#!/bin/bash
# LaunchAgent entrypoint: bring up the Apple `container` system and the
# nice-dns stack after login. Idempotent: tears down existing containers and
# recreates them in pi-hole → unbound → tor order so the bridge allocator
# hands out 172.31.240.250/.251/.252 deterministically.
#
# Variant is read from /usr/local/etc/nice-dns/variant (haproxy|socat),
# created by the installer. Defaults to haproxy if missing.

set -u
LOG="${HOME}/Library/Logs/nice-dns.log"
VARIANT_FILE=/usr/local/etc/nice-dns/variant
ROOT_HELPER=/usr/local/sbin/start-container-root.sh

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset SSH_AUTH_SOCK

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"; }

mkdir -p "$(dirname "$LOG")"

VARIANT=haproxy
[[ -r "$VARIANT_FILE" ]] && VARIANT="$(tr -d '[:space:]' <"$VARIANT_FILE")"
case "$VARIANT" in haproxy|socat) ;; *) VARIANT=haproxy ;; esac
TOR_IMAGE="docker.io/sureserver/tor-${VARIANT}:latest"

log "starting nice-dns runtime (variant=$VARIANT)"

# Let the system settle after login before poking container.
sleep 5

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

# 2) Privileged pre-start (e.g. Mullvad teardown). Optional — only runs if
# the helper is installed in sudoers.
if [[ -x "$ROOT_HELPER" ]]; then
  sudo -n "$ROOT_HELPER" pre >>"$LOG" 2>&1 || log "pre-start helper skipped"
fi

# 3) Teardown any previous state. Full recreate keeps the allocator
# deterministic across reboots.
for c in pi-hole unbound tor-haproxy tor-socat; do
  container stop "$c" >/dev/null 2>&1 || true
  container rm "$c"   >/dev/null 2>&1 || true
done
container network rm dnsnet >/dev/null 2>&1 || true

# 4) Recreate network and containers in IP-allocation order.
if ! container network create --subnet 172.31.240.248/29 dnsnet >>"$LOG" 2>&1; then
  log "failed to create dnsnet"
  exit 1
fi

if ! container run -d --name pi-hole --network dnsnet \
      -c 1 -m 256M \
      -e TZ=Europe/London \
      -e DNS1=172.31.240.251 \
      -e DISABLE_GITHUB_UPDATES=true \
      pi-hole:latest >>"$LOG" 2>&1; then
  log "failed to start pi-hole"
  exit 1
fi

if ! container run -d --name unbound --network dnsnet \
      -c 1 -m 256M \
      unbound:latest >>"$LOG" 2>&1; then
  log "failed to start unbound"
  exit 1
fi

if ! container run -d --name "tor-${VARIANT}" --network dnsnet \
      -c 1 -m 512M \
      "$TOR_IMAGE" >>"$LOG" 2>&1; then
  log "failed to start tor-${VARIANT}"
  exit 1
fi

# 5) Wait for the chain to resolve before declaring success. Tor bootstrap
# typically finishes within ~60s.
tries=0
until dig @172.31.240.250 +time=3 +tries=1 +short cloudflare.com 2>/dev/null \
      | grep -Eq '^[0-9.]+$'; do
  (( tries++ ))
  if (( tries >= 30 )); then
    log "chain did not come up within 150s"
    break
  fi
  sleep 5
done
log "chain resolving"

# 6) Privileged post-start (set system DNS to pi-hole).
if [[ -x "$ROOT_HELPER" ]]; then
  sudo -n "$ROOT_HELPER" post >>"$LOG" 2>&1 || log "post-start helper failed"
fi

log "done"
