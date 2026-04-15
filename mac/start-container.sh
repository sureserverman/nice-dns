#!/usr/bin/env bash
# LaunchAgent entrypoint: bring up the Apple `container` system and the
# nice-dns stack after login. Idempotent: tears down existing containers and
# recreates them in pi-hole → unbound → tor order so the bridge allocator
# hands out 172.31.240.250/.251/.252 deterministically.
#
# Variant ('haproxy' or 'socat') is passed as argv[1] by the LaunchAgent plist.

set -u
LOG="${HOME}/Library/Logs/nice-dns.log"
ROOT_HELPER=/usr/local/sbin/start-container-root.sh
VARIANT="${1:-haproxy}"
TOR_IMAGE="docker.io/sureserver/tor-${VARIANT}:latest"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset SSH_AUTH_SOCK

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"; }

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

# 2) Fast path: if the stack is already healthy AND the running tor variant
# matches what the plist requested, there's nothing to do. The variant check
# prevents silently keeping a stale haproxy container when the installer has
# been re-run with socat (or vice versa).
if container list 2>/dev/null | grep -qw "tor-${VARIANT}" \
   && dig @172.31.240.250 +time=3 +tries=1 +short cloudflare.com 2>/dev/null \
        | grep -Eq '^[0-9.]+$'; then
  log "stack already healthy (variant=$VARIANT) — skipping rebuild"
  exit 0
fi

# 3) Privileged pre-start (e.g. Mullvad teardown). Optional — only runs if
# the helper is installed in sudoers.
if [[ -x "$ROOT_HELPER" ]]; then
  sudo -n "$ROOT_HELPER" pre >>"$LOG" 2>&1 || log "pre-start helper skipped"
fi

# 4) Teardown any previous state. Full recreate keeps the allocator
# deterministic across reboots.
for c in pi-hole unbound tor-haproxy tor-socat; do
  container stop "$c" >/dev/null 2>&1 || true
  container rm "$c"   >/dev/null 2>&1 || true
done
container network rm dnsnet >/dev/null 2>&1 || true

# 5) Recreate network and containers in IP-allocation order.
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

# 6) Wait for the chain to resolve before declaring success. Tor bootstrap
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

# 7) Privileged post-start (set system DNS to pi-hole).
if [[ -x "$ROOT_HELPER" ]]; then
  sudo -n "$ROOT_HELPER" post >>"$LOG" 2>&1 || log "post-start helper failed"
fi

log "done"
