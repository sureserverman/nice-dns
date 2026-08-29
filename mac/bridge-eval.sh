#!/usr/bin/env bash
# nice-dns-bridge-eval.sh — host-side obfs4 bridge selection for macOS.
#
# macOS counterpart to the nice-dns-fetch-bridges.service unit that
# deb/persistent-podman.sh installs on Linux. Runs the in-image bridge-eval
# in "manage" mode: fetches candidates from both the Moat builtin list and
# the rdsys HTTPS distributor, accumulates them into a persistent pool,
# tests which ones actually complete an obfs4 handshake and reach the
# Cloudflare DoT .onion, prunes only the persistently dead, and writes the
# reachable set to bridges.env.
#
# Why host-side, and why not in the proxy container:
#
#   The usability probe costs roughly 150s. Measured on this stack, running
#   it inside the proxy at startup (BRIDGE_EVAL=auto) pushed tor bootstrap
#   from ~8s to ~87s and the onion path from ~108s to ~147s, three runs each,
#   alternated against the current behaviour to control for drift. Paying
#   that on every start is strictly worse than paying it out-of-band.
#
#   Run here instead, on its own schedule, the cost is invisible: the proxy
#   starts immediately on whatever bridges.env already holds, and this
#   refreshes it for the *next* start.
#
# Why it is worth running at all:
#
#   fetch-bridges.sh deliberately does not rank — a TCP-connect probe cannot
#   distinguish a working bridge from one that is TCP-open but PT-dead — and
#   the proxy consumes bridges.env as-is (BRIDGE_EVAL=off is a passthrough),
#   so whatever the fetch wrote becomes the Bridge list verbatim, dead entries
#   included. This evaluator is what actually tests the obfs4 handshake and
#   drops the ones that never answer.
#
#   Measured, isolated, alternated, one tor at a time (macOS, 2026-08-29):
#   pruning dead bridges did NOT speed up bootstrap — 7-alive and 7-with-2-dead
#   both had a 56s mean, because a dead bridge times out in parallel with the
#   live ones succeeding. What it does buy is a guard sample free of dead
#   entries: 5 bridge descriptors received against 3 for the unpruned set.
#
# Exit status mirrors the Linux unit's SuccessExitStatus=0 1 handling: a run
# that finds nothing reachable is tolerated *if* a usable bridges.env already
# exists, because a transient distributor or Tor outage should not clobber a
# working set. With nothing to fall back on it fails loudly, since the proxy
# would otherwise start bridgeless and Tor would never bootstrap.

set -uo pipefail

VARIANT="${1:-haproxy}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nice-dns"
BRIDGES_FILE="$CONFIG_DIR/bridges.env"
POOL_FILE="$CONFIG_DIR/bridge-pool.tsv"
IMAGE="docker.io/sureserver/tor-${VARIANT}:latest"
NETWORK_NAME=dnsnet
LOG="${HOME}/Library/Logs/nice-dns-bridge-eval.log"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$CONFIG_DIR" "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"; }

log "starting host-side bridge-eval manage (variant=$VARIANT)"

# The runtime must be up; unlike systemd there is no dependency ordering to
# lean on, so wait rather than fail if this fires before the stack's agent.
tries=0
until container system status >/dev/null 2>&1; do
  tries=$((tries + 1))
  if (( tries >= 10 )); then
    log "container system not available; leaving bridges.env untouched"
    exit 0
  fi
  sleep 6
done

# This MUST run on the stack's own network, never the default one. Measured on
# this host 2026-08-29, from a healthy baseline, healing between arms:
#
#   4th container with --network dnsnet   -> vmenet 3->4, datapath ok
#   4th container on the default network  -> vmenet 3->1, datapath WEDGED in 14s
#
# Apple's runtime cannot carry containers on two vmnet networks at once:
# bringing one up on a second network tears down the first network's
# interfaces. This script used to run with no --network at all, so it landed on
# `default` and killed dnsnet every time -- which is why the stack died minutes
# after each install, when the RunAtLoad on this agent fires.
#
# So wait for dnsnet rather than falling back to the default network: running
# without it is precisely the bug.
tries=0
until container network list 2>/dev/null | grep -qw "$NETWORK_NAME"; do
  tries=$((tries + 1))
  if (( tries >= 10 )); then
    log "$NETWORK_NAME not present; leaving bridges.env untouched (refusing to run on the default network)"
    exit 0
  fi
  sleep 6
done

# -pool is what enables manage mode. -window 150 / -grace 20 match the Linux
# unit so both platforms select on the same criteria.
#
# -count 7, not 3: bridge COUNT dominates bootstrap time. Measured isolated and
# alternated, one tor at a time (macOS, 2026-08-29), 3 verified-alive bridges
# took a 141s median against 41s for 7, with a much worse tail (350s vs 141s).
# Tor fans descriptor fetches out across bridges in parallel, so a wider set
# wins; 7 is the practical width of the fetched pool.
out="$(mktemp)"
container run --rm \
  --network "$NETWORK_NAME" \
  -v "${CONFIG_DIR}:/pool" \
  --entrypoint /bin/bridge-eval \
  "$IMAGE" \
  -pool /pool/bridge-pool.tsv \
  -out /pool/bridges.env \
  -count 7 -window 150 -grace 20 >"$out" 2>&1
rc=$?
sed -e 's/cert=[A-Za-z0-9+/]\{20\}[^ ]*/cert=<redacted>/g' "$out" >>"$LOG"
rm -f "$out"

if (( rc == 0 )); then
  log "bridge-eval selected $(grep -c '^BRIDGE' "$BRIDGES_FILE" 2>/dev/null || echo 0) bridge(s)"
  exit 0
fi

# Non-zero: tolerate only when a previous selection survives to fall back on.
if grep -q '^BRIDGE1=' "$BRIDGES_FILE" 2>/dev/null; then
  log "bridge-eval failed (rc=$rc); keeping existing bridges.env"
  exit 0
fi

log "bridge-eval failed (rc=$rc) and no usable bridges.env exists — the proxy will start WITHOUT bridges and Tor will NOT bootstrap. Common cause: bridges.torproject.org unreachable (VPN DNS lockdown, or no network). Fix connectivity, then: launchctl kickstart -k gui/\$(id -u)/org.nice-dns.bridge-eval"
exit 1
