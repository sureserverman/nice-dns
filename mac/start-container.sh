#!/usr/bin/env bash
# LaunchAgent entrypoint: bring up the Apple `container` system and the
# nice-dns stack after login. Normal starts reuse the existing dnsnet network
# and existing containers. Only the recovery path tears the stack down.
#
# Variant ('haproxy' or 'socat') is passed as argv[1] by the LaunchAgent plist.

set -u
LOG="${HOME}/Library/Logs/nice-dns.log"
ROOT_HELPER=/usr/local/sbin/start-container-root.sh
VARIANT="${1:-haproxy}"
TOR_IMAGE="docker.io/sureserver/tor-${VARIANT}:latest"
NETWORK_NAME=dnsnet
NETWORK_SUBNET=172.31.240.248/29
NETWORK_STATE_DIR="${HOME}/Library/Application Support/com.apple.container/networks/${NETWORK_NAME}"
PIHOLE_IP=172.31.240.250
TOR_CONTAINER="tor-${VARIANT}"
HEALTH_PROBE=cloudflare.com

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset SSH_AUTH_SOCK

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"; }
run_root_helper() {
  [[ -x "$ROOT_HELPER" ]] || return 1
  sudo -n "$ROOT_HELPER" "$1" >>"$LOG" 2>&1
}

dns_healthy() {
  dig @"$PIHOLE_IP" +time=3 +tries=1 +short "$HEALTH_PROBE" 2>/dev/null \
    | grep -Eq '^[0-9.]+$'
}

container_running() {
  container list 2>/dev/null | grep -qw "$1"
}

container_exists() {
  container list --all 2>/dev/null | grep -qw "$1"
}

network_exists() {
  container network list 2>/dev/null | grep -qw "$NETWORK_NAME"
}

latest_overlap_log() {
  log show --last 2m --style compact \
    --predicate 'subsystem == "com.apple.NetworkSharing" AND eventMessage CONTAINS[c] "overlapping DHCP range"' \
    2>/dev/null | tail -n 1
}

repair_stale_dnsnet() {
  local overlap_line
  local backup_root
  local backup_target

  overlap_line="$(latest_overlap_log)"
  if [[ -z "$overlap_line" ]]; then
    log "dnsnet create failed without NetworkSharing overlap evidence"
    return 1
  fi

  log "detected stale dnsnet reservation: $overlap_line"
  backup_root="${HOME}/.nice-dns-vmnet-backup-$(date '+%Y%m%d-%H%M%S')"
  if [[ -e "$NETWORK_STATE_DIR" ]]; then
    mkdir -p "$backup_root"
    backup_target="${backup_root}/${NETWORK_NAME}"
    mv "$NETWORK_STATE_DIR" "$backup_target"
    log "moved stale dnsnet metadata to $backup_target"
  else
    log "dnsnet metadata path not present at $NETWORK_STATE_DIR"
  fi

  if ! run_root_helper repair-dnsnet; then
    log "repair-dnsnet helper failed"
    return 1
  fi

  sleep 2
  return 0
}

ensure_network_present() {
  local out
  out="$(mktemp)"
  if container network create --subnet "$NETWORK_SUBNET" "$NETWORK_NAME" >"$out" 2>&1; then
    cat "$out" >>"$LOG"
    rm -f "$out"
    log "dnsnet ready"
    return 0
  fi

  cat "$out" >>"$LOG"
  if grep -qi "already exists" "$out"; then
    rm -f "$out"
    log "dnsnet already exists"
    return 0
  fi
  rm -f "$out"

  if ! repair_stale_dnsnet; then
    return 1
  fi

  out="$(mktemp)"
  if container network create --subnet "$NETWORK_SUBNET" "$NETWORK_NAME" >"$out" 2>&1; then
    cat "$out" >>"$LOG"
    rm -f "$out"
    log "dnsnet recreated after stale metadata repair"
    return 0
  fi

  cat "$out" >>"$LOG"
  if grep -qi "already exists" "$out"; then
    rm -f "$out"
    log "dnsnet already exists after stale metadata repair"
    return 0
  fi
  rm -f "$out"
  log "dnsnet recreate still failed after stale metadata repair"
  return 1
}

remove_wrong_tor_variant() {
  local stale
  for stale in tor-haproxy tor-socat; do
    if [[ "$stale" == "$TOR_CONTAINER" ]]; then
      continue
    fi
    if container_exists "$stale"; then
      container stop "$stale" >/dev/null 2>&1 || true
      container rm "$stale" >/dev/null 2>&1 || true
      log "removed stale container $stale"
    fi
  done
}

ensure_container() {
  local name="$1"
  shift

  if container_running "$name"; then
    log "$name already running"
    return 0
  fi

  if container_exists "$name"; then
    if container start "$name" >>"$LOG" 2>&1; then
      log "started existing container $name"
      return 0
    fi
    container rm "$name" >/dev/null 2>&1 || true
    log "recreating container $name after failed start"
  fi

  if container run -d --name "$name" --network "$NETWORK_NAME" "$@" >>"$LOG" 2>&1; then
    log "created container $name"
    return 0
  fi

  log "failed to create container $name"
  return 1
}

start_or_create_stack() {
  remove_wrong_tor_variant

  ensure_container pi-hole \
    -c 1 -m 256M \
    -e TZ=Europe/London \
    -e DNS1=172.31.240.251 \
    -e DISABLE_GITHUB_UPDATES=true \
    pi-hole:latest || return 1

  ensure_container unbound \
    -c 1 -m 256M \
    unbound:latest || return 1

  ensure_container "$TOR_CONTAINER" \
    -c 1 -m 512M \
    "$TOR_IMAGE" || return 1

  return 0
}

rebuild_stack() {
  local c
  for c in pi-hole unbound tor-haproxy tor-socat; do
    if container_exists "$c"; then
      container stop "$c" >/dev/null 2>&1 || true
      container rm "$c" >/dev/null 2>&1 || true
    fi
  done

  if network_exists; then
    container network rm "$NETWORK_NAME" >>"$LOG" 2>&1 || true
  fi

  ensure_network_present || return 1
  start_or_create_stack
}

wait_for_chain() {
  local tries=0
  until dns_healthy; do
    (( tries++ ))
    if (( tries >= 30 )); then
      log "chain did not come up within 150s"
      return 1
    fi
    sleep 5
  done
  log "chain resolving"
  return 0
}

mkdir -p "$(dirname "$LOG")"

log "starting nice-dns runtime (variant=$VARIANT)"

# 1) apiserver + default kernel must be up. `container system start` is
# idempotent; the first-ever run prompts for the kata kernel download, which
# the installer handled — this invocation runs non-interactively.
tries=0
until container system status >/dev/null 2>&1; do
  (( tries++ ))
  if (( tries >= 10 )); then
    log "container system never came up"
    exit 1
  fi
  log "container system not ready, retry $tries/10"
  container system start </dev/null >>"$LOG" 2>&1 || true
  sleep 4
done
log "container system ready"

# 2) Fast path: if the stack is already healthy and using the requested tor
# variant, keep the existing network and containers untouched.
if container_running "$TOR_CONTAINER" && dns_healthy; then
  run_root_helper post || log "post-start helper failed"
  log "stack already healthy (variant=$VARIANT) — reusing existing state"
  exit 0
fi

# 3) Privileged pre-start (e.g. Mullvad teardown). Optional — only runs if
# the helper is installed in sudoers.
run_root_helper pre || log "pre-start helper skipped"

# 4) Default path: keep dnsnet if it is already present and just start missing
# containers. Only the recovery path below rebuilds the stack.
if ! ensure_network_present; then
  log "failed to ensure dnsnet exists"
  exit 1
fi

# 5) Tor/bootstrap lag is normal. If the default path cannot start the reused
# stack cleanly, rebuild the stack once. This avoids dnsnet recreation on
# ordinary logins while still giving the system a single recovery shot.
if ! start_or_create_stack; then
  log "default start path failed; attempting one rebuild"
  if ! rebuild_stack; then
    log "rebuild path failed; keeping fail-closed DNS pin"
    exit 1
  fi
elif ! wait_for_chain; then
  log "default start path unhealthy; attempting one rebuild"
  if ! rebuild_stack; then
    log "rebuild path failed; keeping fail-closed DNS pin"
    exit 1
  fi
fi

if ! wait_for_chain; then
  log "rebuild path unhealthy; keeping fail-closed DNS pin"
  exit 1
fi

# 6) Privileged post-start (set system DNS to pi-hole).
run_root_helper post || log "post-start helper failed"

log "done"
