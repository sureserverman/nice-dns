# shellcheck shell=bash
# nice-dns route application (ARCH-03 apply_route, ARCH-04). Sourced; Bash 3.2
# compatible (macOS /bin/bash), safe under set -u. Sub-plan 3 adds the
# recovery actions here and holds the mutation lock (lib/state.sh) around
# every call that changes the route.
#
#   apply_route <route_id> <generation>   select a route from routes/providers.tsv
#   reconcile_route                       bring the running route to the desired one
#   seed_route <route_id> <generation>    write the first include before Unbound starts
#   route_readback                        route<TAB>generation<TAB>address running now
#
# The route directory (nd_platform_route_dir) is mounted into the Unbound
# container at /etc/unbound/route and holds:
#   forward-route.conf          the active include (rendered here, 0644)
#   .forward-route.conf.staged  a candidate being validated
#   .forward-route.conf.prev    the include before the last change (rollback)
#   desired.tsv                 schema, route and generation last requested
#                               (Sub-plan 3's lib/state.sh becomes the owner of
#                               desired state and generations; this file and
#                               the stale-generation check here then serve as
#                               the route layer's own guard)
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
