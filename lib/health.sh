# shellcheck shell=bash
# nice-dns health observations (ARCH-02 health.sh, ARCH-03 observe). Sourced;
# Bash 3.2 compatible (macOS /bin/bash), safe under set -u, BSD and GNU
# userland (no timeout, no flock). It only looks: it never restarts, writes
# state or decides an action (lib/policy.sh and lib/recovery.sh do).
#
#   nd_health_observe [budget_seconds]   print the observation records
#   nd_health_validate                   check records on stdin (0 valid)
#   nd_bounded <secs> <out> <err> <cmd...>
#                                        run cmd with a deadline; 124 on expiry
#   nd_dig_parse <file> <qname>          "kind<TAB>rcode<TAB>addresses" of a
#                                        saved dig reply (see below)
#
# Output (tab-separated data; never sourced or evaluated):
#   schema  nice-dns-observations/1
#   obs     <name>  healthy|unhealthy|indeterminate  <duration_ms>  <reason>
# The reason is one line without tabs or control characters. unhealthy is a
# definite failure; indeterminate means the observation could not be made
# (deadline, dig's own timeout, missing tool, unparseable output), which is
# never read as unhealthy or healthy. Names, in output order:
#   runtime        the runtime CLI answers and pi-hole, unbound and the Tor
#                  proxy (tor-haproxy or tor-socat) run. Reasons start with
#                  running: | cli-missing: | runtime-down: |
#                  containers-missing: | deadline:
#   dns-owner      the host resolves through nice-dns (platform adapter:
#                  Linux resolv.conf, macOS networksetup and scutil)
#   local-service  Pi-hole FTL answers pi.hole (A) at the platform endpoint
#   filtering      a blocklisted name (doubleclick.net) is sinkholed: every
#                  A record behind any CNAMEs is 0.0.0.0
#   local-cache    Pi-hole answers cloudflare.com (NOERROR or NXDOMAIN). This
#                  may be a cached or stale answer: it is NOT upstream health
#   route:<id>     one per row of routes/providers.tsv, in table order: an
#                  authenticated DNS query through that route, made by the
#                  proxy image's /usr/local/bin/nice-dns-route-probe with the
#                  route's port and TLS name (NXDOMAIN is working transport)
#   route-table    only when the route table cannot be read (then no
#                  route:<id> records are printed)
# A NXDOMAIN reply is an answer: the transport worked. SERVFAIL and other
# error rcodes are unhealthy. Probe names are fixed (pi.hole,
# doubleclick.net, cloudflare.com and the probe's "." SOA); no client query
# is ever replayed.
#
# Tunables (seconds unless noted): ND_HEALTH_CMD_DEADLINE (10, runtime and
# DNS-owner commands), ND_HEALTH_DIG_TIME (3) and ND_HEALTH_DIG_TRIES (2),
# ND_HEALTH_DNS_DEADLINE (TIME*TRIES+2), ND_HEALTH_PROBE_DEADLINE (15; the
# probe bounds itself at 10), ND_HEALTH_LOCAL_NAME, ND_HEALTH_FILTER_NAME,
# ND_HEALTH_CACHE_NAME, ND_TOR_VARIANT (haproxy|socat, when none runs),
# ND_ROUTES_FILE, ND_PLATFORM (linux|macos, default from uname).
# A deadline kills the command's whole process group; `<runtime> exec` stops
# the local client only, and the in-container probe ends on its own timeout.

ND_HEALTH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_ND_H_TAB="$(printf '\t')"

if ! declare -F nd_platform_dns_addr >/dev/null; then
  case "${ND_PLATFORM:-$(uname -s)}" in
    linux|Linux)
      # shellcheck source=lib/platform/linux.sh
      . "$ND_HEALTH_LIB_DIR/platform/linux.sh" ;;
    macos|Darwin)
      # shellcheck source=lib/platform/macos.sh
      . "$ND_HEALTH_LIB_DIR/platform/macos.sh" ;;
    *) printf 'health.sh: unsupported platform %s\n' "${ND_PLATFORM:-$(uname -s)}" >&2; return 1 ;;
  esac
fi

# nd_bounded <deadline_secs> <out> <err> <cmd...>: run cmd with stdin from
# /dev/null, stdout to <out>, stderr to <err>. Job control gives the command
# its own process group; a watchdog sends TERM to the group at the deadline
# and KILL a second later, and whatever is left in the group is killed when
# the command returns. Returns the command's status, 124 at the deadline,
# 127 when cmd is not found.
nd_bounded() {
  local dl="$1" out="$2" err="$3"
  shift 3
  case "$dl" in ''|*[!0-9]*|0) dl=1 ;; esac
  if ! command -v "$1" >/dev/null 2>&1; then
    : >"$out"; printf '%s: command not found\n' "$1" >"$err"
    return 127
  fi
  rm -f "$out.deadline"
  (
    set -m
    "$@" >"$out" 2>"$err" </dev/null &
    cpid=$!
    (
      sleep "$dl"
      : >"$out.deadline"
      kill -TERM -- "-$cpid" 2>/dev/null
      sleep 1
      kill -KILL -- "-$cpid" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    wpid=$!
    wait "$cpid"; rc=$?
    kill -KILL -- "-$wpid" 2>/dev/null
    kill -KILL -- "-$cpid" 2>/dev/null
    if [ -f "$out.deadline" ]; then rm -f "$out.deadline"; exit 124; fi
    exit "$rc"
  ) 2>/dev/null
}

# _nd_now_ms: wall clock in ms (Bash 5 EPOCHREALTIME; Bash 3.2 has whole
# seconds only, so durations there are multiples of 1000).
_nd_now_ms() {
  local s f
  if [ -n "${EPOCHREALTIME:-}" ]; then
    s="${EPOCHREALTIME%[.,]*}" f="${EPOCHREALTIME#*[.,]}000"
    printf '%s\n' "$((s * 1000 + 10#${f:0:3}))"
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

# nd_dig_parse <file> <qname>: read a full dig reply (never +short).
#   response<TAB>RCODE<TAB>A-addresses   a reply header was received; the
#       addresses are every A record of the answer section whose owner is
#       the query name after following its CNAME chain ("-" when none)
#   timeout|refused|unparsed<TAB>-<TAB>-
# Only the first reply's header and answer section count: ";;" error and
# warning lines, the question and authority sections, and records of other
# owners are never an answer.
nd_dig_parse() {
  awk -v q="$2" '
    function norm(n) { n = tolower(n); sub(/\.$/, "", n); return n }
    /^;; ->>HEADER<<-/ {
      if (!hdr && match($0, /status: [A-Z0-9]+/)) { rc = substr($0, RSTART + 8, RLENGTH - 8); hdr = 1 }
      next
    }
    /^;; ANSWER SECTION:/ { if (hdr && !done) insec = 1; next }
    insec && /^[ \t]*$/ { insec = 0; done = 1; next }
    insec && /^;/ { next }
    insec { if (NF >= 5 && $3 == "IN") { n++; own[n] = norm($1); typ[n] = $4; dat[n] = $5 }; next }
    /timed out/ { to = 1 }
    /connection refused/ { refused = 1 }
    END {
      if (hdr) {
        t = norm(q); hops = 0; moved = 1
        while (moved && hops < 16) {
          moved = 0
          for (i = 1; i <= n; i++) if (own[i] == t && typ[i] == "CNAME") { t = norm(dat[i]); hops++; moved = 1; break }
        }
        a = ""
        for (i = 1; i <= n; i++)
          if (own[i] == t && typ[i] == "A" && dat[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) a = a (a == "" ? "" : " ") dat[i]
        printf "response\t%s\t%s\n", rc, (a == "" ? "-" : a)
        exit
      }
      if (refused) { print "refused\t-\t-"; exit }
      if (to) { print "timeout\t-\t-"; exit }
      print "unparsed\t-\t-"
    }' "$1"
}

# _nd_obs <name> <verdict> <ms> <reason>: one record; the reason is folded to
# one line and stripped of control characters.
_nd_obs() {
  local r
  r="$(printf '%s' "$4" | tr '\t\r\n' '   ' | tr -d '\000-\010\013\014\016-\037\177' | cut -c1-300)"
  printf 'obs\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${r:--}"
}

# _nd_left: seconds of the observation budget left (at least 0).
_nd_left() {
  local l=$((_ND_H_BUDGET - (SECONDS - _ND_H_START)))
  [ "$l" -gt 0 ] || l=0
  printf '%s\n' "$l"
}

# _nd_deadline <default>: min(default, budget left); 0 when spent.
_nd_deadline() {
  local l
  l="$(_nd_left)"
  if [ "$1" -lt "$l" ]; then printf '%s\n' "$1"; else printf '%s\n' "$l"; fi
}

_nd_first_line() { head -n 1 "$1" 2>/dev/null | cut -c1-200; }

# ─── runtime ─────────────────────────────────────────────────────────────────

# Sets _ND_H_RT (ok|cli-missing|down|deadline), _ND_H_PROXY (the Tor proxy
# container name, running or expected, or empty).
_nd_obs_runtime() {
  local t0 dl rc f="$_ND_H_TMP/running" c missing="" v running
  t0="$(_nd_now_ms)"
  _ND_H_RT=deadline _ND_H_PROXY=""
  dl="$(_nd_deadline "${ND_HEALTH_CMD_DEADLINE:-10}")"
  if [ "$dl" -le 0 ]; then _nd_obs runtime indeterminate 0 "deadline: observation budget spent"; return 0; fi
  nd_platform_runtime_list "$dl" "$f"; rc=$?
  case "$rc" in
    0) ;;
    3) _ND_H_RT=cli-missing
       _nd_obs runtime unhealthy $(($(_nd_now_ms) - t0)) "cli-missing: no $(nd_platform_name) container runtime CLI found"
       return 0 ;;
    124) _nd_obs runtime indeterminate $(($(_nd_now_ms) - t0)) "deadline: listing containers gave no answer within ${dl}s"
       return 0 ;;
    *) _ND_H_RT=down
       _nd_obs runtime unhealthy $(($(_nd_now_ms) - t0)) "runtime-down: $(tr '\n' ' ' <"$f.err" | cut -c1-200)"
       return 0 ;;
  esac
  _ND_H_RT=ok
  for c in tor-haproxy tor-socat; do
    if grep -qxF "$c" "$f"; then _ND_H_PROXY="$c"; break; fi
  done
  if [ -z "$_ND_H_PROXY" ]; then
    v="${ND_TOR_VARIANT:-}"
    case "$v" in haproxy|socat) ;; *) v="$(nd_platform_installed_variant 2>/dev/null)" || v="" ;; esac
    [ -n "$v" ] && _ND_H_PROXY="tor-$v"
  fi
  for c in pi-hole unbound "${_ND_H_PROXY:-tor-haproxy|tor-socat}"; do
    grep -qxF "$c" "$f" || missing="$missing${missing:+ }$c"
  done
  running="$(tr '\n' ' ' <"$f" | sed 's/ *$//')"
  if [ -n "$missing" ]; then
    _nd_obs runtime unhealthy $(($(_nd_now_ms) - t0)) "containers-missing: $missing (running: ${running:-none})"
  else
    _nd_obs runtime healthy $(($(_nd_now_ms) - t0)) "running: pi-hole unbound $_ND_H_PROXY"
  fi
}

# ─── DNS owner ───────────────────────────────────────────────────────────────

_nd_obs_dns_owner() {
  local t0 dl line
  t0="$(_nd_now_ms)"
  dl="$(_nd_deadline "${ND_HEALTH_CMD_DEADLINE:-10}")"
  if [ "$dl" -le 0 ]; then _nd_obs dns-owner indeterminate 0 "deadline: observation budget spent"; return 0; fi
  line="$(nd_platform_dns_owner "$dl" | head -n 1)"
  case "$line" in
    healthy"$_ND_H_TAB"*|unhealthy"$_ND_H_TAB"*|indeterminate"$_ND_H_TAB"*)
      _nd_obs dns-owner "${line%%"$_ND_H_TAB"*}" $(($(_nd_now_ms) - t0)) "${line#*"$_ND_H_TAB"}" ;;
    *) _nd_obs dns-owner indeterminate $(($(_nd_now_ms) - t0)) "the platform adapter gave no verdict" ;;
  esac
}

# ─── DNS through Pi-hole ─────────────────────────────────────────────────────

_nd_name_ok() {
  case "$1" in ''|.*|*..*|*[!A-Za-z0-9.-]*) return 1 ;; esac
  return 0
}

# nd_dns_query <addr> <port> <qname> <deadline>: one A query with dig. Sets
# ND_Q_KIND (response timeout refused unparsed deadline missing), ND_Q_RCODE,
# ND_Q_ADDRS ("-" when none), ND_Q_MS.
nd_dns_query() {
  local t0 rc parsed tm="${ND_HEALTH_DIG_TIME:-3}" tr="${ND_HEALTH_DIG_TRIES:-2}"
  ND_Q_KIND=unparsed ND_Q_RCODE=- ND_Q_ADDRS=- ND_Q_MS=0
  t0="$(_nd_now_ms)"
  nd_bounded "$4" "$_ND_H_TMP/dig.out" "$_ND_H_TMP/dig.err" dig -p "$2" "@$1" "$3" A "+time=$tm" "+tries=$tr"
  rc=$?
  ND_Q_MS=$(($(_nd_now_ms) - t0))
  case "$rc" in
    124) ND_Q_KIND=deadline; return 0 ;;
    127) ND_Q_KIND=missing; return 0 ;;
  esac
  parsed="$(nd_dig_parse "$_ND_H_TMP/dig.out" "$3")"
  ND_Q_KIND="${parsed%%"$_ND_H_TAB"*}"; parsed="${parsed#*"$_ND_H_TAB"}"
  ND_Q_RCODE="${parsed%%"$_ND_H_TAB"*}"; ND_Q_ADDRS="${parsed#*"$_ND_H_TAB"}"
}

# _nd_obs_dns <name> <qname> <how>: query Pi-hole at the platform endpoint
# and classify. <how>: local (NOERROR with an A record), sinkhole (NOERROR,
# every A record 0.0.0.0) or answer (NOERROR or NXDOMAIN).
_nd_obs_dns() {
  local name="$1" q="$2" how="$3" addr dl at a
  addr="$(nd_platform_dns_addr)"; at="$addr#53"
  if ! _nd_name_ok "$q"; then _nd_obs "$name" indeterminate 0 "invalid probe name '$q'"; return 0; fi
  dl="$(_nd_deadline "${ND_HEALTH_DNS_DEADLINE:-$(( ${ND_HEALTH_DIG_TIME:-3} * ${ND_HEALTH_DIG_TRIES:-2} + 2 ))}")"
  if [ "$dl" -le 0 ]; then _nd_obs "$name" indeterminate 0 "deadline: observation budget spent"; return 0; fi
  nd_dns_query "$addr" 53 "$q" "$dl"
  case "$ND_Q_KIND" in
    deadline) _nd_obs "$name" indeterminate "$ND_Q_MS" "deadline: dig $q at $at gave no result within ${dl}s"; return 0 ;;
    missing) _nd_obs "$name" indeterminate "$ND_Q_MS" "dig not found"; return 0 ;;
    timeout) _nd_obs "$name" indeterminate "$ND_Q_MS" "dig timed out at $at ($q)"; return 0 ;;
    refused) _nd_obs "$name" unhealthy "$ND_Q_MS" "connection refused at $at ($q)"; return 0 ;;
    response) ;;
    *) _nd_obs "$name" indeterminate "$ND_Q_MS" "no DNS response header in dig output from $at ($q)"; return 0 ;;
  esac
  case "$how" in
    local)
      if [ "$ND_Q_RCODE" = NOERROR ] && [ "$ND_Q_ADDRS" != - ]; then
        _nd_obs "$name" healthy "$ND_Q_MS" "$q A $ND_Q_ADDRS from $at"
      elif [ "$ND_Q_RCODE" = NOERROR ]; then
        _nd_obs "$name" unhealthy "$ND_Q_MS" "$q NOERROR with no A record from $at"
      else
        _nd_obs "$name" unhealthy "$ND_Q_MS" "$q rcode $ND_Q_RCODE from $at"
      fi ;;
    sinkhole)
      if [ "$ND_Q_RCODE" != NOERROR ]; then
        _nd_obs "$name" unhealthy "$ND_Q_MS" "$q rcode $ND_Q_RCODE from $at (expected a 0.0.0.0 sinkhole)"
      elif [ "$ND_Q_ADDRS" = - ]; then
        _nd_obs "$name" unhealthy "$ND_Q_MS" "$q NOERROR with no A record from $at (expected a 0.0.0.0 sinkhole)"
      else
        for a in $ND_Q_ADDRS; do
          if [ "$a" != 0.0.0.0 ]; then
            _nd_obs "$name" unhealthy "$ND_Q_MS" "$q not sinkholed: A $ND_Q_ADDRS from $at"; return 0
          fi
        done
        _nd_obs "$name" healthy "$ND_Q_MS" "$q sinkholed to 0.0.0.0 at $at"
      fi ;;
    answer)
      case "$ND_Q_RCODE" in
        NOERROR|NXDOMAIN)
          _nd_obs "$name" healthy "$ND_Q_MS" "Pi-hole at $at answered $q $ND_Q_RCODE (A $ND_Q_ADDRS); a local answer may be cached or stale and is not upstream health" ;;
        *) _nd_obs "$name" unhealthy "$ND_Q_MS" "Pi-hole at $at answered $q rcode $ND_Q_RCODE" ;;
      esac ;;
  esac
}

# ─── provider routes ─────────────────────────────────────────────────────────

# nd_health_routes: validate routes/providers.tsv (the rules of
# lib/recovery.sh _nd_route_table) and print its rows
# "route<TAB>port<TAB>tls_name<TAB>provider<TAB>class". 2 bad table
# (problems on stderr).
nd_health_routes() {
  local f="${ND_ROUTES_FILE:-$ND_HEALTH_LIB_DIR/../routes/providers.tsv}"
  if [ ! -f "$f" ] || [ -L "$f" ]; then printf 'route table %s is missing or a symlink\n' "$f" >&2; return 2; fi
  awk -F '\t' '
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
      seen[$1] = 1; port[$2] = 1; rows[++n] = $0
    }
    END {
      if (!schema) bad("no schema row")
      if (!err && n == 0) bad("no routes")
      if (err) exit 2
      for (i = 1; i <= n; i++) print rows[i]
    }' "$f"
}

_ND_PROBE=/usr/local/bin/nice-dns-route-probe

# _nd_probe_one <i> <deadline> <port> <tls_name>: background worker; leaves
# r<i>.out, r<i>.err and r<i>.rc ("status<TAB>ms").
_nd_probe_one() {
  local t0 rc
  t0="$(_nd_now_ms)"
  nd_bounded "$2" "$_ND_H_TMP/r$1.out" "$_ND_H_TMP/r$1.err" nd_platform_proxy_exec "$_ND_H_PROXY" "$_ND_PROBE" "$3" "$4"
  rc=$?
  printf '%s\t%s\n' "$rc" $(($(_nd_now_ms) - t0)) >"$_ND_H_TMP/r$1.rc"
}

_nd_obs_routes() {
  local rows i=0 pids="" p id port name dl rc ms line res rcode pms why running=0
  if ! rows="$(nd_health_routes 2>"$_ND_H_TMP/routes.err")"; then
    _nd_obs route-table unhealthy 0 "$(tr '\n' ' ' <"$_ND_H_TMP/routes.err")"
    return 0
  fi
  case "$_ND_H_RT" in
    ok) if [ -n "$_ND_H_PROXY" ] && grep -qxF "$_ND_H_PROXY" "$_ND_H_TMP/running"; then running=1; fi ;;
    *) why="runtime unavailable (${_ND_H_RT}); the route cannot be probed" ;;
  esac
  dl="$(_nd_deadline "${ND_HEALTH_PROBE_DEADLINE:-15}")"
  if [ "$_ND_H_RT" = ok ] && [ "$running" -eq 1 ] && [ "$dl" -gt 0 ]; then
    while IFS="$_ND_H_TAB" read -r id port name _; do
      i=$((i + 1))
      _nd_probe_one "$i" "$dl" "$port" "$name" &
      pids="$pids $!"
    done <<EOF
$rows
EOF
    for p in $pids; do wait "$p"; done
  fi
  i=0
  while IFS="$_ND_H_TAB" read -r id port name _; do
    i=$((i + 1))
    if [ "$_ND_H_RT" != ok ]; then _nd_obs "route:$id" indeterminate 0 "$why"; continue; fi
    if [ "$running" -ne 1 ]; then
      _nd_obs "route:$id" unhealthy 0 "proxy container ${_ND_H_PROXY:-tor-haproxy or tor-socat} is not running"; continue
    fi
    if [ "$dl" -le 0 ]; then _nd_obs "route:$id" indeterminate 0 "deadline: observation budget spent"; continue; fi
    rc=1 ms=0
    if [ -f "$_ND_H_TMP/r$i.rc" ]; then IFS="$_ND_H_TAB" read -r rc ms <"$_ND_H_TMP/r$i.rc"; fi
    if [ "$rc" = 124 ]; then
      _nd_obs "route:$id" indeterminate "$ms" "deadline: probe of $_ND_H_PROXY:$port as $name gave no verdict within ${dl}s"; continue
    fi
    line="$(grep -E '^port=[0-9]+ name=[a-z0-9.-]+ result=(ok|dns-error|no-answer) rcode=[A-Z0-9-]+ ms=[0-9]+' "$_ND_H_TMP/r$i.out" 2>/dev/null | head -n 1)"
    if [ -z "$line" ]; then
      _nd_obs "route:$id" indeterminate "$ms" "probe gave no verdict (exit $rc): $(_nd_first_line "$_ND_H_TMP/r$i.err")"; continue
    fi
    case "$line" in
      "port=$port name=$name "*) ;;
      *) _nd_obs "route:$id" indeterminate "$ms" "probe answered for a different port or name: $line"; continue ;;
    esac
    res="${line#* result=}"; res="${res%% *}"
    rcode="${line#* rcode=}"; rcode="${rcode%% *}"
    pms="${line#* ms=}"; pms="${pms%% *}"
    case "$res" in
      ok) _nd_obs "route:$id" healthy "$ms" "rcode $rcode in $pms ms via $_ND_H_PROXY:$port as $name" ;;
      dns-error) _nd_obs "route:$id" unhealthy "$ms" "dns-error rcode $rcode via $_ND_H_PROXY:$port as $name" ;;
      *) _nd_obs "route:$id" unhealthy "$ms" "no-answer via $_ND_H_PROXY:$port as $name (refused, dropped, failed certificate or name check, or the probe's own timeout)" ;;
    esac
  done <<EOF
$rows
EOF
}

# nd_health_observe [budget_seconds]: every observation, bounded by the
# budget (default 60) and each command's own deadline.
nd_health_observe() {
  local rc=0
  _ND_H_BUDGET="${1:-60}"
  case "$_ND_H_BUDGET" in ''|*[!0-9]*) _ND_H_BUDGET=60 ;; esac
  _ND_H_START=$SECONDS
  _ND_H_TMP="$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-health.XXXXXX")" || { printf 'health.sh: cannot create a scratch directory\n' >&2; return 1; }
  printf 'schema\tnice-dns-observations/1\n'
  _nd_obs_runtime
  _nd_obs_dns_owner
  _nd_obs_dns local-service "${ND_HEALTH_LOCAL_NAME:-pi.hole}" local
  _nd_obs_dns filtering "${ND_HEALTH_FILTER_NAME:-doubleclick.net}" sinkhole
  _nd_obs_dns local-cache "${ND_HEALTH_CACHE_NAME:-cloudflare.com}" answer
  _nd_obs_routes || rc=1
  rm -rf "$_ND_H_TMP"
  return "$rc"
}

# nd_health_validate: 0 when stdin is a complete observation set: the schema
# row, then records with known names (each once, all fixed names present,
# and route:<id> records or a route-table record), known verdicts, integer
# durations and one-line reasons. Problems go to stderr.
nd_health_validate() {
  awk -F '\t' '
    function bad(m) { print "observation line " NR ": " m > "/dev/stderr"; err = 1 }
    NR == 1 { if ($0 != "schema\tnice-dns-observations/1") bad("expected schema<TAB>nice-dns-observations/1"); next }
    /[\001-\010\013-\037\177\r]/ { bad("control character"); next }
    $1 != "obs" || NF != 5 { bad("expected obs<TAB>name<TAB>verdict<TAB>ms<TAB>reason"); next }
    $2 !~ /^(runtime|dns-owner|local-service|filtering|local-cache|route-table|route:[a-z0-9]+(-[a-z0-9]+)*)$/ { bad("unknown observation name"); next }
    $3 !~ /^(healthy|unhealthy|indeterminate)$/ { bad("unknown verdict"); next }
    $4 !~ /^[0-9]+$/ { bad("duration is not an integer"); next }
    $5 == "" { bad("empty reason"); next }
    { if (seen[$2]++) bad("duplicate " $2); if ($2 ~ /^route/) routes++ }
    END {
      if (NR < 1) bad("no input")
      split("runtime dns-owner local-service filtering local-cache", need, " ")
      for (i = 1; i <= 5; i++) if (!(need[i] in seen)) bad("missing " need[i])
      if (!routes) bad("no route records")
      if (("route-table" in seen) && routes > 1) bad("route-table with route records")
      exit err ? 1 : 0
    }'
}
