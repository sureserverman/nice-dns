#!/usr/bin/env bash
# LaunchAgent entrypoint: bring up the Apple `container` system and the
# nice-dns stack after login. Normal starts reuse the existing dnsnet network
# and existing containers. Only the recovery path tears the stack down.
#
# Variant ('haproxy' or 'socat') is passed as argv[1] by the LaunchAgent plist.

set -euo pipefail
LOG="${HOME}/Library/Logs/nice-dns.log"
ROOT_HELPER=/usr/local/sbin/start-container-root.sh
VARIANT="${1:-haproxy}"
TOR_IMAGE="docker.io/sureserver/tor-${VARIANT}:latest"
NETWORK_NAME=dnsnet
NETWORK_SUBNET=172.31.240.248/29
NETWORK_STATE_DIR="${HOME}/Library/Application Support/com.apple.container/networks/${NETWORK_NAME}"
# Addresses the rest of the stack is wired for. These are not requests —
# Apple's runtime has no --ip flag (apple/container#282) — they are what the
# vmnet allocator hands out when the network is created fresh and containers
# are created in the order below: it allocates sequentially from the subnet
# base, and .249 is the gateway. Verified deterministic across repeated
# create/destroy cycles. unbound.conf's forward-addr, pi-hole's upstream, and
# start-container-root.sh's set_local_dns all hardcode these, so the stack is
# only correct when the allocator actually produces them.
PIHOLE_IP=172.31.240.250
UNBOUND_IP=172.31.240.251
TOR_IP=172.31.240.252
TOR_CONTAINER="tor-${VARIANT}"
HEALTH_PROBE=cloudflare.com
BRIDGES_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/nice-dns/bridges.env"
FETCH_BRIDGES_BIN=/usr/local/sbin/nice-dns-fetch-bridges.sh
# Tor's DataDirectory, bind-mounted so it survives container recreation.
# The image puts DataDirectory under $DATA_DIR (/app/data), so mounting that
# one path carries cached-microdesc-consensus, cached-microdescs, the guard
# selection in `state`, and pt_state for the obfs4 transports — ~50MB that
# Tor otherwise re-downloads from scratch. A cold bootstrap through obfs4 can
# exceed 10 minutes on a degraded link, so surviving a recreate is the
# difference between a stack that comes back and one that doesn't.
# Paired with the guard-sample pruning in prune_guard_state(): persisting this
# directory is only safe while stale bridges are cleared out of it.
# Apple's runtime maps the host owner onto the container's uid, so no
# chown dance is needed here.
TOR_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns/tor-${VARIANT}"
# Fingerprint of the bridge triple baked into the running tor container.
# Apple's runtime bakes -e env at `container run` and reuses it on `container
# start`, so the only way to apply new bridges is to recreate — but recreating
# when nothing changed throws away a working Tor for no reason.
BRIDGE_FP_FILE="${TOR_STATE_DIR}/.bridge-fingerprint"
# Set when tor fails to bootstrap; makes the *next* run rotate bridges.
# Bridges are only rotated on evidence they don't work, never on a timer.
BRIDGE_SENTINEL="${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns/bootstrap-failed-${VARIANT}"
BRIDGE1=""
BRIDGE2=""
BRIDGE3=""

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset SSH_AUTH_SOCK

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"; }
run_root_helper() {
  [[ -x "$ROOT_HELPER" ]] || return 1
  sudo -n "$ROOT_HELPER" "$1" >>"$LOG" 2>&1
}

load_bridges() {
  [[ -f "$BRIDGES_FILE" ]] || return 1
  BRIDGE1="$(sed -n 's/^BRIDGE1=//p' "$BRIDGES_FILE" | head -n 1)"
  BRIDGE2="$(sed -n 's/^BRIDGE2=//p' "$BRIDGES_FILE" | head -n 1)"
  BRIDGE3="$(sed -n 's/^BRIDGE3=//p' "$BRIDGES_FILE" | head -n 1)"
  [[ -n "$BRIDGE1" && -n "$BRIDGE2" && -n "$BRIDGE3" ]]
}

bridge_fingerprint() {
  printf '%s\n%s\n%s\n' "$BRIDGE1" "$BRIDGE2" "$BRIDGE3" | shasum -a 256 | cut -d' ' -f1
}

# Tor's DataDirectory holds two kinds of state with opposite lifetimes:
#
#   cached-*  — network consensus and microdescriptors. Independent of which
#               bridges we use, ~50MB, and the expensive thing to re-fetch.
#               Always worth keeping.
#   state     — the *sampled guard set*. Bridge-specific. Bridges that rotate
#               out are marked listed=0 but stay in the sample, and Tor keeps
#               retrying them. With NumPrimaryGuards 2 (see the image's torrc)
#               a sample carrying dead bridges starves the live ones: tor still
#               reports "bootstrapped" while its circuits carry no data, and
#               every haproxy backend — including the clearnet ones — fails its
#               Layer7 check.
#
# So persisting the DataDirectory is only safe if the guard sample is dropped
# whenever the bridge set changes. Keep the caches, discard the sample.
prune_guard_state() {
  rm -f "${TOR_STATE_DIR}/tor/state"
}

tor_bootstrapped() {
  container logs "$TOR_CONTAINER" 2>&1 | grep -qi 'bootstrapped successfully'
}

# Bootstrap is judged on tor's own output rather than on end-to-end DNS, so a
# slow-but-working Tor is not mistaken for a bad bridge set.
wait_for_tor_bootstrap() {
  local tries=0
  until tor_bootstrapped; do
    tries=$((tries + 1))
    if (( tries >= 60 )); then
      log "tor did not bootstrap within 300s"
      return 1
    fi
    sleep 5
  done
  log "tor bootstrapped"
  return 0
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

container_ip() {
  container inspect "$1" 2>/dev/null \
    | sed -nE 's@.*"ipv4Address" *: *"([0-9.]+).*@\1@p' | head -n 1
}

# True only when all three containers are running AND sitting on the addresses
# the configs hardcode. Apple's allocator assigns sequentially and does not
# reuse a freed address immediately, so `container start` on an existing
# container can hand it a different address than it had — which silently
# repoints unbound at whatever now occupies the old one. Checking is cheap;
# guessing is what produced a chain wired pi-hole -> itself.
stack_addressed_correctly() {
  container_running pi-hole || return 1
  container_running unbound || return 1
  container_running "$TOR_CONTAINER" || return 1
  [[ "$(container_ip pi-hole)"          == "$PIHOLE_IP"  ]] || return 1
  [[ "$(container_ip unbound)"          == "$UNBOUND_IP" ]] || return 1
  [[ "$(container_ip "$TOR_CONTAINER")" == "$TOR_IP"     ]] || return 1
  return 0
}

log_addresses() {
  log "addresses: pi-hole=$(container_ip pi-hole) unbound=$(container_ip unbound) ${TOR_CONTAINER}=$(container_ip "$TOR_CONTAINER") (want ${PIHOLE_IP}/${UNBOUND_IP}/${TOR_IP})"
}

network_exists() {
  container network list 2>/dev/null | grep -qw "$NETWORK_NAME"
}

latest_overlap_log() {
  # log show may exit non-zero on no-match; tolerate under pipefail.
  log show --last 2m --style compact \
    --predicate 'subsystem == "com.apple.NetworkSharing" AND eventMessage CONTAINS[c] "overlapping DHCP range"' \
    2>/dev/null | tail -n 1 || true
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
    # Block until this container has actually been assigned an address before
    # returning. Addresses are handed out in creation order, so callers must
    # not race: creating all three back-to-back within the same second was
    # observed to produce them out of order (pi-hole .252, unbound .250,
    # tor .251) and silently mis-wire the chain.
    local tries=0
    until [[ -n "$(container_ip "$name")" ]]; do
      tries=$((tries + 1))
      if (( tries >= 30 )); then
        log "$name created but never got an address"
        return 1
      fi
      sleep 1
    done
    log "created container $name at $(container_ip "$name")"
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
    -e DNS1=172.31.240.251#5335 \
    -e FTLCONF_dns_upstreams=172.31.240.251#5335 \
    -e DISABLE_GITHUB_UPDATES=true \
    pi-hole:latest || return 1

  ensure_container unbound \
    -c 1 -m 256M \
    unbound:latest || return 1

  # Recreate the tor container only when the bridge set actually changed.
  # Apple's runtime bakes -e env at `container run` and reuses it on
  # `container start`, so a changed bridge set does require a drop+rerun —
  # but an unchanged one does not, and recreating regardless was throwing
  # away a bootstrapped Tor on every boot. pi-hole and unbound aren't
  # bridge-dependent, so they go through the normal ensure_container reuse
  # path.
  mkdir -p "$TOR_STATE_DIR"
  local want_fp have_fp=""
  want_fp="$(bridge_fingerprint)"
  [[ -f "$BRIDGE_FP_FILE" ]] && have_fp="$(cat "$BRIDGE_FP_FILE" 2>/dev/null || true)"

  if container_exists "$TOR_CONTAINER" && [[ -n "$have_fp" && "$want_fp" == "$have_fp" ]]; then
    log "bridge set unchanged; reusing existing $TOR_CONTAINER"
  else
    if container_exists "$TOR_CONTAINER"; then
      container stop "$TOR_CONTAINER" >/dev/null 2>&1 || true
      container rm "$TOR_CONTAINER" >/dev/null 2>&1 || true
      log "removed existing $TOR_CONTAINER to apply changed bridge set"
    fi
    if [[ -n "$have_fp" && "$want_fp" != "$have_fp" ]]; then
      prune_guard_state
      log "bridge set changed; dropped stale guard sample (consensus cache kept)"
    fi
  fi

  ensure_container "$TOR_CONTAINER" \
    -c 1 -m 512M \
    -v "${TOR_STATE_DIR}:/app/data" \
    -e "BRIDGE1=${BRIDGE1}" \
    -e "BRIDGE2=${BRIDGE2}" \
    -e "BRIDGE3=${BRIDGE3}" \
    "$TOR_IMAGE" || return 1

  # Record what the running container was actually started with, so the next
  # boot can tell "same bridges, leave it alone" from "bridges changed".
  printf '%s\n' "$want_fp" > "$BRIDGE_FP_FILE"

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
    tries=$((tries + 1))
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

# 0) Load BRIDGE1/2/3 for the `container run -e BRIDGE*` call below, fetching
# a new set only when there's a reason to.
#
# This used to refetch with --force on every boot. That defeats itself: each
# rotation invalidates the guard reputation Tor has built up, and (now that
# the DataDirectory persists) leaves delisted bridges accumulating in tor's
# sampled guard set until circuits stop carrying data entirely. Bridges do
# still need to rotate — obfs4 is what gets Tor past a VLESS/REALITY
# transparent proxy, and individual bridges die — but rotation should be a
# response to failure, not a scheduled event. So: reuse the known set, and
# refetch only when it's missing/incomplete or the previous run failed to
# bootstrap (BRIDGE_SENTINEL, set at the bottom of this script).
mkdir -p "$(dirname "$BRIDGE_SENTINEL")"
rotate_bridges=0
if ! load_bridges; then
  rotate_bridges=1
  log "bridges.env missing or incomplete; fetching a set"
elif [[ -f "$BRIDGE_SENTINEL" ]]; then
  rotate_bridges=1
  log "previous run failed to bootstrap; rotating bridges"
fi

if (( rotate_bridges )); then
  if [[ -x "$FETCH_BRIDGES_BIN" ]]; then
    "$FETCH_BRIDGES_BIN" --force >>"$LOG" 2>&1 \
      || log "bridge refetch failed — keeping previous bridges.env"
    load_bridges || log "bridges.env still incomplete after fetch; tor will fail to start"
  else
    log "warning: $FETCH_BRIDGES_BIN not installed; cannot rotate bridges"
  fi
  rm -f "$BRIDGE_SENTINEL"
else
  log "reusing existing bridge set (bootstrapped cleanly last run)"
fi

# 1) apiserver + default kernel must be up. `container system start` is
# idempotent; the first-ever run prompts for the kata kernel download, which
# the installer handled — this invocation runs non-interactively.
tries=0
until container system status >/dev/null 2>&1; do
  tries=$((tries + 1))
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
# variant, keep the existing network and containers untouched. Bridge
# refresh-and-apply happens at the next host boot via the bind-mount path —
# no mid-session container churn.
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
# 5) Bring the stack up on the addresses the configs are wired for.
#
# Apple's runtime offers no way to request an address (apple/container#282),
# but the vmnet allocator is not arbitrary: on a freshly created network it
# hands out the subnet sequentially, so creating pi-hole, unbound and tor in
# that order yields .250/.251/.252 every time. Measured across repeated
# create/destroy cycles, identical on each. That is the whole guarantee the
# hardcoded addresses rest on, and it only holds for containers created
# against a fresh network — `container start` on an existing container may
# move it, because freed addresses are not reused immediately.
#
# So: if everything is already running on the right addresses, leave it
# completely alone. Otherwise tear down the network and recreate in order,
# which is the only operation that restores them. There is no middle path —
# recreating a single container is what scrambles the assignment.
if stack_addressed_correctly; then
  log "stack running on expected addresses; leaving it alone"
else
  log_addresses
  log "addresses not as configured; rebuilding stack in allocation order"
  if ! rebuild_stack; then
    log "rebuild path failed; leaving system resolver untouched"
    exit 1
  fi
  if ! stack_addressed_correctly; then
    # Refuse to run a mis-wired chain. unbound would forward to whatever now
    # holds .252 — which has been observed to be unbound itself — and pi-hole
    # would forward to whatever holds .251. Both fail in ways that look like
    # upstream latency rather than a wiring fault.
    log_addresses
    log "rebuild did not produce the expected addresses; refusing to continue"
    exit 1
  fi
  log "stack rebuilt on expected addresses"
fi

# 5a) Let tor finish bootstrapping before judging anything, and judge the
# bridge set on tor's own output rather than on end-to-end DNS. A slow
# upstream or a cold cache must not be read as "bad bridges" — that
# misdiagnosis is what made the old unconditional refetch rotate a working
# set away every boot. Rotation is deferred to the next run so this one
# still gets to recover on what it has.
tor_ok=0
if wait_for_tor_bootstrap; then
  tor_ok=1
else
  touch "$BRIDGE_SENTINEL"
  log "armed bridge rotation for next run"
fi

# 5b) A chain fault is only worth a rebuild when tor is the thing that's
# broken. rebuild_stack tears down and recreates every container, so running
# it against a bootstrapped tor discards the one piece that is expensive to
# rebuild and cheap to keep — observed live: a tor that had bootstrapped in
# 101s and was answering DoT was destroyed by this path, and its replacement
# then failed to bootstrap at all. If tor is up, leave the stack alone and
# let the fault surface as an unhealthy chain instead.
if ! wait_for_chain; then
  if (( tor_ok )); then
    # Deliberately stop here rather than rebuilding *or* pinning. Rebuilding
    # would discard a working tor. Pinning is not safe yet either: the root
    # helper's set_local_dns hardcodes PIHOLE_IP=172.31.240.250, but Apple's
    # runtime reassigns container addresses on every start, so the pin can
    # point at an address nothing is listening on — that is DNS loss with
    # none of the privacy benefit. Until the stack learns its own addresses
    # at runtime, exiting leaves the system resolver untouched.
    log "chain unhealthy but tor is bootstrapped; not rebuilding (would discard a working tor)"
    log "not pinning DNS: pin target is hardcoded and container IPs are not stable"
    exit 1
  else
    log "chain unhealthy and tor never bootstrapped; attempting one rebuild"
    if ! rebuild_stack; then
      log "rebuild path failed; keeping fail-closed DNS pin"
      exit 1
    fi
    if ! wait_for_chain; then
      log "rebuild path unhealthy; keeping fail-closed DNS pin"
      exit 1
    fi
  fi
fi

# 6) Privileged post-start (set system DNS to pi-hole).
run_root_helper post || log "post-start helper failed"

log "done"
