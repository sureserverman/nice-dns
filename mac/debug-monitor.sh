#!/usr/bin/env bash
# nice-dns debug monitor — catches the vmnet datapath wedge in the act.
#
# The wedge: containers running on their correct addresses, tor reporting
# "Bootstrapped 100%" off cached consensus, every health check passing — and no
# traffic moving, not even between two containers on the same /29. On the host
# the runtime's vmenet interfaces are all down. mac/start-container.sh now
# detects and repairs this, but the *trigger* is unknown, and the repair
# destroys the evidence. This samples continuously and dumps a full snapshot on
# the healthy->wedged transition, before anything gets a chance to fix it.
#
# Not reproducible by churn: 14 rounds of container create/destroy and 6 of
# network create/destroy left it healthy, and the vmenet count is a fixed pool
# that was identical in both states. So this captures the things churn does not
# touch -- host network reconfiguration, sleep/wake, pf reloads, runtime service
# restarts -- and timestamps them against the transition.
#
# Usage: debug-monitor.sh [haproxy|socat] [interval_seconds]

set -uo pipefail
VARIANT="${1:-haproxy}"
INTERVAL="${2:-20}"
TOR_CONTAINER="tor-${VARIANT}"
UNBOUND_IP=172.31.240.251
PIHOLE_IP=172.31.240.250

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

LOGDIR="${HOME}/Library/Logs/nice-dns-debug"
SERIES="${LOGDIR}/series.log"
mkdir -p "$LOGDIR"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }

# --- state probes -----------------------------------------------------------

vmenet_up()    { ifconfig 2>/dev/null | grep '^vmenet' -A1 | grep -c RUNNING; }
vmenet_total() { ifconfig 2>/dev/null | grep -c '^vmenet'; }

datapath_ok() {
  container_running "$TOR_CONTAINER" || return 1
  # Instrument control: if loopback fails, nc is unusable and we cannot judge.
  container exec "$TOR_CONTAINER" nc -w 4 -z 127.0.0.1 853 >/dev/null 2>&1 || return 0
  container exec "$TOR_CONTAINER" nc -w 5 -z "$UNBOUND_IP" 5335 >/dev/null 2>&1
}

container_running() { container list 2>/dev/null | grep -qw "$1"; }
dns_ok() { dig @"$PIHOLE_IP" +time=3 +tries=1 +short cloudflare.com 2>/dev/null | grep -Eq '^[0-9.]+$'; }

# Primary service + its DNS, so a host network reconfiguration is visible in the
# series itself rather than only in the snapshot.
primary_dns() { networksetup -getdnsservers Wi-Fi 2>/dev/null | tr '\n' ',' ; }
route_gw()    { netstat -rn 2>/dev/null | awk '$1=="default"{print $2; exit}'; }

# --- snapshot ---------------------------------------------------------------

snapshot() {
  local reason="$1"
  local f="${LOGDIR}/snapshot-$(date '+%Y%m%d-%H%M%S')-${reason}.txt"
  {
    echo "=== $(ts)  reason=${reason} ==="
    echo
    echo "--- interfaces (vmenet/bridge/feth) ---"
    ifconfig 2>/dev/null | grep -E '^(vmenet|bridge|feth|en)[0-9]*:' -A3
    echo
    echo "--- bridge0 members ---"
    ifconfig bridge0 2>/dev/null
    echo
    echo "--- routes ---"
    netstat -rn 2>/dev/null | head -20
    echo
    echo "--- containers ---"
    container ls --all 2>&1 | head -12
    echo
    echo "--- container system status ---"
    container system status 2>&1 | head -8
    echo
    echo "--- apple container services ---"
    launchctl list 2>/dev/null | grep -i 'com.apple.container' || echo "(none)"
    echo
    echo "--- DNS config ---"
    for s in "Wi-Fi" "Ethernet"; do
      printf '%s: %s\n' "$s" "$(networksetup -getdnsservers "$s" 2>&1 | tr '\n' ' ')"
    done
    scutil --dns 2>/dev/null | grep -E 'nameserver|resolver #' | head -12
    echo
    echo "--- pf status ---"
    sudo -n pfctl -s info 2>/dev/null | head -6 || echo "(pfctl needs sudo; skipped)"
    echo
    echo "--- sleep/wake (recent) ---"
    pmset -g log 2>/dev/null | grep -E 'Sleep|Wake|DarkWake' | tail -12
    echo
    echo "--- unified log: apple container + vmnet, last 10m ---"
    log show --last 10m --style compact \
      --predicate 'subsystem CONTAINS "com.apple.container" OR eventMessage CONTAINS "vmnet" OR eventMessage CONTAINS "vmenet"' \
      2>/dev/null | tail -60 || echo "(log show unavailable)"
    echo
    echo "--- nice-dns agent log (tail) ---"
    tail -25 "${HOME}/Library/Logs/nice-dns.log" 2>/dev/null
    echo
    echo "--- tor log tail ---"
    container exec "$TOR_CONTAINER" tail -15 /tmp/tor.log 2>/dev/null | cut -c1-160
  } > "$f" 2>&1
  echo "$f"
}

# --- main loop --------------------------------------------------------------

echo "$(ts) monitor starting (variant=${VARIANT} interval=${INTERVAL}s pid=$$)" >> "$SERIES"
prev_state=""
prev_dns=""
prev_gw=""

while :; do
  up="$(vmenet_up)"; tot="$(vmenet_total)"
  if datapath_ok; then dp=ok; else dp=WEDGED; fi
  if dns_ok; then dn=ok; else dn=FAIL; fi
  cdns="$(primary_dns)"; gw="$(route_gw)"
  state="${dp}/${dn}/${up}"

  printf '%s vmenet=%s/%s datapath=%s dns=%s dns_cfg=%s gw=%s\n' \
    "$(ts)" "$up" "$tot" "$dp" "$dn" "$cdns" "$gw" >> "$SERIES"

  # Host network reconfiguration is a prime suspect: it is the one thing an
  # install does that container/network churn does not. Record it separately so
  # it can be correlated against a later transition even if nothing breaks now.
  if [[ -n "$prev_dns" && "$cdns" != "$prev_dns" ]]; then
    echo "$(ts) EVENT dns_config_changed: '${prev_dns}' -> '${cdns}'" >> "$SERIES"
    snapshot "dnschange" >> "$SERIES"
  fi
  if [[ -n "$prev_gw" && "$gw" != "$prev_gw" ]]; then
    echo "$(ts) EVENT default_route_changed: '${prev_gw}' -> '${gw}'" >> "$SERIES"
    snapshot "routechange" >> "$SERIES"
  fi

  # The transition we are hunting.
  if [[ -n "$prev_state" && "$state" != "$prev_state" ]]; then
    echo "$(ts) EVENT state_change: ${prev_state} -> ${state}" >> "$SERIES"
    if [[ "$dp" == WEDGED ]]; then
      f="$(snapshot wedged)"
      echo "$(ts) *** WEDGE DETECTED — snapshot: ${f}" >> "$SERIES"
    else
      snapshot "recovered" >> "$SERIES"
    fi
  fi

  prev_state="$state"; prev_dns="$cdns"; prev_gw="$gw"
  sleep "$INTERVAL"
done
