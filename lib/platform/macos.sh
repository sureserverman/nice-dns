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

# nd_platform_unbound_exec <cmd...>: run cmd in the Unbound container as the
# unbound user (the only uid the control socket admits).
nd_platform_unbound_exec() {
  "${CONTAINER_BIN:-container}" exec --user unbound "${ND_UNBOUND_CONTAINER:-unbound}" "$@"
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
  _nd_mac_table "${ND_HEALTH_CMD_DEADLINE:-10}" "$t" -a || return 1
  for v in haproxy socat; do
    if awk -F '\t' -v n="tor-$v" '$1 == n { f = 1 } END { exit !f }' "$t"; then printf '%s\n' "$v"; return 0; fi
  done
  return 1
}

nd_platform_proxy_exec() {
  local c="$1" bin
  shift
  bin="$(nd_platform_runtime_bin)" || { printf 'container CLI not found\n' >&2; return 127; }
  "$bin" exec "$c" "$@"
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
