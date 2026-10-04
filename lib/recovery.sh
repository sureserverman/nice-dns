# shellcheck shell=bash
# nice-dns route application and recovery actions (ARCH-03 apply_route and
# request_recovery, ARCH-04, ARCH-07). Sourced; Bash 3.2 compatible (macOS
# /bin/bash), safe under set -u.
#
#   apply_route <route_id> <generation>   select a route from routes/providers.tsv
#   reconcile_route                       bring the running route to the desired one
#   seed_route <route_id> <generation>    write the first include before Unbound starts
#   route_readback                        route<TAB>generation<TAB>address running now
#   request_recovery <component> <request_id>
#                                         ask the proxy image to restart Tor and
#                                         wait for its acknowledgement
#   nd_recovery_restart_service <request_id>
#                                         the service-level proxy restart
#   nd_recovery_restart_tor <request_id>  request_recovery, then one service
#                                         restart when it is not acknowledged
#                                         (not-acknowledged, unsupported or
#                                         unreachable): the only Tor restart path
#   repair_runtime <fault> <request_id>   repair the runtime fault observed
#   nd_recovery_apply <decision> <request_id> <route_generation>
#                                         carry out one lib/policy.sh decision
#   nd_recovery_tick <active|shadow> <observations>
#                                         one controller pass (see below)
#
# Recovery (Sub-plan 3, Task 1.3). Every action is recorded in the journal
# $(nd_platform_state_dir)/recovery.tsv as separate phases:
#   requested -> acknowledged | not-acknowledged | refused | unsupported
#   -> (a later pass) ready | not-ready
# An acknowledgement is the image's or runtime's own answer that the action
# happened: a new Tor generation and pid from the proxy's control directory
# (/app/data/control, org.nice-dns.transport.restart=control-dir-ack), or a
# new container start for a service restart, or the runtime answering again.
# Writing a request is never an acknowledgement, and the old
# /tmp/tor-restart-flag is never used. Readiness is a later observation, never
# part of the acknowledgement. Every runtime command runs under nd_bounded,
# and every wait is bounded in wall-clock seconds, so one action ends well
# inside the state lock's 600 s lease. When ND_RECOVERY_LOCK_TOKEN is set (a
# tick sets it), the lock is re-checked before each step that changes
# anything, and a lost lock stops the action (result lock-lost, exit 5).
# The acknowledgement is the proxy image's own answer; readiness of a Tor
# restart is corroborated on the host side through Unbound (the locally built
# image) resolving over its TLS-verified route, which the proxy cannot forge
# (DEC-006). The in-image restart keeps Tor's data (only the tor child is
# respawned). The service restart recreates the container; Tor's data
# (/app/data: its state and, since Sub-plan 5, its log) is on a volume on both
# platforms and survives it (deb/quadlet/tor-*.container,
# mac/start-container.sh).
#
# The recovery functions and the journal expect the caller to hold the state
# lock (nd_recovery_tick and the CLI's run path do); the journal's rotation is
# not locked on its own. The service restart is proxy-only on Linux and
# stack-wide on macOS (nd_platform_restart_scope).
#
# Recovery output: key<TAB>value lines: result, component, request_id,
# generation_before, generation, detail. Exit: 0 acknowledged; 1
# not-acknowledged; 2 refused (bad argument); 3 unsupported (the image or
# platform offers no such action); 4 unreachable (no proxy container); 5
# lock-lost.
#
# The route directory (nd_platform_route_dir) is mounted into the Unbound
# container at /etc/unbound/route and holds:
#   forward-route.conf          the active include (rendered here, 0644)
#   .forward-route.conf.staged  a candidate being validated
#   .forward-route.conf.prev    the include before the last change (rollback)
#   desired.tsv                 schema, route and generation last requested
#                               (lib/state.sh owns desired state and
#                               generations; this file and the stale-generation
#                               check here are the route layer's own guard)
#
# apply_route: record the desired route; stage the include; have the image
# validate it (nice-dns-unbound-start check-route: shape, then
# unbound-checkconf on the complete candidate config); keep the previous
# include; rename the candidate over the active one; reload_keep_cache; read
# the route marker back through the control socket; then resolve through the
# new forwarder (nice-dns-unbound-start probe-route: a fresh TLS session with
# Unbound's trust store and the route's name, so the cache cannot answer for
# it; ND_ROUTE_PROBE_NAME, default "."). A failure after the rename restores
# the previous include the same way (the restore is read back, not probed). An unchanged route is
# never reloaded. A reload is only issued after validation: Unbound exits
# when it reloads a config it cannot parse.
#
# Each call prints key<TAB>value lines:
#   result      applied unchanged converged none restored refused conflict escalate
#   route generation forwarder   what runs after the call ('-' when unknown)
#   desired_route desired_generation
#   detail      one line
# Exit: 0 applied, unchanged, converged or none; 1 restored (the change failed
# and the previous route runs again); 2 refused (the active include was not
# touched); 3 escalate (the running route is not known to be a validated one;
# the forward-zone is never removed); 4 conflict (stale generation).

ND_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_ND_CTL=/usr/share/nice-dns/control.conf
_ND_CTR_ROUTE_DIR=/etc/unbound/route
_ND_START=/usr/local/bin/nice-dns-unbound-start

if ! declare -F nd_bounded >/dev/null; then
  # shellcheck source=lib/health.sh
  . "$ND_LIB_DIR/health.sh" || return 1
fi
if ! declare -F nd_state_lock >/dev/null; then
  # shellcheck source=lib/state.sh
  . "$ND_LIB_DIR/state.sh" || return 1
fi
if ! declare -F nd_policy_decide >/dev/null; then
  # shellcheck source=lib/policy.sh
  . "$ND_LIB_DIR/policy.sh" || return 1
fi
if ! declare -F nd_platform_route_addr >/dev/null; then
  case "${ND_PLATFORM:-$(uname -s)}" in
    linux|Linux)
      # shellcheck source=lib/platform/linux.sh
      . "$ND_LIB_DIR/platform/linux.sh" ;;
    macos|Darwin)
      # shellcheck source=lib/platform/macos.sh
      . "$ND_LIB_DIR/platform/macos.sh" ;;
    *) printf 'recovery.sh: unsupported platform %s\n' "${ND_PLATFORM:-$(uname -s)}" >&2; return 1 ;;
  esac
fi

# nd_route_checkpoint <step>: called at each step of a route change (steps:
# desired-written staged before-rename after-rename after-reload
# rollback-rename). A non-zero return fails that step. The default does
# nothing; tests replace it to interrupt a change at a chosen point.
nd_route_checkpoint() { return 0; }

_nd_routes_file() { printf '%s\n' "${ND_ROUTES_FILE:-$ND_LIB_DIR/../routes/providers.tsv}"; }

# _nd_route_table <route>: validate the whole table; print the route's
# "port<TAB>tls_name<TAB>provider<TAB>class". 1 unknown route, 2 bad table
# (problems on stderr).
_nd_route_table() {
  local f
  f="$(_nd_routes_file)"
  if [ ! -f "$f" ] || [ -L "$f" ]; then printf 'route table %s is missing or a symlink\n' "$f" >&2; return 2; fi
  awk -F '\t' -v want="$1" '
    function bad(m) { print "route table line " NR ": " m > "/dev/stderr"; err = 1 }
    /\r/ { bad("carriage return"); next }
    /^#/ || /^$/ { next }
    !schema { if ($0 != "schema\tnice-dns-routes/1") bad("the first row must be schema<TAB>nice-dns-routes/1"); schema = 1; next }
    {
      if (NF != 5) { bad("expected 5 tab-separated fields (route port tls_name provider class)"); next }
      if ($1 !~ /^[a-z0-9]+(-[a-z0-9]+)*$/) bad("bad route id \"" $1 "\"")
      if ($2 !~ /^[1-9][0-9]*$/ || $2 + 0 > 65535) bad("route " $1 ": bad port \"" $2 "\"")
      if ($3 !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/) bad("route " $1 ": missing or invalid TLS name \"" $3 "\"")
      if ($4 !~ /^[a-z0-9]+(-[a-z0-9]+)*$/) bad("route " $1 ": bad provider \"" $4 "\"")
      if ($5 != "identity" && $5 != "compat") bad("route " $1 ": bad class \"" $5 "\"")
      if ($1 in seen) bad("duplicate route " $1)
      if ($2 in port) bad("port " $2 " is bound to two routes")
      seen[$1] = 1; port[$2] = 1
      if ($1 == want) row = $2 "\t" $3 "\t" $4 "\t" $5
    }
    END {
      if (!schema) bad("no schema row")
      if (err) exit 2
      if (row == "") exit 1
      print row
    }' "$f"
}

_nd_route_out() {
  printf 'result\t%s\nroute\t%s\ngeneration\t%s\nforwarder\t%s\n' "$1" "$2" "$3" "$4"
  printf 'desired_route\t%s\ndesired_generation\t%s\n' "${_ND_DES_ROUTE:--}" "${_ND_DES_GEN:--}"
  printf 'detail\t%s\n' "$(printf '%s' "$5" | tr '\t\n' '  ')"
}

# _nd_route_render <route> <generation> <ADDR@PORT#NAME>
_nd_route_render() {
  printf '# nice-dns managed route include (lib/recovery.sh renders this file; do not edit)\n'
  printf '# route\t%s\n# generation\t%s\n' "$1" "$2"
  printf 'server:\n    local-zone: "nice-dns-route.invalid." static\n'
  printf "    local-data: 'nice-dns-route.invalid. 0 IN TXT \"route=%s generation=%s\"'\n" "$1" "$2"
  printf 'forward-zone:\n    name: "."\n    forward-tls-upstream: yes\n    forward-first: no\n    forward-addr: %s\n' "$3"
}

# _nd_route_file_info <file>: "route<TAB>generation<TAB>ADDR@PORT#NAME" from a
# rendered include.
_nd_route_file_info() {
  if [ ! -f "$1" ] || [ -L "$1" ]; then return 1; fi
  awk -F '\t' '
    $1 == "# route" { r = $2 }
    $1 == "# generation" { g = $2 }
    /^[[:space:]]*forward-addr:/ { sub(/^[[:space:]]*forward-addr:[[:space:]]*/, ""); n++; a = $0 }
    END { if (r == "" || g == "" || n != 1) exit 1; print r "\t" g "\t" a }' "$1"
}

# route_readback: the route marker and root forwarder address of the running
# Unbound, read through the control socket: "route<TAB>generation<TAB>address".
# 1 when control is unreachable or the running config has no single marker
# and single root forwarder.
route_readback() {
  local data fwd
  data="$(nd_platform_unbound_exec unbound-control -c "$_ND_CTL" list_local_data 2>/dev/null)" || return 1
  fwd="$(nd_platform_unbound_exec unbound-control -c "$_ND_CTL" list_forwards 2>/dev/null)" || return 1
  printf '%s\n--forwards--\n%s\n' "$data" "$fwd" | awk '
    /^--forwards--$/ { part = 2; next }
    part != 2 && $1 == "nice-dns-route.invalid." && $4 == "TXT" {
      if (match($0, /"route=[a-z0-9-]+ generation=[0-9]+"/)) {
        split(substr($0, RSTART + 1, RLENGTH - 2), kv, /[ =]/); r = kv[2]; g = kv[4]; nm++
      }
    }
    part == 2 && $1 == "." && $3 == "forward" {
      nf++; a = ""; na = 0
      # Unbound 1.25 prints the address only; drop any @port#name suffix so
      # a release that adds it still compares by address.
      for (i = 4; i <= NF; i++) if ($i !~ /^\+/) { a = $i; sub(/[@#].*/, "", a); na++ }
    }
    END { if (nm != 1 || nf != 1 || na != 1) exit 1; print r "\t" g "\t" a }'
}

# _nd_route_wait_runtime <route> <generation> <address>: poll the readback
# (a reload completes after unbound-control has answered "ok"). _ND_RT holds
# the last readback.
_nd_route_wait_runtime() {
  local i=0 max=$(( ${ND_ROUTE_READBACK_SECONDS:-15} * 4 ))
  while :; do
    _ND_RT="$(route_readback)" || _ND_RT="unreadable"
    [ "$_ND_RT" = "$1	$2	$3" ] && return 0
    i=$((i + 1))
    [ "$i" -lt "$max" ] || return 1
    sleep 0.25
  done
}

_nd_route_reload() {
  local out
  out="$(nd_platform_unbound_exec unbound-control -c "$_ND_CTL" reload_keep_cache 2>&1)" || return 1
  printf '%s\n' "$out" | grep -qx ok
}

# _nd_route_resolves: resolution through the running route, bypassing the
# cache (see the header).
_nd_route_resolves() {
  nd_platform_unbound_exec "$_ND_START" probe-route "${ND_ROUTE_PROBE_NAME:-.}" 2>&1
}

# _nd_route_check <container path>: the image validates a route include.
_nd_route_check() {
  nd_platform_unbound_exec "$_ND_START" check-route "$1" 2>&1
}

# _nd_route_dir_ok <dir>: a real directory owned by us, not writable by group
# or others, whose managed files are neither symlinks nor group/other-writable.
_nd_route_dir_ok() {
  local f
  if [ -L "$1" ]; then printf 'route directory %s is a symlink\n' "$1"; return 1; fi
  if [ ! -d "$1" ]; then printf 'route directory %s is missing\n' "$1"; return 1; fi
  if [ -z "$(find "$1" -maxdepth 0 -user "$(id -u)" 2>/dev/null)" ]; then
    printf 'route directory %s is not owned by uid %s\n' "$1" "$(id -u)"; return 1
  fi
  if [ -n "$(find "$1" -maxdepth 0 \( -perm -0020 -o -perm -0002 \) 2>/dev/null)" ]; then
    printf 'route directory %s is writable by group or others\n' "$1"; return 1
  fi
  for f in forward-route.conf .forward-route.conf.staged .forward-route.conf.prev desired.tsv; do
    if [ -L "$1/$f" ]; then printf '%s/%s is a symlink\n' "$1" "$f"; return 1; fi
    if [ -e "$1/$f" ] && [ -n "$(find "$1/$f" -maxdepth 0 \( -perm -0020 -o -perm -0002 \) 2>/dev/null)" ]; then
      printf '%s/%s is writable by group or others\n' "$1" "$f"; return 1
    fi
  done
  return 0
}

_nd_route_read_desired() {
  _ND_DES_ROUTE="" _ND_DES_GEN=""
  [ -e "$1/desired.tsv" ] || return 0
  [ "$(head -n 1 "$1/desired.tsv")" = "schema	nice-dns-route-desired/1" ] || return 1
  _ND_DES_ROUTE="$(awk -F '\t' '$1 == "route" { print $2 }' "$1/desired.tsv")"
  _ND_DES_GEN="$(awk -F '\t' '$1 == "generation" { print $2 }' "$1/desired.tsv")"
  case "$_ND_DES_ROUTE" in ''|*[!a-z0-9-]*) _ND_DES_ROUTE="" _ND_DES_GEN=""; return 1 ;; esac
  case "$_ND_DES_GEN" in ''|*[!0-9]*) _ND_DES_ROUTE="" _ND_DES_GEN=""; return 1 ;; esac
  return 0
}

_nd_route_write_desired() {
  (umask 077 && printf 'schema\tnice-dns-route-desired/1\nroute\t%s\ngeneration\t%s\n' "$2" "$3" >"$1/.desired.tsv.tmp") \
    && mv -f "$1/.desired.tsv.tmp" "$1/desired.tsv"
}

# _nd_route_resolve <route>: sets _ND_FWD (ADDR@PORT#NAME) and _ND_ADDR, or
# prints why not. 1 unknown route or bad table, 2 bad platform address.
_nd_route_resolve() {
  local row rc port name
  row="$(_nd_route_table "$1" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ]; then printf "route '%s' is not in the route table %s\n" "$1" "$(_nd_routes_file)"; return 1; fi
  if [ "$rc" -ne 0 ]; then printf 'route table is invalid: %s\n' "$row"; return 1; fi
  port="$(printf '%s\n' "$row" | cut -f1)"
  name="$(printf '%s\n' "$row" | cut -f2)"
  _ND_ADDR="$(nd_platform_route_addr)"
  case "$_ND_ADDR" in
    *[!0-9.]*|'') printf "platform route address '%s' is not an IPv4 address\n" "$_ND_ADDR"; return 2 ;;
  esac
  _ND_FWD="$_ND_ADDR@$port#$name"
}

# Generations start at 1; 0 is reserved for the image default include.
_nd_route_gen_ok() {
  case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 15 ]
}

# _nd_route_escalate <detail>: report what runs (from the readback), exit 3.
_nd_route_escalate() {
  local rt r="-" g="-" a="-"
  if rt="$(route_readback)"; then
    r="$(printf '%s\n' "$rt" | cut -f1)"; g="$(printf '%s\n' "$rt" | cut -f2)"; a="$(printf '%s\n' "$rt" | cut -f3)"
  fi
  _nd_route_out escalate "$r" "$g" "$a" "$1"
  return 3
}

# _nd_route_rollback <dir> <why>: restore .prev (validated first), reload and
# read it back.
_nd_route_rollback() {
  local d="$1" p="$1/.forward-route.conf.prev" info out r g f
  [ -f "$p" ] || { _nd_route_escalate "$2; no previous route to restore"; return 3; }
  info="$(_nd_route_file_info "$p")" || { _nd_route_escalate "$2; the previous route file is not a rendered include"; return 3; }
  out="$(_nd_route_check "$_ND_CTR_ROUTE_DIR/.forward-route.conf.prev")" \
    || { _nd_route_escalate "$2; the previous route failed validation: $out"; return 3; }
  nd_route_checkpoint rollback-rename || { _nd_route_escalate "$2; interrupted before restoring the previous route"; return 3; }
  mv -f "$p" "$d/forward-route.conf" || { _nd_route_escalate "$2; cannot restore the previous route file"; return 3; }
  r="$(printf '%s\n' "$info" | cut -f1)"; g="$(printf '%s\n' "$info" | cut -f2)"; f="$(printf '%s\n' "$info" | cut -f3)"
  if ! _nd_route_reload || ! _nd_route_wait_runtime "$r" "$g" "${f%%@*}"; then
    _nd_route_escalate "$2; restoring route $r generation $g did not take effect ($_ND_RT)"; return 3
  fi
  _nd_route_out restored "$r" "$g" "$f" "$2; restored route $r generation $g"
  return 1
}

# _nd_route_activate <dir> <route> <generation> <forwarder> <address>: the
# include is in place; reload and read it back, else roll back.
_nd_route_activate() {
  local why="" out
  if ! nd_route_checkpoint after-rename; then why="interrupted after the rename"
  elif ! _nd_route_reload; then why="reload_keep_cache failed"
  elif ! nd_route_checkpoint after-reload; then why="interrupted after the reload"
  elif ! _nd_route_wait_runtime "$2" "$3" "$5"; then why="readback does not show route $2 generation $3 at $5 (got: $_ND_RT)"
  elif ! out="$(_nd_route_resolves)"; then why="route $2 did not resolve ($out)"
  fi
  if [ -z "$why" ]; then
    _nd_route_out applied "$2" "$3" "$4" "route $2 generation $3 active after reload_keep_cache"
    return 0
  fi
  _nd_route_rollback "$1" "$why"
}

apply_route() {
  local route="${1:-}" gen="${2:-}" dir msg cur rt staged
  _ND_DES_ROUTE="" _ND_DES_GEN="" _ND_RT=""
  if ! _nd_route_gen_ok "$gen"; then _nd_route_out refused - - - "generation must be a positive integer, got '$gen'"; return 2; fi
  msg="$(_nd_route_resolve "$route")" || { _nd_route_out refused - - - "$msg"; return 2; }
  _nd_route_resolve "$route" >/dev/null
  dir="$(nd_platform_route_dir)"
  msg="$(_nd_route_dir_ok "$dir")" || { _nd_route_out refused - - - "$msg"; return 2; }
  _nd_route_read_desired "$dir" || { _nd_route_out refused - - - "$dir/desired.tsv is malformed"; return 2; }
  if [ -n "$_ND_DES_GEN" ]; then
    if [ "$gen" -lt "$_ND_DES_GEN" ] || { [ "$gen" -eq "$_ND_DES_GEN" ] && [ "$route" != "$_ND_DES_ROUTE" ]; }; then
      _nd_route_out conflict - - - "generation $gen for $route is stale: desired is $_ND_DES_ROUTE generation $_ND_DES_GEN"
      return 4
    fi
  fi
  _nd_route_write_desired "$dir" "$route" "$gen" || { _nd_route_out refused - - - "cannot write $dir/desired.tsv"; return 2; }
  _ND_DES_ROUTE="$route" _ND_DES_GEN="$gen"
  nd_route_checkpoint desired-written || { _nd_route_out refused - - - "interrupted after recording the desired route"; return 2; }

  # Unchanged: the include already selects this forwarder and Unbound runs it.
  cur="$(_nd_route_file_info "$dir/forward-route.conf")" || cur=""
  rt="$(route_readback)" || rt=""
  if [ -n "$cur" ] && [ "$(printf '%s\n' "$cur" | cut -f1,3)" = "$route	$_ND_FWD" ] \
     && [ "$rt" = "$(printf '%s\n' "$cur" | cut -f1,2)	$_ND_ADDR" ]; then
    _nd_route_out unchanged "$route" "$(printf '%s\n' "$cur" | cut -f2)" "$_ND_FWD" "route $route already active; no reload"
    return 0
  fi

  staged="$dir/.forward-route.conf.staged"
  rm -f "$staged"
  if ! (umask 022 && _nd_route_render "$route" "$gen" "$_ND_FWD" >"$staged"); then
    rm -f "$staged"; _nd_route_out refused - - - "cannot write $staged"; return 2
  fi
  chmod 0644 "$staged"
  nd_route_checkpoint staged || { rm -f "$staged"; _nd_route_out refused - - - "interrupted after staging"; return 2; }
  msg="$(_nd_route_check "$_ND_CTR_ROUTE_DIR/.forward-route.conf.staged")" \
    || { rm -f "$staged"; _nd_route_out refused - - - "Unbound refused the staged route: $msg"; return 2; }
  if [ -f "$dir/forward-route.conf" ]; then
    if ! { cp -p "$dir/forward-route.conf" "$dir/.forward-route.conf.prev.tmp" && mv -f "$dir/.forward-route.conf.prev.tmp" "$dir/.forward-route.conf.prev"; }; then
      rm -f "$staged" "$dir/.forward-route.conf.prev.tmp"; _nd_route_out refused - - - "cannot keep the previous route"; return 2
    fi
  fi
  nd_route_checkpoint before-rename || { rm -f "$staged"; _nd_route_out refused - - - "interrupted before the rename"; return 2; }
  mv -f "$staged" "$dir/forward-route.conf" || { rm -f "$staged"; _nd_route_out refused - - - "cannot rename the staged route into place"; return 2; }
  _nd_route_activate "$dir" "$route" "$gen" "$_ND_FWD" "$_ND_ADDR"
}

reconcile_route() {
  local dir msg cur rt r g f out
  _ND_DES_ROUTE="" _ND_DES_GEN="" _ND_RT=""
  dir="$(nd_platform_route_dir)"
  msg="$(_nd_route_dir_ok "$dir")" || { _nd_route_out refused - - - "$msg"; return 2; }
  _nd_route_read_desired "$dir" || { _nd_route_out refused - - - "$dir/desired.tsv is malformed"; return 2; }
  rt="$(route_readback)" || { _nd_route_escalate "Unbound control is unreachable or its running route is unreadable; nothing changed"; return 3; }
  cur="$(_nd_route_file_info "$dir/forward-route.conf")" || cur=""
  if [ -z "$_ND_DES_ROUTE" ]; then
    _nd_route_out none "$(printf '%s\n' "$rt" | cut -f1)" "$(printf '%s\n' "$rt" | cut -f2)" "$(printf '%s\n' "$cur" | cut -f3)" "no route has been requested"
    return 0
  fi
  r="$(printf '%s\n' "$cur" | cut -f1)"; g="$(printf '%s\n' "$cur" | cut -f2)"; f="$(printf '%s\n' "$cur" | cut -f3)"
  if [ -n "$cur" ] && [ "$r" = "$_ND_DES_ROUTE" ]; then
    if [ "$rt" = "$r	$g	${f%%@*}" ]; then
      _nd_route_out converged "$r" "$g" "$f" "route $r generation $g runs as desired"
      return 0
    fi
    # The include was renamed into place but never loaded (an interrupted
    # change): validate it again, then activate it.
    out="$(_nd_route_check "$_ND_CTR_ROUTE_DIR/forward-route.conf")" \
      || { _nd_route_rollback "$dir" "the active include failed validation: $out"; return $?; }
    _nd_route_activate "$dir" "$r" "$g" "$f" "${f%%@*}"
    return $?
  fi
  apply_route "$_ND_DES_ROUTE" "$_ND_DES_GEN"
}

seed_route() {
  local route="${1:-}" gen="${2:-}" dir msg
  _ND_DES_ROUTE="" _ND_DES_GEN=""
  if ! _nd_route_gen_ok "$gen"; then _nd_route_out refused - - - "generation must be a positive integer, got '$gen'"; return 2; fi
  msg="$(_nd_route_resolve "$route")" || { _nd_route_out refused - - - "$msg"; return 2; }
  _nd_route_resolve "$route" >/dev/null
  dir="$(nd_platform_route_dir)"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then (umask 022 && mkdir -p "$dir") || { _nd_route_out refused - - - "cannot create $dir"; return 2; }; fi
  msg="$(_nd_route_dir_ok "$dir")" || { _nd_route_out refused - - - "$msg"; return 2; }
  if [ -e "$dir/forward-route.conf" ]; then
    _nd_route_out refused - - - "$dir/forward-route.conf exists; change a seeded route with apply_route"; return 2
  fi
  if ! { (umask 022 && _nd_route_render "$route" "$gen" "$_ND_FWD" >"$dir/.forward-route.conf.seed") \
         && chmod 0644 "$dir/.forward-route.conf.seed" && mv -f "$dir/.forward-route.conf.seed" "$dir/forward-route.conf"; }; then
    rm -f "$dir/.forward-route.conf.seed"; _nd_route_out refused - - - "cannot write $dir/forward-route.conf"; return 2
  fi
  _nd_route_write_desired "$dir" "$route" "$gen" || { _nd_route_out refused - - - "cannot write $dir/desired.tsv"; return 2; }
  _ND_DES_ROUTE="$route" _ND_DES_GEN="$gen"
  _nd_route_out applied "$route" "$gen" "$_ND_FWD" "seeded $dir/forward-route.conf (Unbound reads it when it starts)"
}

# seed_default_route: the installers' seed (Sub-plan 5 Task 1.2, DEC-010).
# A directory that already holds an include is the controller's: it is
# checked and kept (result kept). Otherwise ND_ROUTE_SEED is seeded at
# generation 1: an identity-bound exit, usable while the onion is cold (ARCH-04;
# the controller promotes the onion once it is sustained), never `compat`
# (DEC-005). Exit 0 seeded or kept; 2 refused.
ND_ROUTE_SEED=cloudflare-exit
seed_default_route() {
  local dir msg
  dir="$(nd_platform_route_dir)"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    msg="$(_nd_route_dir_ok "$dir")" || { _nd_route_out refused - - - "$msg"; return 2; }
    if [ -f "$dir/forward-route.conf" ]; then
      _nd_route_out kept - - - "$dir/forward-route.conf exists; the controller owns it"
      return 0
    fi
  fi
  seed_route "$ND_ROUTE_SEED" 1
}

# start_route: before Unbound starts (Sub-plan 5 Task 1.4, ARCH-04's startup
# rule: an authenticated exit while the onion is cold). When the proxy is
# fresh, a persisted *-onion include is demoted to ND_ROUTE_SEED at the next
# generation, as an install seeds it. Measured on the mac 2026-09-29: after a
# restart on a kept onion the first answer waited 56 s for the rendezvous,
# until the controller's next tick moved to the exit.
#
# Fresh is the policy's test (lib/policy.sh, the fresh-proxy rule), with one
# difference: the proxy container's generation hash (nd_generation_hash, as
# the proxy observation records it) differs from the state's proxy_gen, or,
# here only, cannot be read (the proxy is being recreated; the policy takes an
# unreadable generation as no evidence). So the controller's next pass drops the
# onion from its state too and selects the exit (unchanged), then promotes the
# onion once sustained: include and state agree. Unbound restarting alone
# while the proxy runs on (same generation) keeps its onion: the circuits are
# warm, and a demotion there would stick, since the state would still say
# onion (Tier-1 review I1). Accepted risk (review N1, backlog): a proxy
# generation that cannot be read counts as fresh, which the macOS rebuild
# needs (the proxy does not exist yet); a failed read of a warm proxy
# therefore demotes too, and that demotion sticks until the proxy restarts.
#
# Files only (Unbound is not running), under the controller's state lock, so
# a tick's apply_route never interleaves. A tick holding the lock wins (busy,
# exit 3): the start then runs on the persisted route until that tick or the
# next one decides (a tick restarting the proxy decides on its next pass).
# desired.tsv is written first and the previous include copied by rename, as
# apply_route does, so an interrupted demotion reconciles forward. A malformed
# desired.tsv is refused, as apply_route refuses it. No include, or an exit,
# is kept. Exit 0 applied or kept; 2 refused; 3 busy.
start_route() {
  local dir info cur igen gen tok rc msg pgen sgen
  _ND_DES_ROUTE="" _ND_DES_GEN=""
  dir="$(nd_platform_route_dir)"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    _nd_route_out kept - - - "no route directory $dir (seeding is the installers')"; return 0
  fi
  msg="$(_nd_route_dir_ok "$dir")" || { _nd_route_out refused - - - "$msg"; return 2; }
  [ -e "$dir/forward-route.conf" ] || { _nd_route_out kept - - - "no include in $dir"; return 0; }
  info="$(_nd_route_file_info "$dir/forward-route.conf")" || { _nd_route_out refused - - - "$dir/forward-route.conf is not a managed include"; return 2; }
  cur="$(printf '%s\n' "$info" | cut -f1)" igen="$(printf '%s\n' "$info" | cut -f2)"
  case "$cur" in
    *-onion) ;;
    *) _nd_route_read_desired "$dir" || true
       _nd_route_out kept "$cur" "$igen" "$(printf '%s\n' "$info" | cut -f3)" "not an onion route; kept"; return 0 ;;
  esac
  msg="$(_nd_route_resolve "$ND_ROUTE_SEED")" || { _nd_route_out refused - - - "$msg"; return 2; }
  _nd_route_resolve "$ND_ROUTE_SEED" >/dev/null
  nd_state_init >/dev/null 2>&1 || { _nd_route_out refused - - - "cannot open the controller state directory"; return 2; }
  tok="$(nd_state_lock 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 3 ]; then _nd_route_out busy "$cur" "$igen" - "the controller holds the state lock; the start runs on the persisted route until its pass decides"; return 3; fi
  [ "$rc" -eq 0 ] || { _nd_route_out refused - - - "cannot take the controller state lock"; return 2; }
  pgen="$(_nd_route_proxy_gen)"
  sgen="$(awk -F '\t' '$1 == "proxy_gen" { print $2; exit }' "$(_nd_state_dir)/state.tsv" 2>/dev/null)"
  if [ -n "$pgen" ] && [ "$pgen" = "$sgen" ]; then
    nd_state_unlock "$tok" >/dev/null 2>&1
    _nd_route_read_desired "$dir" || true
    _nd_route_out kept "$cur" "$igen" "$(printf '%s\n' "$info" | cut -f3)" "the proxy is not fresh (generation $pgen, as the controller recorded it): its onion circuits are warm; kept"
    return 0
  fi
  if ! _nd_route_read_desired "$dir"; then
    nd_state_unlock "$tok" >/dev/null 2>&1
    _nd_route_out refused "$cur" "$igen" - "$dir/desired.tsv is malformed"; return 2
  fi
  _nd_route_gen_ok "$igen" || igen=0
  gen="$igen"
  if _nd_route_gen_ok "${_ND_DES_GEN:-}" && [ "$_ND_DES_GEN" -gt "$gen" ]; then gen="$_ND_DES_GEN"; fi
  gen=$((gen + 1))
  if ! { _nd_route_write_desired "$dir" "$ND_ROUTE_SEED" "$gen" \
         && (umask 022 && _nd_route_render "$ND_ROUTE_SEED" "$gen" "$_ND_FWD" >"$dir/.forward-route.conf.staged") \
         && chmod 0644 "$dir/.forward-route.conf.staged" \
         && cp -p "$dir/forward-route.conf" "$dir/.forward-route.conf.prev.tmp" \
         && mv -f "$dir/.forward-route.conf.prev.tmp" "$dir/.forward-route.conf.prev" \
         && mv -f "$dir/.forward-route.conf.staged" "$dir/forward-route.conf"; }; then
    rm -f "$dir/.forward-route.conf.staged" "$dir/.forward-route.conf.prev.tmp"
    nd_state_unlock "$tok" >/dev/null 2>&1
    _nd_route_out refused - - - "cannot write the exit route in $dir"; return 2
  fi
  nd_state_unlock "$tok" >/dev/null 2>&1
  _ND_DES_ROUTE="$ND_ROUTE_SEED" _ND_DES_GEN="$gen"
  _nd_route_out applied "$ND_ROUTE_SEED" "$gen" "$_ND_FWD" "the proxy is fresh (generation ${pgen:-unreadable}, recorded ${sgen:--}): demoted $cur (generation $igen) before Unbound starts"
}

# _nd_route_proxy_gen: the running proxy container's generation hash, or
# nothing when none can be read (not created yet: the macOS agent creates the
# proxy after Unbound).
_nd_route_proxy_gen() {
  local c t out
  t="$(mktemp -d "${TMPDIR:-/tmp}/nd-route-start.XXXXXX")" || return 0
  for c in tor-haproxy tor-socat; do
    if out="$(nd_platform_container_generation "$c" 10 "$t" 2>/dev/null)" && [ -n "$out" ]; then
      nd_generation_hash "$out" || true
      break
    fi
  done
  rm -rf "${t:?}"
}

# ─── Recovery actions (Sub-plan 3, Task 1.3) ────────────────────────────────

_ND_CTL_DIR=/app/data/control

# nd_recovery_checkpoint <step>: called at request-written; tests replace it.
nd_recovery_checkpoint() { return 0; }

_nd_rec_clean() { printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300; }

# nd_recovery_journal <request_id> <component> <phase> <detail>: append one
# row to the journal (created with its schema line; the last 1000 rows are
# kept once it passes 2000).
nd_recovery_journal() {
  local d f n
  d="$(nd_platform_state_dir)"
  _nd_state_dir_ok "$d" >/dev/null || return 1
  f="$d/recovery.tsv"
  [ -L "$f" ] && return 1
  if [ ! -f "$f" ]; then (umask 077 && printf 'schema\tnice-dns-recovery-journal/1\n' >"$f") || return 1; fi
  (umask 077 && printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(_nd_rec_clean "$1")" "$(_nd_rec_clean "$2")" \
    "$(_nd_rec_clean "$3")" "$(_nd_rec_clean "$4")" >>"$f") || return 1
  n="$(wc -l <"$f" | tr -d ' ')"
  if [ "$n" -gt 2001 ]; then
    { head -n 1 "$f"; tail -n 1000 "$f"; } >"$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  fi
  return 0
}

_nd_rec_out() {
  printf 'result\t%s\ncomponent\t%s\nrequest_id\t%s\ngeneration_before\t%s\ngeneration\t%s\ndetail\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$(_nd_rec_clean "$6")"
}

# _nd_rec_x <deadline> <cmd...>: bounded; stdout in $_ND_RX/o, stderr in $_ND_RX/e.
_nd_rec_x() {
  local dl="$1"
  shift
  nd_bounded "$dl" "$_ND_RX/o" "$_ND_RX/e" "$@"
}

_nd_rec_field() { awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$2" 2>/dev/null; }

_nd_rec_id_ok() {
  case "$1" in ''|legacy|suspend|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

# _nd_rec_lock_ok <request_id> <component>: 0 unless a lock token was given
# and no longer holds the state lock (then journalled and printed).
_nd_rec_lock_ok() {
  [ -n "${ND_RECOVERY_LOCK_TOKEN:-}" ] || return 0
  nd_state_lock_held "$ND_RECOVERY_LOCK_TOKEN" && return 0
  nd_recovery_journal "$1" "$2" lock-lost "the state lock was taken over; stopping before any change"
  _nd_rec_out lock-lost "$2" "$1" - - "the state lock is no longer held"
  return 1
}

_nd_rec_now() { date +%s; }

request_recovery() {
  local comp="${1:-}" id="${2:-}" dl="${ND_RECOVERY_CMD_DEADLINE:-15}" c rc g0 p0 st g p i=0 max
  max="${ND_RECOVERY_ACK_S:-30}"
  if [ "$comp" != tor ]; then _nd_rec_out unsupported "$comp" "$id" - - "no in-image restart for component '$comp'"; return 3; fi
  if ! _nd_rec_id_ok "$id"; then _nd_rec_out refused "$comp" "$id" - - "request id must be 1-64 of A-Za-z0-9._:- and not 'legacy' or 'suspend'"; return 2; fi
  _ND_RX="$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-recovery.XXXXXX")" || return 4
  c="$(nd_platform_proxy_container "$dl" "$_ND_RX")" || {
    nd_recovery_journal "$id" tor unreachable "no proxy container"; _nd_rec_out unreachable tor "$id" - - "no proxy container found"
    rm -rf "$_ND_RX"; return 4; }
  _nd_rec_x "$dl" nd_platform_proxy_exec "$c" test -d "$_ND_CTL_DIR"; rc=$?
  if [ "$rc" -eq 1 ]; then
    nd_recovery_journal "$id" tor unsupported "$c has no $_ND_CTL_DIR (image without the acknowledged restart)"
    _nd_rec_out unsupported tor "$id" - - "$c does not offer the acknowledged restart"; rm -rf "$_ND_RX"; return 3
  elif [ "$rc" -ne 0 ]; then
    nd_recovery_journal "$id" tor unreachable "exec in $c failed (exit $rc): $(head -n 1 "$_ND_RX/e")"
    _nd_rec_out unreachable tor "$id" - - "cannot exec in $c (exit $rc)"; rm -rf "$_ND_RX"; return 4
  fi
  _nd_rec_x "$dl" nd_platform_proxy_exec "$c" cat "$_ND_CTL_DIR/tor-generation" || : >"$_ND_RX/o"
  g0="$(_nd_rec_field generation "$_ND_RX/o")"; p0="$(_nd_rec_field tor_pid "$_ND_RX/o")"
  case "$g0" in ''|*[!0-9]*) g0=- ;; esac
  _nd_rec_lock_ok "$id" tor || { rm -rf "$_ND_RX"; return 5; }
  # The image's own user writes the request atomically (tmp + mv).
  # shellcheck disable=SC2016
  if ! _nd_rec_x "$dl" nd_platform_proxy_exec "$c" sh -c 'printf "%s\n" "$1" >"$2/tor-restart-request.tmp" && mv "$2/tor-restart-request.tmp" "$2/tor-restart-request"' sh "$id" "$_ND_CTL_DIR"; then
    nd_recovery_journal "$id" tor not-acknowledged "the request could not be written in $c"
    _nd_rec_out not-acknowledged tor "$id" "$g0" - "the request could not be written in $c"; rm -rf "$_ND_RX"; return 1
  fi
  nd_recovery_journal "$id" tor requested "restart request in $c; generation before: $g0"
  nd_recovery_checkpoint request-written
  st="" g="" p="" i=$(( $(_nd_rec_now) + max ))
  while :; do
    if _nd_rec_x "$dl" nd_platform_proxy_exec "$c" cat "$_ND_CTL_DIR/tor-restart-ack" \
       && [ "$(_nd_rec_field request_id "$_ND_RX/o")" = "$id" ]; then
      st="$(_nd_rec_field status "$_ND_RX/o")"; g="$(_nd_rec_field generation "$_ND_RX/o")"; p="$(_nd_rec_field tor_pid "$_ND_RX/o")"
      break
    fi
    [ "$(_nd_rec_now)" -lt "$i" ] || break
    sleep 1
  done
  rm -rf "$_ND_RX"
  if [ -z "$st" ]; then
    nd_recovery_journal "$id" tor not-acknowledged "no acknowledgement within ${max}s"
    _nd_rec_out not-acknowledged tor "$id" "$g0" - "no acknowledgement from $c within ${max}s"; return 1
  fi
  if [ "$st" = respawned ] && [ "$g0" != - ] && [ "$g" -gt "$g0" ] 2>/dev/null && [ -n "$p" ] && [ "$p" != "$p0" ]; then
    nd_recovery_journal "$id" tor acknowledged "generation $g0 -> $g, tor pid $p0 -> $p"
    _nd_rec_out acknowledged tor "$id" "$g0" "$g" "tor respawned in $c: generation $g, pid $p"; return 0
  fi
  nd_recovery_journal "$id" tor not-acknowledged "answer status=$st generation=$g pid=$p (before: $g0, $p0)"
  _nd_rec_out not-acknowledged tor "$id" "$g0" "${g:--}" "$c answered status=$st generation=$g; no new tor generation"
  return 1
}

# _nd_rec_wait_generation <container|""> <before> <seconds>: 0 when the
# container runs with a generation other than <before>; an empty name waits
# for either proxy container to run. _ND_REC_GEN holds the last one read.
_nd_rec_wait_generation() {
  local end=$(( $(_nd_rec_now) + $3 ))
  _ND_REC_GEN=""
  local c
  while [ "$(_nd_rec_now)" -lt "$end" ]; do
    c="$1"
    if [ -z "$c" ] && nd_platform_runtime_list "${ND_RECOVERY_CMD_DEADLINE:-15}" "$_ND_RX/running" >/dev/null 2>&1; then
      c="$(grep -x -e tor-haproxy -e tor-socat "$_ND_RX/running" | head -n 1)"
    fi
    if [ -n "$c" ]; then
      _ND_REC_GEN="$(nd_platform_container_generation "$c" "${ND_RECOVERY_CMD_DEADLINE:-15}" "$_ND_RX" 2>/dev/null)" || _ND_REC_GEN=""
      if [ -n "$_ND_REC_GEN" ] && [ "$_ND_REC_GEN" != "$2" ] && nd_platform_runtime_list "${ND_RECOVERY_CMD_DEADLINE:-15}" "$_ND_RX/running" >/dev/null 2>&1 \
         && grep -qx "$c" "$_ND_RX/running"; then
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

nd_recovery_restart_service() {
  local id="${1:-}" dl="${ND_RECOVERY_CMD_DEADLINE:-15}" svc="${ND_RECOVERY_SERVICE_S:-120}" c g0 rc
  if ! _nd_rec_id_ok "$id"; then _nd_rec_out refused service "$id" - - "bad request id"; return 2; fi
  _ND_RX="$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-recovery.XXXXXX")" || return 4
  if ! c="$(nd_platform_proxy_container "$dl" "$_ND_RX")"; then
    # No proxy container at all. A stack-wide restart (macOS) recreates it;
    # a proxy-only restart has nothing to name.
    if [ "$(nd_platform_restart_scope)" != stack ]; then
      nd_recovery_journal "$id" service unreachable "no proxy container to restart"
      _nd_rec_out unreachable service "$id" - - "no proxy container found"; rm -rf "$_ND_RX"; return 4
    fi
    c=""
  fi
  if [ -n "$c" ]; then g0="$(nd_platform_container_generation "$c" "$dl" "$_ND_RX" 2>/dev/null)" || g0="-"; else g0="-"; fi
  [ -n "$g0" ] || g0="-"
  _nd_rec_lock_ok "$id" service || { rm -rf "$_ND_RX"; return 5; }
  nd_recovery_journal "$id" service requested "$(nd_platform_restart_scope) restart for ${c:-the missing proxy}; container before: $g0"
  nd_platform_restart_proxy "$c" "$svc" "$_ND_RX"; rc=$?
  if [ "$rc" -ne 0 ]; then
    nd_recovery_journal "$id" service not-acknowledged "the service restart of $c exited $rc: $(head -n 1 "$_ND_RX/svc.err" 2>/dev/null)"
    _nd_rec_out not-acknowledged service "$id" "$g0" - "service restart of $c exited $rc"; rm -rf "$_ND_RX"; return 1
  fi
  if _nd_rec_wait_generation "$c" "$g0" "$svc"; then
    nd_recovery_journal "$id" service acknowledged "$c restarted: $_ND_REC_GEN"
    _nd_rec_out acknowledged service "$id" "$g0" "$_ND_REC_GEN" "$c runs as a new container start"; rm -rf "$_ND_RX"; return 0
  fi
  nd_recovery_journal "$id" service not-acknowledged "$c did not come back with a new start within ${svc}s (last: ${_ND_REC_GEN:-none})"
  _nd_rec_out not-acknowledged service "$id" "$g0" "${_ND_REC_GEN:--}" "no new start of $c within ${svc}s"; rm -rf "$_ND_RX"
  return 1
}

repair_runtime() {
  local fault="${1:-}" id="${2:-}" dl="${ND_RECOVERY_CMD_DEADLINE:-15}" svc="${ND_RECOVERY_SERVICE_S:-120}" rc i=0 n
  case "$fault" in runtime-down|containers-missing) ;; *) _nd_rec_out refused runtime "$id" - - "no repair for fault '$fault'"; return 2 ;; esac
  if ! _nd_rec_id_ok "$id"; then _nd_rec_out refused runtime "$id" - - "bad request id"; return 2; fi
  _nd_rec_lock_ok "$id" runtime || return 5
  _ND_RX="$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-recovery.XXXXXX")" || return 4
  nd_platform_repair_runtime "$fault" "$svc" "$_ND_RX"; rc=$?
  if [ "$rc" -eq 3 ]; then
    nd_recovery_journal "$id" runtime unsupported "no repair for $fault on $(nd_platform_name)"
    _nd_rec_out unsupported runtime "$id" - - "no repair for $fault on $(nd_platform_name)"; rm -rf "$_ND_RX"; return 3
  fi
  nd_recovery_journal "$id" runtime requested "repair of $fault (exit $rc)"
  i=$(( $(_nd_rec_now) + svc )) n=0 rc=1
  while [ "$(_nd_rec_now)" -lt "$i" ]; do
    if nd_platform_runtime_list "$dl" "$_ND_RX/running" >/dev/null 2>&1; then
      if [ "$fault" = runtime-down ]; then rc=0; break; fi
      n="$(grep -cx -e pi-hole -e unbound -e tor-haproxy -e tor-socat "$_ND_RX/running")"
      [ "$n" -ge 3 ] && { rc=0; break; }
    fi
    sleep 2
  done
  rm -rf "$_ND_RX"
  if [ "$rc" -eq 0 ]; then
    nd_recovery_journal "$id" runtime acknowledged "$fault: the runtime answers$( [ "$fault" = containers-missing ] && printf ' and the stack runs')"
    _nd_rec_out acknowledged runtime "$id" - - "$fault repaired"; return 0
  fi
  nd_recovery_journal "$id" runtime not-acknowledged "$fault persists after ${svc}s"
  _nd_rec_out not-acknowledged runtime "$id" - - "$fault persists after ${svc}s"; return 1
}

nd_recovery_restart_tor() {
  local id="${1:-}" rc f
  # A refreshed bridge set the running proxy has not read yet: the in-image
  # restart reuses the container's environment, so the service restart,
  # which recreates the container, is what adopts it.
  if _nd_br_pending; then
    nd_recovery_journal "$id" tor adopting "a refreshed bridge set waits for the proxy; the service restart adopts it"
    nd_recovery_restart_service "$id-svc"; rc=$?
    f="$(nd_platform_state_dir)/bridges.pending"
    [ "$rc" -eq 0 ] && rm -f "${f:?}"
    return "$rc"
  fi
  request_recovery tor "$id"; rc=$?
  case "$rc" in
    1|3|4) nd_recovery_restart_service "$id-svc"; rc=$? ;;
  esac
  return "$rc"
}

# nd_recovery_apply <decision> <request_id> <route_generation>: prints the
# action's own output; returns its status (0 for no-op and escalate). A Tor
# restart that the image cannot acknowledge falls back once to the service
# restart; nothing is retried beyond that in one pass.
nd_recovery_apply() {
  local dec="$1" id="$2" rgen="$3" action target reason rc
  action="$(_nd_rec_field action "$dec")"; target="$(_nd_rec_field target "$dec")"; reason="$(_nd_rec_field reason "$dec")"
  case "$action" in
    no-op) return 0 ;;
    escalate) nd_recovery_journal "$id" controller escalated "$reason"; return 0 ;;
    switch-route)
      _nd_rec_lock_ok "$id" "route:$target" || return 5
      nd_recovery_journal "$id" "route:$target" requested "switch to $target (generation $rgen): $reason"
      apply_route "$target" "$rgen"; rc=$?
      case "$rc" in
        0) nd_recovery_journal "$id" "route:$target" acknowledged "route $target generation $rgen reads back and resolves" ;;
        *) nd_recovery_journal "$id" "route:$target" not-acknowledged "apply_route exit $rc" ;;
      esac
      return "$rc" ;;
    restart-component)
      case "$target" in
        tor) nd_recovery_restart_tor "$id"; return $? ;;
        proxy) nd_recovery_restart_service "$id"; return $? ;;
        *) nd_recovery_journal "$id" controller refused "no restart for component '$target'"; return 2 ;;
      esac ;;
    repair-runtime) repair_runtime "$target" "$id"; return $? ;;
    *) nd_recovery_journal "$id" controller refused "unknown action '$action'"; return 2 ;;
  esac
}

# _nd_rec_readiness <observations> <now>: for every acknowledged action that
# has no readiness row yet, record ready when this pass shows its component
# working, or not-ready once ND_RECOVERY_READY_S (600) passed without it:
#   route:<id>        that route's probe is healthy
#   tor, service      an identity route is healthy AND Unbound resolves over
#                     its current route (nice-dns-unbound-start probe-route: a
#                     fresh TLS session with Unbound's trust store, host-side
#                     evidence the proxy cannot forge). An Unbound image
#                     without probe-route (exit 126/127) gives "ready,
#                     uncorroborated".
#   runtime           the runtime observation is healthy
_nd_rec_readiness() {
  local f d row id comp at ok det age ids
  d="$(nd_platform_state_dir)"; f="$d/recovery.tsv"
  [ -f "$f" ] || return 0
  ids="$(awk -F '\t' '$1 == "#" || $1 !~ /^[0-9]+$/ { next }
    $4 == "acknowledged" && !($2 in ack) { ack[$2] = NR; row[$2] = $0; order[++n] = $2 }
    $4 == "ready" || $4 == "not-ready" { done[$2] = 1 }
    END { for (i = 1; i <= n; i++) if (!(order[i] in done)) print row[order[i]] }' "$f")"
  [ -n "$ids" ] || return 0
  _nd_rec_identity="$(awk -F '\t' '$5 == "identity" { printf "%s%s", s, $1; s = " " }' "${ND_ROUTES_FILE:-$ND_LIB_DIR/../routes/providers.tsv}")"
  printf '%s\n' "$ids" | while IFS="$(printf '\t')" read -r at id comp _ _; do
    ok=0 det=""
    case "$comp" in
      route:*)
        awk -F '\t' -v n="$comp" '$1 == "obs" && $2 == n && $3 == "healthy" { f = 1 } END { exit !f }' "$1" && ok=1 ;;
      tor|service)
        if awk -F '\t' -v ids=" $_nd_rec_identity " '$1 == "obs" && $2 ~ /^route:/ && $3 == "healthy" && index(ids, " " substr($2, 7) " ") { f = 1 } END { exit !f }' "$1"; then
          _ND_RX="$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-ready.XXXXXX")" || return 0
          _nd_rec_x "${ND_RECOVERY_CMD_DEADLINE:-15}" nd_platform_unbound_exec "$_ND_START" probe-route "${ND_ROUTE_PROBE_NAME:-.}"
          case $? in
            0) ok=1 det="; Unbound resolves over its route" ;;
            126|127) ok=1 det="; uncorroborated: the Unbound image has no probe-route" ;;
          esac
          rm -rf "$_ND_RX"
        fi ;;
      runtime)
        awk -F '\t' '$1 == "obs" && $2 == "runtime" && $3 == "healthy" { f = 1 } END { exit !f }' "$1" && ok=1 ;;
    esac
    age=$(( $2 - at ))
    if [ "$ok" = 1 ]; then nd_recovery_journal "$id" "$comp" ready "observed working ${age}s after the acknowledgement$det"
    elif [ "$age" -ge "${ND_RECOVERY_READY_S:-600}" ]; then nd_recovery_journal "$id" "$comp" not-ready "still failing ${age}s after the acknowledgement"
    fi
  done
  return 0
}

# nd_recovery_tick <active|shadow> <observations>: one controller pass under
# the state lock: record readiness for the last acknowledged action, decide
# (lib/policy.sh), carry the action out (active) or only record it (shadow),
# commit the next state. Shadow mode keeps its own state and journal in the
# state directory's shadow/ and never runs a runtime or route command.
# Prints action, target, result and generation rows. Exit: 0 done; 3 the lock
# is held by another pass; 2 a state or input error.
nd_recovery_tick() {
  local mode="${1:-}" obs="${2:-}" tok gen now boot t id rc=0 result=none rgen act pg
  case "$mode" in active) ;; shadow) ND_STATE_DIR="$(nd_platform_state_dir)/shadow"; export ND_STATE_DIR ;; *) printf 'tick: mode must be active or shadow\n' >&2; return 2 ;; esac
  [ -r "$obs" ] || { printf 'tick: observations %s unreadable\n' "$obs" >&2; return 2; }
  nd_state_init || return 2
  tok="$(nd_state_lock)"; rc=$?
  if [ "$rc" -ne 0 ]; then printf 'action\t-\ntarget\t-\nresult\tbusy\ngeneration\t-\n'; return "$rc"; fi
  t="$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-tick.XXXXXX")" || { nd_state_unlock "$tok"; return 2; }
  now="$(date +%s)"; boot="$(_nd_state_boot)"
  if ! nd_state_load >"$t/state"; then rm -rf "$t"; nd_state_unlock "$tok"; return 2; fi
  gen="$(_nd_rec_field generation "$t/state")"
  _nd_rec_readiness "$obs" "$now"
  if ! ND_POLICY_RUNTIME_REPAIRS="$(nd_platform_runtime_repairs)" nd_policy_decide "$obs" "$t/state" "$now" "$boot" >"$t/out"; then rm -rf "$t"; nd_state_unlock "$tok"; return 2; fi
  awk '$0 == "schema\tnice-dns-controller-state/1" { s = 1 } !s' "$t/out" >"$t/decision"
  awk '$0 == "schema\tnice-dns-controller-state/1" { s = 1 } s' "$t/out" >"$t/next"
  id="nd-$now-$((gen + 1))"
  act="$(_nd_rec_field action "$t/decision")"
  if [ "$act" != no-op ]; then
    if [ "$mode" = shadow ]; then
      nd_recovery_journal "$id" controller shadow "would $act $(_nd_rec_field target "$t/decision"): $(_nd_rec_field reason "$t/decision")"
      result=shadow
    elif [ "$act" = switch-route ] && [ ! -d "$(nd_platform_route_dir)" ]; then
      # No route directory is mounted (deployments before Sub-plan 4): route
      # control is unavailable, so nothing is attempted or recorded.
      result=unmanaged
    else
      # The route generation stays ahead of both the controller's and the
      # route layer's own (desired.tsv), which apply_route refuses to go below.
      rgen=$((gen + 1))
      if [ "$act" = switch-route ] && _nd_route_read_desired "$(nd_platform_route_dir)" 2>/dev/null \
         && [ -n "$_ND_DES_GEN" ] && [ "$_ND_DES_GEN" -ge "$rgen" ]; then rgen=$((_ND_DES_GEN + 1)); fi
      ND_RECOVERY_LOCK_TOKEN="$tok" nd_recovery_apply "$t/decision" "$id" "$rgen" >"$t/apply" 2>&1; rc=$?
      # The last result row: after a fallback, the fallback's outcome.
      result="$(awk -F '\t' '$1 == "result" { r = $2 } END { print r }' "$t/apply")"; [ -n "$result" ] || result="exit-$rc"
    fi
    # A route is recorded as selected only once apply_route succeeded (exit 0:
    # applied, or unchanged when it already ran); otherwise the previous one
    # stays, and the next pass decides the switch again. A switch that was
    # tried and failed also keeps the previous proxy generation (BL-023): the
    # pass that decided it on a fresh proxy (lib/policy.sh) must find the
    # proxy fresh again, or the onion it dropped would stay in the state while
    # the start's exit (start_route) runs, for good. Without route control
    # (unmanaged) nothing was tried and the generation is recorded.
    if [ "$act" = switch-route ] && { [ "$mode" = shadow ] || [ "$result" = unmanaged ] || [ "$rc" -ne 0 ]; }; then
      if [ "$mode" != shadow ]; then
        pg=""
        if [ "$result" != unmanaged ]; then pg="$(_nd_rec_field proxy_gen "$t/state")"; [ -n "$pg" ] || pg=-; fi
        awk -F '\t' -v r="$(_nd_rec_field route "$t/state")" -v pg="$pg" 'BEGIN { OFS = "\t" } $1 == "route" { $2 = r } pg != "" && $1 == "proxy_gen" { $2 = pg } { print }' "$t/next" >"$t/next.2" && mv "$t/next.2" "$t/next"
      fi
    fi
  fi
  gen="$(nd_state_commit "$tok" "$gen" "$t/next")" || gen="-"
  nd_state_unlock "$tok"
  printf 'action\t%s\ntarget\t%s\nresult\t%s\ngeneration\t%s\n' "$(_nd_rec_field action "$t/decision")" "$(_nd_rec_field target "$t/decision")" "$result" "$gen"
  rm -rf "$t"
  return 0
}

# ─── Bridge refresh (Sub-plan 3, Task 2.2; ARCH-07) ─────────────────────────
#
#   nd_bridges_refresh <variant>           evaluate, then nd_bridges_apply
#   nd_bridges_apply <candidate> <base>    adopt a candidate bridge set
#
# The proxy image's bridge-eval (nd_platform_bridge_eval) writes a candidate
# next to bridges.env, never bridges.env itself, and runs WITHOUT the state
# lock (it takes minutes); a refresh mutex (bridges.lock in the state
# directory) keeps two evaluations off the shared pool. Applying is short and
# holds the state lock:
#   * a candidate with fewer than 3 valid obfs4 lines is not applied: the last
#     good set stays (an outage of the distributor never empties bridges.env);
#   * the sets are compared normalized (valid lines, sorted, unique); an
#     unchanged set writes nothing;
#   * bridges.env is only replaced when it still holds the set the evaluation
#     started from, so a slow evaluation never overwrites a newer one;
#   * a changed set replaces bridges.env atomically (the old one kept as
#     bridges.env.prev) and restarts nothing: the proxy reads it at its next
#     natural start. bridges.pending records the proxy container's
#     generation, so a later Tor restart during a sustained failure can adopt
#     the set through the service restart (nd_recovery_restart_tor); a proxy
#     that restarted since has adopted it already.

_ND_BR_LINE='^BRIDGE[0-9]+=obfs4 [0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{1,5} [0-9A-F]{40} cert=[A-Za-z0-9+/=]+ iat-mode=[0-2]$'

# _nd_br_norm <file>: the valid bridge lines, without keys, sorted, unique.
_nd_br_norm() {
  [ -f "$1" ] || return 0
  grep -E "$_ND_BR_LINE" "$1" 2>/dev/null | sed 's/^BRIDGE[0-9]*=//' | LC_ALL=C sort -u
}

_nd_br_hash() {
  local n
  n="$(_nd_br_norm "$1")"
  [ -n "$n" ] || { printf 'none\n'; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then printf '%s\n' "$n" | sha256sum | cut -c1-16
  else printf '%s\n' "$n" | shasum -a 256 | cut -c1-16; fi
}

nd_bridges_apply() {
  local cand="$1" base="$2" d live n tok i=0 cur new g c
  d="$(nd_platform_bridge_dir)"; live="$d/bridges.env"
  n="$(_nd_br_norm "$cand" | wc -l | tr -d ' ')"
  if [ "$n" -lt 3 ]; then
    nd_recovery_journal "br-$(date +%s)" bridges not-applied "the candidate has $n usable bridges; the last good set stays"
    printf 'result\tnot-applied\n'; return 1
  fi
  while ! tok="$(nd_state_lock 2>/dev/null)"; do
    i=$((i + 1)); [ "$i" -lt 60 ] || { printf 'result\tbusy\n'; return 3; }
    sleep 0.5
  done
  cur="$(_nd_br_hash "$live")"; new="$(_nd_br_hash "$cand")"
  if [ "$cur" != "$base" ]; then
    nd_state_unlock "$tok"
    nd_recovery_journal "br-$(date +%s)" bridges superseded "bridges.env changed while this evaluation ran ($base -> $cur); its candidate is dropped"
    printf 'result\tsuperseded\n'; return 4
  fi
  if [ "$cur" = "$new" ]; then
    nd_state_unlock "$tok"
    nd_recovery_journal "br-$(date +%s)" bridges unchanged "the evaluated set equals the running one ($cur)"
    printf 'result\tunchanged\n'; return 0
  fi
  [ -f "$live" ] && cp -p "$live" "$live.prev"
  if ! { _nd_br_norm "$cand" | awk '{ printf "BRIDGE%d=%s\n", NR, $0 }' | (umask 077 && cat >"$live.new.$$") \
          && mv -f "$live.new.$$" "$live"; }; then
    rm -f "${live:?}.new.$$"; nd_state_unlock "$tok"; printf 'result\tnot-applied\n'; return 1
  fi
  _ND_RX="$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-bridges.XXXXXX")" || _ND_RX=""
  g="-"
  if [ -n "$_ND_RX" ] && c="$(nd_platform_proxy_container "${ND_RECOVERY_CMD_DEADLINE:-15}" "$_ND_RX")"; then
    g="$(nd_platform_container_generation "$c" "${ND_RECOVERY_CMD_DEADLINE:-15}" "$_ND_RX" 2>/dev/null)" || g="-"
    [ -n "$g" ] || g="-"
  fi
  [ -n "$_ND_RX" ] && rm -rf "${_ND_RX:?}"
  (umask 077 && printf '%s\t%s\n' "$new" "$g" >"$(nd_platform_state_dir)/bridges.pending")
  nd_state_unlock "$tok"
  nd_recovery_journal "br-$(date +%s)" bridges changed "$cur -> $new ($n bridges); adopted at the proxy's next start, no restart"
  printf 'result\tchanged\n'; return 0
}

# _nd_br_mutex_take / _nd_br_mutex_drop: the refresh mutex (a symlink, like
# the state lock; stale when its process is gone or from another boot).
_nd_br_mutex_take() {
  local m v
  m="$(nd_platform_state_dir)/bridges.lock"
  _ND_LK_NOW="$(date +%s)" _ND_LK_BOOT="$(_nd_state_boot)"
  if ln -s "nd-lock:$$:$_ND_LK_BOOT:$_ND_LK_NOW:bridges" "$m" 2>/dev/null; then return 0; fi
  v="$(readlink "$m" 2>/dev/null)" || return 1
  ND_STATE_LEASE_S=1800 _nd_lock_stale "$v" || return 1
  rm -f "${m:?}"
  ln -s "nd-lock:$$:$_ND_LK_BOOT:$_ND_LK_NOW:bridges" "$m" 2>/dev/null
}

_nd_br_mutex_drop() {
  local m
  m="$(nd_platform_state_dir)/bridges.lock"
  case "$(readlink "$m" 2>/dev/null)" in "nd-lock:$$:"*) rm -f "${m:?}" ;; esac
}

# Stream quality. bridge-eval judges a bridge by its obfs4 handshake; a bridge
# can pass that and still carry streams badly (the mac soak of 2026-10-02:
# 80% stream success, onion streams stalled for minutes; Tor only drops a
# timed-out rend stream, never its circuit). The running Tor keeps per-bridge
# path-bias use counters in its state file; Tor itself judges them after 20
# uses (DFLT_PATH_BIAS_MIN_USE) and only logs. Below ND_BRIDGE_MIN_USE_PCT
# (90, user decision 2026-10-04) a bridge is left out of every refresh while
# its counters stay low. listed=1 marks a bridge the running Tor is
# configured with.

# _nd_br_weak <tor state file>: "FINGERPRINT<TAB>listed<TAB>successes/uses"
# for each judged bridge below the bar.
_nd_br_weak() {
  awk -v min="${ND_BRIDGE_MIN_USE:-20}" -v pct="${ND_BRIDGE_MIN_USE_PCT:-90}" '
    $1 == "Guard" && $2 == "in=bridges" {
      fp = ""; l = 0; a = 0; s = 0
      for (i = 3; i <= NF; i++) {
        k = $i; sub(/=.*/, "", k); v = $i; sub(/^[^=]*=/, "", v)
        if (k == "rsa_id") fp = toupper(v)
        else if (k == "listed") l = v + 0
        else if (k == "pb_use_attempts") a = v + 0
        else if (k == "pb_use_successes") s = v + 0
      }
      if (length(fp) == 40 && fp !~ /[^0-9A-F]/ && a >= min && s * 100 < pct * a)
        printf "%s\t%d\t%d/%d\n", fp, l, s, a
    }' "$1" 2>/dev/null
}

# _nd_br_tor_state <tmp>: the running proxy's Tor state into <tmp>/tor-state.
_nd_br_tor_state() {
  local c dl="${ND_RECOVERY_CMD_DEADLINE:-15}"
  c="$(nd_platform_proxy_container "$dl" "$1")" || return 1
  nd_bounded "$dl" "$1/tor-state" "$1/tor-state.err" nd_platform_proxy_exec "$c" cat /app/data/tor/state
}

# _nd_br_drop <bridges file> <weak list>: leave the weak fingerprints out, in place.
_nd_br_drop() {
  awk -v w="$(printf '%s\n' "$2" | cut -f1 | tr '\n' ' ')" '
    BEGIN { n = split(w, x, " "); for (i = 1; i <= n; i++) bad[x[i]] = 1 }
    !(toupper($3) in bad)' "$1" >"$1.q" && mv -f "$1.q" "$1"
}

# _nd_br_running_weak <weak list> <bridges file>: 0 when the running Tor is
# configured with a weak bridge the file no longer holds.
_nd_br_running_weak() {
  local f
  for f in $(printf '%s\n' "$1" | awk -F '\t' '$2 == 1 { print $1 }'); do
    awk -v f="$f" 'toupper($3) == f { found = 1 } END { exit !found }' "$2" || return 0
  done
  return 1
}

nd_bridges_refresh() {
  local v="${1:-}" d base cand rc t out weak="" dropped=0 n0 adopted=-
  case "$v" in haproxy|socat) ;; *) printf 'result\trefused\ndetail\tvariant must be haproxy or socat\n'; return 2 ;; esac
  d="$(nd_platform_bridge_dir)"
  if ! _nd_br_mutex_take; then
    nd_recovery_journal "br-$(date +%s)" bridges skipped "another bridge refresh is running"
    printf 'result\tskipped\n'; return 3
  fi
  base="$(_nd_br_hash "$d/bridges.env")"
  cand=".bridges.env.candidate.$$"
  t="$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-bridges.XXXXXX")" || { _nd_br_mutex_drop; return 2; }
  nd_platform_bridge_eval "$v" "$cand" "${ND_BRIDGE_EVAL_S:-300}" "$t"; rc=$?
  [ "$rc" -eq 0 ] && _nd_br_tor_state "$t" && weak="$(_nd_br_weak "$t/tor-state")"
  rm -rf "${t:?}"
  if [ "$rc" -eq 0 ] && [ -n "$weak" ]; then
    n0="$(_nd_br_norm "$d/$cand" | wc -l | tr -d ' ')"
    _nd_br_drop "$d/$cand" "$weak"
    dropped=$((n0 - $(_nd_br_norm "$d/$cand" | wc -l | tr -d ' ')))
    nd_recovery_journal "br-$(date +%s)" bridges weak "below ${ND_BRIDGE_MIN_USE_PCT:-90}% stream success after ${ND_BRIDGE_MIN_USE:-20} uses, left out: $(printf '%s\n' "$weak" | awk -F '\t' '{ printf "%s%s %s%s", (NR > 1 ? ", " : ""), substr($1, 1, 12), $3, ($2 == 1 ? " (running)" : "") }')"
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "${d:?}/$cand"
    _nd_br_mutex_drop
    if [ "$rc" -eq 3 ]; then
      nd_recovery_journal "br-$(date +%s)" bridges skipped "the stack is not running; nothing evaluated"
      printf 'result\tskipped\n'; return 3
    fi
    nd_recovery_journal "br-$(date +%s)" bridges not-applied "bridge-eval exit $rc; the last good set stays"
    printf 'result\tnot-applied\n'; return 1
  fi
  out="$(nd_bridges_apply "$d/$cand" "$base")"; rc=$?
  rm -f "${d:?}/$cand"
  _nd_br_mutex_drop
  # The proxy reads bridges.env only when it starts. A running weak bridge
  # the new set leaves out is adopted now, through the service restart that
  # recreates the proxy (user decision 2026-10-04: one fail-closed gap at most
  # per refresh). The pending marker bounds it: once the proxy has read the
  # set, a stale listed=1 in the state file restarts nothing.
  if [ "$rc" -eq 0 ] && _nd_br_running_weak "$weak" "$d/bridges.env" && _nd_br_pending; then
    nd_recovery_journal "br-$(date +%s)" bridges adopting "the running proxy uses a bridge the new set leaves out; the service restart adopts the set"
    if nd_recovery_restart_service "br-$(date +%s)-svc" >/dev/null; then
      rm -f "$(nd_platform_state_dir)/bridges.pending"; adopted=restarted
    else
      adopted=failed
    fi
  fi
  printf '%s\ndropped\t%s\nadopted\t%s\n' "$out" "$dropped" "$adopted"
  return "$rc"
}

# _nd_br_pending: 0 when a refreshed set waits for the running proxy, which
# has not been recreated since it was written. A proxy recreated since then
# has read it; the marker is dropped.
_nd_br_pending() {
  local f g c cur t
  f="$(nd_platform_state_dir)/bridges.pending"
  [ -f "$f" ] || return 1
  g="$(cut -f2 "$f")"
  t="$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-bridges.XXXXXX")" || return 1
  cur="-"
  if c="$(nd_platform_proxy_container "${ND_RECOVERY_CMD_DEADLINE:-15}" "$t")"; then
    cur="$(nd_platform_container_generation "$c" "${ND_RECOVERY_CMD_DEADLINE:-15}" "$t" 2>/dev/null)" || cur="-"
    [ -n "$cur" ] || cur="-"
  fi
  rm -rf "${t:?}"
  if [ "$cur" != "-" ] && [ "$g" != "-" ] && [ "$cur" != "$g" ]; then rm -f "${f:?}"; return 1; fi
  return 0
}
