# shellcheck shell=bash
# nice-dns macOS platform adapter (ARCH-02): route operations. Sourced by
# lib/recovery.sh; Bash 3.2 compatible (macOS /bin/bash). Sub-plan 3 adds
# health and recovery operations here.
#
# Apple `container` gives each container its own address on dnsnet, so the
# route listeners are on the proxy container's address (TOR_IP in
# mac/start-container.sh).
#
#   ND_ROUTE_DIR           host directory mounted at /etc/unbound/route
#                          (default ~/Library/Application Support/nice-dns/unbound-route)
#   ND_UNBOUND_CONTAINER   Unbound container name (default unbound)
#   CONTAINER_BIN          the container CLI (default container)

nd_platform_name() { printf 'macos\n'; }

nd_platform_route_addr() { printf '172.31.240.252\n'; }

nd_platform_route_dir() {
  printf '%s\n' "${ND_ROUTE_DIR:-${HOME:?HOME is unset}/Library/Application Support/nice-dns/unbound-route}"
}

# _nd_mac_exec <container CLI> <exec args...>: `<cli> exec`, with a missing
# executable reported as 127, as podman (crun) does. Apple container exits 1
# with "failed to find target executable" (observed on 1.4.1), which callers
# would otherwise read as a failed command: an Unbound image without
# nice-dns-unbound-start then never let a working restart be ready.
_nd_mac_exec() {
  local bin="$1" e rc
  shift
  e="$(mktemp "${TMPDIR:-/tmp}/nd-mac-exec.XXXXXX")" || { "$bin" exec "$@"; return; }
  "$bin" exec "$@" 2>"$e"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q '^Error: .*failed to find target executable' "$e"; then rc=127; fi
  cat "$e" >&2; rm -f "$e"
  return "$rc"
}

# nd_platform_unbound_exec <cmd...>: run cmd in the Unbound container as the
# unbound user (the only uid the control socket admits).
nd_platform_unbound_exec() {
  _nd_mac_exec "${CONTAINER_BIN:-container}" --user unbound "${ND_UNBOUND_CONTAINER:-unbound}" "$@"
}

# ─── Health operations (Sub-plan 3, ARCH-02) ───────────────────────────────
# Used by lib/health.sh, which provides nd_bounded (a command run under a
# deadline) and the scratch directory $_ND_H_TMP.
#
#   CONTAINER_BIN          the container CLI when set
#   ND_CONTAINER_FALLBACK  where Homebrew installs it (default
#                          /opt/homebrew/bin/container; launchd's PATH lacks it)

_ND_MAC_PIHOLE=172.31.240.250

# nd_platform_dns_addr: Pi-hole's address on dnsnet (PIHOLE_IP in
# mac/start-container.sh); the host resolves through it on port 53.
nd_platform_dns_addr() { printf '%s\n' "$_ND_MAC_PIHOLE"; }

# nd_platform_runtime_bin: the container CLI, or 1 when it is not installed.
nd_platform_runtime_bin() {
  local f="${ND_CONTAINER_FALLBACK:-/opt/homebrew/bin/container}"
  if [ -n "${CONTAINER_BIN:-}" ] && [ -x "$CONTAINER_BIN" ]; then printf '%s\n' "$CONTAINER_BIN"; return 0; fi
  command -v container 2>/dev/null && return 0
  if [ -x "$f" ]; then printf '%s\n' "$f"; return 0; fi
  return 1
}

# _nd_mac_table <deadline> <out> [-a]: `container ls` rows as
# "name<TAB>state" (the plain table; `container ps` does not exist). An
# "Error:" line fails even when the CLI exits 0. Codes as for
# nd_platform_runtime_list.
_nd_mac_table() {
  local bin rc
  bin="$(nd_platform_runtime_bin)" || return 3
  nd_bounded "$1" "$2.raw" "$2.err" "$bin" ls ${3:+"$3"}
  rc=$?
  [ "$rc" -eq 124 ] && return 124
  if [ "$rc" -ne 0 ] || grep -q '^Error:' "$2.raw" "$2.err" 2>/dev/null \
     || ! head -n 1 "$2.raw" | grep -Eq '^ID[[:space:]].*[[:space:]]STATE([[:space:]]|$)'; then
    { grep -h '^Error:' "$2.raw" "$2.err" 2>/dev/null; cat "$2.err" "$2.raw" 2>/dev/null; printf 'container ls exited %s without its table\n' "$rc"; } | head -n 1 >"$2.err.1"
    mv -f "$2.err.1" "$2.err"
    return 4
  fi
  awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "STATE") s = i; next }
       s && NF >= s { print $1 "\t" $s }' "$2.raw" >"$2"
  return 0
}

nd_platform_runtime_list() {
  local rc
  _nd_mac_table "$1" "$2.tab"; rc=$?
  [ -f "$2.tab.err" ] && mv -f "$2.tab.err" "$2.err"
  [ "$rc" -eq 0 ] || return "$rc"
  awk -F '\t' '$2 == "running" { print $1 }' "$2.tab" >"$2"
}

nd_platform_installed_variant() {
  local t="${_ND_H_TMP:-${TMPDIR:-/tmp}}/installed-variant" v
  # [deadline]: the caller's command deadline (recovery passes its own).
  _nd_mac_table "${1:-${ND_HEALTH_CMD_DEADLINE:-10}}" "$t" -a || return 1
  for v in haproxy socat; do
    if awk -F '\t' -v n="tor-$v" '$1 == n { f = 1 } END { exit !f }' "$t"; then printf '%s\n' "$v"; return 0; fi
  done
  return 1
}

nd_platform_proxy_exec() {
  local c="$1" bin
  shift
  bin="$(nd_platform_runtime_bin)" || { printf 'container CLI not found\n' >&2; return 127; }
  _nd_mac_exec "$bin" "$c" "$@"
}

# nd_platform_dns_owner <deadline>: "verdict<TAB>reason". macOS resolves per
# network service, not through /etc/resolv.conf: every enabled service
# (networksetup) must list only Pi-hole's address, and the effective default
# resolver (scutil --dns, resolver #1 of the unscoped configuration) must be
# it too.
nd_platform_dns_owner() {
  local dl="$1" t="$_ND_H_TMP/owner" svc got bad="" n=0 rc ns
  nd_bounded "$dl" "$t.list" "$t.err" networksetup -listallnetworkservices; rc=$?
  case "$rc" in
    0) ;;
    124) printf 'indeterminate\tdeadline: networksetup -listallnetworkservices gave no answer within %ss\n' "$dl"; return 0 ;;
    127) printf 'indeterminate\tnetworksetup not found\n'; return 0 ;;
    *) printf 'indeterminate\tnetworksetup -listallnetworkservices exited %s: %s\n' "$rc" "$(head -n 1 "$t.err")"; return 0 ;;
  esac
  # Line 1 explains the asterisk; a leading * marks a disabled service.
  tail -n +2 "$t.list" | grep -v '^\*' | grep -v '^[[:space:]]*$' >"$t.svcs"
  while IFS= read -r svc; do
    n=$((n + 1))
    nd_bounded "$dl" "$t.svc" "$t.err" networksetup -getdnsservers "$svc"; rc=$?
    case "$rc" in
      0) ;;
      124) printf 'indeterminate\tdeadline: networksetup -getdnsservers %s gave no answer within %ss\n' "$svc" "$dl"; return 0 ;;
      *) printf 'indeterminate\tnetworksetup -getdnsservers %s exited %s\n' "$svc" "$rc"; return 0 ;;
    esac
    got="$(awk '/^[0-9A-Fa-f:.]+$/ { printf "%s%s", sep, $1; sep = "," }' "$t.svc")"
    [ "$got" = "$_ND_MAC_PIHOLE" ] || bad="$bad${bad:+; }$svc=${got:-unset}"
  done <"$t.svcs"
  if [ "$n" -eq 0 ]; then printf 'unhealthy\tno enabled network service\n'; return 0; fi
  nd_bounded "$dl" "$t.scutil" "$t.err" scutil --dns; rc=$?
  case "$rc" in
    0) ;;
    124) printf 'indeterminate\tdeadline: scutil --dns gave no answer within %ss\n' "$dl"; return 0 ;;
    *) printf 'indeterminate\tscutil --dns exited %s\n' "$rc"; return 0 ;;
  esac
  ns="$(awk '/^DNS configuration \(for scoped queries\)/ { exit }
             /^resolver #/ { r++; next }
             r == 1 && $1 == "nameserver[0]" { print $3; exit }' "$t.scutil")"
  if [ -n "$bad" ]; then printf 'unhealthy\tservices not pinned to %s: %s\n' "$_ND_MAC_PIHOLE" "$bad"; return 0; fi
  if [ "$ns" != "$_ND_MAC_PIHOLE" ]; then
    printf 'unhealthy\tscutil resolver #1 nameserver is %s (want %s)\n' "${ns:-absent}" "$_ND_MAC_PIHOLE"; return 0
  fi
  printf 'healthy\tall %s active services use %s; scutil resolver #1 is %s\n' "$n" "$_ND_MAC_PIHOLE" "$ns"
}

# ─── State operations (Sub-plan 3, ARCH-02 state.sh) ───────────────────────
#
#   ND_STATE_DIR   the controller state directory (default
#                  ~/Library/Application Support/nice-dns/controller)

nd_platform_state_dir() {
  printf '%s\n' "${ND_STATE_DIR:-${HOME:?HOME is unset}/Library/Application Support/nice-dns/controller}"
}

# nd_platform_boot_id: an identifier that changes on every boot.
nd_platform_boot_id() { sysctl -n kern.bootsessionuuid 2>/dev/null; }

# ─── Recovery operations (Sub-plan 3, Task 1.3; ARCH-02, ARCH-03) ──────────
# Used by lib/recovery.sh with nd_bounded (lib/health.sh). <tmp> is the
# caller's scratch directory.
#
#   ND_PROXY_CONTAINER   the Tor proxy container (default: the running
#                        tor-haproxy or tor-socat, else the created one)

_ND_MAC_AGENT=org.nice-dns.start-container

nd_platform_proxy_container() {
  local v
  if [ -n "${ND_PROXY_CONTAINER:-}" ]; then printf '%s\n' "$ND_PROXY_CONTAINER"; return 0; fi
  if nd_platform_runtime_list "$1" "$2/running" >/dev/null 2>&1; then
    for v in haproxy socat; do
      grep -qx "tor-$v" "$2/running" && { printf 'tor-%s\n' "$v"; return 0; }
    done
  fi
  v="$(nd_platform_installed_variant "$1")" || return 1
  printf 'tor-%s\n' "$v"
}

# nd_platform_container_generation <container> <deadline> <tmp>: the
# container's STATE and STARTED columns of `container ls -a` (Apple
# container names are the IDs; a recreated container has a new start time).
# STARTED is the last field: MEMORY prints as two words ("256 MB"), so
# header positions after it do not line up with the rows.
nd_platform_container_generation() {
  local bin
  bin="$(nd_platform_runtime_bin)" || return 3
  nd_bounded "$2" "$3/gen" "$3/gen.err" "$bin" ls -a || return 1
  # An "Error:" banner with exit 0 is not a table (as in _nd_mac_table).
  grep -q '^Error:' "$3/gen" "$3/gen.err" 2>/dev/null && return 1
  # STARTED is an ISO timestamp, one token (Apple container 1.4.1, observed
  # on macOS 26.6.2: "2026-09-23T22:16:51Z"). Only a running row has one: a
  # stopped row ends in its memory unit ("MB"), which is no start at all.
  awk -v n="$1" 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "STATE") s = i; next }
       $1 == n && s && $s == "running" { print $1 " " $s " " $NF; f = 1; exit }
       END { exit !f }' "$3/gen"
}

# nd_platform_restart_scope: what nd_platform_restart_proxy restarts.
nd_platform_restart_scope() { printf 'stack\n'; }

# nd_platform_restart_proxy <container> <deadline> <tmp>: kick the stack's
# LaunchAgent (-k stops a running instance first); mac/start-container.sh
# recreates the whole stack (pi-hole, unbound, proxy) when the chain is not
# healthy. This is the pre-Sub-plan-3 fallback, kept as is: a restart of the
# proxy container alone on Apple container is not qualified yet (Task 2.3,
# live). <container> is only verified afterwards, not targeted.
nd_platform_restart_proxy() {
  local d="${XDG_STATE_HOME:-${HOME:?HOME is unset}/.local/state}/nice-dns"
  # The agent's fast path keeps a stack that looks healthy; a restart the
  # controller decided must rebuild it (mac/start-container.sh fast_path_ok).
  (umask 077 && mkdir -p "$d" && printf '%s\n' "controller $(date +%s)" >"$d/restart-requested") || return 1
  # A kickstart that failed withdraws the request, or a later ordinary run of
  # the agent would rebuild a stack nobody asked it to rebuild.
  nd_bounded "$2" "$3/svc" "$3/svc.err" launchctl kickstart -k "gui/$(id -u)/$_ND_MAC_AGENT" && return 0
  set -- "$?"; rm -f "$d/restart-requested"; return "$1"
}

# nd_platform_runtime_repairs: the runtime faults nd_platform_repair_runtime
# can repair here; the policy escalates any other (ND_POLICY_RUNTIME_REPAIRS).
nd_platform_runtime_repairs() { printf 'runtime-down containers-missing\n'; }

# nd_platform_repair_runtime <fault> <deadline> <tmp>: 0 issued; 3 no repair.
# A runtime that does not answer: `container system start` (what the
# LaunchAgent itself does first). Missing containers: start the LaunchAgent
# if it is not running (no -k), which recreates what is missing.
nd_platform_repair_runtime() {
  local bin
  case "$1" in
    runtime-down)
      bin="$(nd_platform_runtime_bin)" || return 3
      nd_bounded "$2" "$3/rep" "$3/rep.err" "$bin" system start ;;
    containers-missing) nd_bounded "$2" "$3/rep" "$3/rep.err" launchctl kickstart "gui/$(id -u)/$_ND_MAC_AGENT" ;;
    *) return 3 ;;
  esac
}

# ─── Bridge operations (Sub-plan 3, Task 2.2; ARCH-07) ─────────────────────
#
#   ND_BRIDGE_CONFIG_DIR   bridges.env and bridge-pool.tsv (default
#                          $XDG_CONFIG_HOME/nice-dns or ~/.config/nice-dns)

nd_platform_bridge_dir() { printf '%s\n' "${ND_BRIDGE_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME:?HOME is unset}/.config}/nice-dns}"; }

# nd_platform_bridge_eval <variant> <candidate file name> <deadline> <tmp>:
# the image's bridge-eval, always on dnsnet (the only network the proxy's
# probes may use). Its container takes a free dnsnet address, so it runs only
# while pi-hole, unbound and the proxy hold theirs (exit 3 otherwise).
# _nd_mac_stack_addressed <proxy variant> <deadline> <tmp>: 0 when pi-hole,
# unbound and the proxy run on .250/.251/.252 (mac/start-container.sh's
# addresses): a probe container started otherwise could take one of them
# (the 2026-09-21/23 incident, measured by the legacy mac/bridge-eval.sh).
_nd_mac_stack_addressed() {
  local bin
  bin="$(nd_platform_runtime_bin)" || return 1
  nd_bounded "$2" "$3/addr" "$3/addr.err" "$bin" ls || return 1
  awk -v t="tor-$1" 'NR == 1 { next }
    { ip = ""; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\//) { ip = $i; sub(/\/.*/, "", ip) } }
    $1 == "pi-hole" && ip == "172.31.240.250" { a++ } $1 == "unbound" && ip == "172.31.240.251" { a++ } $1 == t && ip == "172.31.240.252" { a++ }
    END { exit !(a == 3) }' "$3/addr"
}

# The start-container agent's stack lock (mac/start-container.sh STACK_LOCK):
# a mkdir lock whose pid file names the holder; a holder that no longer
# runs is reaped, as the agent does.
_ND_MAC_STACK_LOCK="${XDG_STATE_HOME:-${HOME:?HOME is unset}/.local/state}/nice-dns/stack.lock"
_nd_mac_stack_lock() {
  local i=0 max="${ND_BRIDGE_STACK_LOCK_S:-600}" holder
  mkdir -p "$(dirname "$_ND_MAC_STACK_LOCK")" || return 1
  until mkdir "$_ND_MAC_STACK_LOCK" 2>/dev/null; do
    holder="$(cat "$_ND_MAC_STACK_LOCK/pid" 2>/dev/null)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "${_ND_MAC_STACK_LOCK:?}"; continue; fi
    i=$((i + 1)); [ "$i" -lt "$max" ] || return 1
    sleep 1
  done
  printf '%s\n' "$$" >"$_ND_MAC_STACK_LOCK/pid"
}

nd_platform_bridge_eval() {
  local d bin n rc
  d="$(nd_platform_bridge_dir)"
  bin="$(nd_platform_runtime_bin)" || return 3
  nd_platform_runtime_list "$3" "$4/running" >/dev/null 2>&1 || return 3
  n="$(grep -cx -e pi-hole -e unbound -e "tor-$1" "$4/running")"
  [ "$n" -eq 3 ] || return 3
  _nd_mac_stack_addressed "$1" "$3" "$4" || return 3
  # Hold the agent's stack lock while the probe container exists, so no
  # stack rebuild starts underneath it; re-check the addresses once held.
  _nd_mac_stack_lock || return 3
  if ! _nd_mac_stack_addressed "$1" "$3" "$4"; then rm -rf "${_ND_MAC_STACK_LOCK:?}"; return 3; fi
  nd_bounded "$3" "$4/eval" "$4/eval.err" "$bin" run --rm --network dnsnet \
    -v "$d:/pool" --entrypoint /bin/bridge-eval "docker.io/sureserver/tor-$1:latest" \
    -pool /pool/bridge-pool.tsv -out "/pool/$2" -count 7 -window 150 -grace 20
  rc=$?
  rm -rf "${_ND_MAC_STACK_LOCK:?}"
  return "$rc"
}
