# shellcheck shell=bash
# Group unit/observations (Sub-plan 3, Task 1.1; ARCH-01, ARCH-02, ARCH-03).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR). Drives
# lib/health.sh, the platform adapters (lib/platform/{linux,macos}.sh) and the
# health CLI against PATH stubs only: every case runs with PATH reduced to a
# case directory that holds fakes for podman, container, dig, networksetup,
# scutil, systemctl, journalctl, launchctl, ss, lsof and uname plus links to
# plain userland tools, so an unstubbed runtime or resolver command is "not
# found" rather than the host's real one. HOME and XDG_* point into the case
# directory. The one exception is t_bash32_runs_observations, which starts a
# throwaway docker.io/library/bash:3.2 container (--rm, no name, no network)
# to run the library under macOS's Bash version.
#
# NICE_DNS_OPT_PLATFORMS (--platforms all|linux|macos|linux,macos) selects
# the adapters the platform-generic cases exercise; default all.

OB_HEALTH="$NICE_DNS_ROOT/lib/health.sh"
OB_TAB="$(printf '\t')"
OB_TOOLS="awk basename bash cat chmod comm cp cut date dirname env expr find grep head id kill ln ls mkdir mktemp mv od readlink rm sed sh sleep sort stat tail tee touch tr uniq wc xargs"

ob_platforms() {
  local p="${NICE_DNS_OPT_PLATFORMS:-all}" x out=""
  [ "$p" = all ] && { printf 'linux macos\n'; return 0; }
  for x in $(printf '%s' "$p" | tr ',' ' '); do
    case "$x" in linux|macos) out="$out $x" ;; *) fail "unknown --platforms value '$x' (all, linux, macos)" ;; esac
  done
  printf '%s\n' "$out"
}

# ob_write_stubs <bindir>: POSIX sh fakes. Behaviour comes from files under
# $FAKE; every call is appended to $FAKE_LOG.
ob_write_stubs() {
  local b="$1"
  mkdir -p "$b"
  cat >"$b/dig" <<'STUB'
#!/bin/sh
l=dig; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
server="" port=53 q=""
while [ $# -gt 0 ]; do
  case "$1" in
    @*) server="${1#@}" ;;
    -p) port="$2"; shift ;;
    +*|-*) ;;
    *) [ -z "$q" ] && q="$1" ;;
  esac
  shift
done
f="$FAKE/dig/$q"
if [ "$server" != "$(cat "$FAKE/addr")" ] || [ "$port" != 53 ] || [ ! -f "$f" ]; then
  printf '\n; <<>> DiG 9.10.6 <<>> @%s %s\n; (1 server found)\n;; global options: +cmd\n;; connection timed out; no servers could be reached\n' "$server" "$q"
  exit 9
fi
if [ -f "$f.hang" ]; then sleep "$(cat "$FAKE/hang_secs")" & wait; exit 9; fi
cat "$f"
exit "$(cat "$f.rc" 2>/dev/null || echo 0)"
STUB
  # One runtime fake serves as podman (Linux) and container (macOS).
  cat >"$b/podman" <<'STUB'
#!/bin/sh
me="$(basename "$0")"
l="$me"; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
if [ -f "$FAKE/rt.hang" ]; then sleep "$(cat "$FAKE/hang_secs")" & wait; exit 1; fi
table() {
  printf 'ID           IMAGE                                    OS     ARCH   STATE    IP                 CPUS  MEMORY  STARTED\n'
  while IFS= read -r n; do
    [ -n "$n" ] && printf '%-12s %-40s linux  arm64  running  172.31.240.25x/29  1     256 MB  2026-09-23T22:16:33Z\n' "$n" "$n:latest"
  done <"$FAKE/running"
  if [ "$1" = all ] && [ -f "$FAKE/stopped" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] && printf '%-12s %-40s linux  arm64  stopped                     1     256 MB\n' "$n" "$n:latest"
    done <"$FAKE/stopped"
  fi
}
case "$1" in
  ps)
    if [ "$me" = container ]; then echo "Error: Plugin 'container-ps' not found."; exit 0; fi
    if [ -f "$FAKE/rt.down" ]; then printf 'Error: cannot open storage:\tdatabase is locked\nsecond line\n' >&2; exit 125; fi
    case "$*" in *-a*) cat "$FAKE/running" "$FAKE/stopped" 2>/dev/null ;; *) cat "$FAKE/running" ;; esac
    exit 0 ;;
  ls|list)
    [ "$me" = container ] || { echo "Error: unknown command \"$1\" for \"podman\"" >&2; exit 125; }
    if [ -f "$FAKE/rt.errexit0" ]; then echo "Error: XPC connection error: Connection invalid"; exit 0; fi
    if [ -f "$FAKE/rt.down" ]; then echo "Error: failed to connect to the container API server" >&2; exit 1; fi
    case "${2:-}" in -a|--all) table all ;; *) table running ;; esac
    exit 0 ;;
  exec)
    c="$2"; shift 2
    if ! grep -qxF "$c" "$FAKE/running"; then echo "Error: no container with name or ID \"$c\" found: no such container" >&2; exit 125; fi
    case "$1" in
      /usr/local/bin/nice-dns-route-probe)
        port="$2" name="$3"
        mode="$(cat "$FAKE/probe/$port" 2>/dev/null || echo ok)"
        case "$mode" in
          ok) echo "port=$port name=$name result=ok rcode=NOERROR ms=412"; exit 0 ;;
          nxdomain) echo "port=$port name=$name result=ok rcode=NXDOMAIN ms=380"; exit 0 ;;
          servfail) echo "port=$port name=$name result=dns-error rcode=SERVFAIL ms=90"; exit 1 ;;
          no-answer) echo "port=$port name=$name result=no-answer rcode=- ms=10004"; exit 1 ;;
          wrong-port) echo "port=1 name=$name result=ok rcode=NOERROR ms=5"; exit 0 ;;
          garbage) printf 'OCI runtime exec failed:\texec failed\nno such file\n' >&2; exit 126 ;;
          hang) sleep "$(cat "$FAKE/hang_secs")" & wait; exit 1 ;;
        esac ;;
    esac
    exit 0 ;;
  system) exit 0 ;;
esac
exit 0
STUB
  cp "$b/podman" "$b/container"
  cat >"$b/networksetup" <<'STUB'
#!/bin/sh
l=networksetup; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
case "$1" in
  -listallnetworkservices)
    echo "An asterisk (*) denotes that a network service is disabled."
    cat "$FAKE/services" ;;
  -getdnsservers)
    if [ -s "$FAKE/dns/$2" ]; then cat "$FAKE/dns/$2"; else echo "There aren't any DNS Servers set on $2."; fi ;;
esac
exit 0
STUB
  cat >"$b/scutil" <<'STUB'
#!/bin/sh
l=scutil; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
[ "$1" = --dns ] || exit 0
printf 'DNS configuration\n\nresolver #1\n  search domain[0] : Home\n  nameserver[0] : %s\n  flags    : Request A records\n  reach    : 0x00000002 (Reachable)\n\n' "$(cat "$FAKE/scutil_ns")"
printf 'resolver #2\n  domain   : local\n  options  : mdns\n  timeout  : 5\n  flags    : Request A records\n  reach    : 0x00000000 (Not Reachable)\n  order    : 300000\n\n'
printf 'DNS configuration (for scoped queries)\n\nresolver #1\n  search domain[0] : Home\n  nameserver[0] : 192.168.1.1\n  if_index : 15 (en0)\n  flags    : Scoped, Request A records\n  reach    : 0x00020002 (Reachable,Directly Reachable Address)\n'
exit 0
STUB
  local s
  # shellcheck disable=SC2016  # the stubs expand these when they run
  for s in systemctl journalctl launchctl ss lsof; do
    printf '#!/bin/sh\nl=%s; for a in "$@"; do l="$l $a"; done; printf "%%s\\n" "$l" >>"$FAKE_LOG"\nexit 0\n' "$s" >"$b/$s"
  done
  # shellcheck disable=SC2016  # expanded by the stub
  printf '#!/bin/sh\nprintf "%%s\\n" "${FAKE_UNAME:-Linux}"\n' >"$b/uname"
  for s in dig podman container networksetup scutil systemctl journalctl launchctl ss lsof uname; do chmod 755 "$b/$s"; done
}

# ob_dig_file <file> <qname> <status> [owner TYPE rdata]...: a full dig
# response (header, question, answer and, for negative answers, authority).
ob_dig_file() {
  local f="$1" q="$2" st="$3" r o t d
  shift 3
  {
    printf '\n; <<>> DiG 9.18.39-0ubuntu0.24.04.2-Ubuntu <<>> -p 53 @x %s A\n; (1 server found)\n;; global options: +cmd\n;; Got answer:\n' "$q"
    printf ';; ->>HEADER<<- opcode: QUERY, status: %s, id: 4242\n' "$st"
    printf ';; flags: qr rd ra; QUERY: 1, ANSWER: %s, AUTHORITY: 0, ADDITIONAL: 1\n\n' "$#"
    printf ';; OPT PSEUDOSECTION:\n; EDNS: version: 0, flags:; udp: 1232\n;; QUESTION SECTION:\n;%s.\t\t\tIN\tA\n\n' "$q"
    if [ $# -gt 0 ]; then
      printf ';; ANSWER SECTION:\n'
      for r in "$@"; do
        o="${r%% *}"; t="${r#* }"; d="${t#* }"; t="${t%% *}"
        printf '%s.\t300\tIN\t%s\t%s\n' "$o" "$t" "$d"
      done
      printf '\n'
    fi
    case "$st" in NXDOMAIN|NOERROR)
      [ $# -eq 0 ] && printf ';; AUTHORITY SECTION:\n%s.\t1800\tIN\tSOA\tns1.example. hostmaster.example. 1 2 3 4 5\n\n' "$q" ;;
    esac
    printf ';; Query time: 3 msec\n;; SERVER: x#53(x) (UDP)\n;; WHEN: Thu Sep 25 06:00:00 BST 2026\n;; MSG SIZE  rcvd: 59\n\n'
  } >"$f"
}
ob_dig() { ob_dig_file "$FAKE/dig/$1" "$@"; }

# ob_fake_data <fake dir> <platform>: a healthy stack.
ob_fake_data() {
  local d="$1" svc
  mkdir -p "$d/dig" "$d/probe" "$d/dns"
  : >"$d/calls.log"
  printf 'pi-hole\nunbound\ntor-haproxy\n' >"$d/running"
  if [ "$2" = macos ]; then printf '172.31.240.250\n' >"$d/addr"; else printf '127.0.0.1\n' >"$d/addr"; fi
  printf '%s\n' $((4000 + RANDOM % 900)) >"$d/hang_secs"
  printf 'Ethernet\nThunderbolt Bridge\nWi-Fi\n*USB 10/100/1000 LAN\n' >"$d/services"
  for svc in Ethernet 'Thunderbolt Bridge' Wi-Fi; do printf '172.31.240.250\n' >"$d/dns/$svc"; done
  printf '172.31.240.250\n' >"$d/scutil_ns"
  ob_dig_file "$d/dig/pi.hole" pi.hole NOERROR "pi.hole A 10.88.0.5"
  ob_dig_file "$d/dig/doubleclick.net" doubleclick.net NOERROR "doubleclick.net A 0.0.0.0"
  ob_dig_file "$d/dig/cloudflare.com" cloudflare.com NOERROR "cloudflare.com A 104.16.132.229" "cloudflare.com A 104.16.133.229"
}

# ob_setup [linux|macos]: fakes, reduced PATH, private HOME. Idempotent per
# platform switch (ob_platform re-seeds the fake data).
ob_setup() {
  local t p
  OB_PS="$(command -v ps)"
  OB_BIN="$CASE_DIR/bin"
  FAKE="$CASE_DIR/fake"; FAKE_LOG="$FAKE/calls.log"
  mkdir -p "$OB_BIN" "$CASE_DIR/home"
  for t in $OB_TOOLS; do
    p="$(command -v "$t")" && [ ! -e "$OB_BIN/$t" ] && ln -s "$p" "$OB_BIN/$t"
  done
  ob_write_stubs "$OB_BIN"
  HOME="$CASE_DIR/home"
  XDG_STATE_HOME="$HOME/.local/state" XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
  PATH="$OB_BIN"
  export HOME XDG_STATE_HOME XDG_CONFIG_HOME XDG_DATA_HOME PATH FAKE FAKE_LOG
  unset CONTAINER_BIN ND_TOR_VARIANT ND_ROUTES_FILE ND_HEALTH_DNS_DEADLINE ND_HEALTH_PROBE_DEADLINE ND_HEALTH_CMD_DEADLINE XDG_RUNTIME_DIR
  export ND_RESOLV_CONF="$CASE_DIR/resolv.conf" ND_CONTAINER_FALLBACK="$CASE_DIR/no-such-dir/container"
  printf '# written by custom-dns-deb\nnameserver 127.0.0.1\n' >"$ND_RESOLV_CONF"
  ob_platform "${1:-linux}"
}

ob_platform() {
  rm -rf "$FAKE"
  ob_fake_data "$FAKE" "$1"
  ND_PLATFORM="$1"
  if [ "$1" = macos ]; then FAKE_UNAME=Darwin; else FAKE_UNAME=Linux; fi
  export ND_PLATFORM FAKE_UNAME
}

# ob_observe [budget]: source the checkout library in a child bash and
# observe; OB_OUT, OB_RC, OB_ERR.
ob_observe() {
  OB_OUT="$(bash -c '. "$1" && nd_health_observe ${2:+"$2"}' _ "$OB_HEALTH" "${1:-}" 2>"$CASE_DIR/observe.err")"
  OB_RC=$?
  OB_ERR="$(cat "$CASE_DIR/observe.err")"
}

# ob_lib <shell code>: run code with lib/health.sh sourced; OB_OUT, OB_RC.
ob_lib() {
  OB_OUT="$(bash -c '. "$1" && eval "$2"' _ "$OB_HEALTH" "$1" 2>&1)"
  OB_RC=$?
}

ob_field() { printf '%s\n' "$OB_OUT" | awk -F '\t' -v n="$1" -v k="$2" '$1 == "obs" && $2 == n { print $k }'; }
ob_verdict() { ob_field "$1" 3; }
ob_reason() { ob_field "$1" 5; }

# ob_expect <name> <verdict> [reason ERE] [message]
ob_expect() {
  assert_eq "$2" "$(ob_verdict "$1")" "${4:-$ND_PLATFORM $1 verdict} (output: $(printf '%s' "$OB_OUT" | tr '\t\n' ' |'))"
  if [ -n "${3:-}" ]; then assert_match "$3" "$(ob_reason "$1")" "${4:-$ND_PLATFORM $1 reason}"; fi
}

ob_routes() { awk -F '\t' '/^#/ || /^$/ { next } $1 == "schema" { next } { print $1 }' "$NICE_DNS_ROOT/routes/providers.tsv"; }

# ob_no_proc <pattern>: no process whose command line is exactly <pattern>.
ob_no_proc() {
  local i=0 n
  while :; do
    n="$("$OB_PS" -eo args | grep -cx -- "$1")"
    [ "$n" -eq 0 ] && break
    i=$((i + 1)); [ "$i" -ge 30 ] && break
    sleep 0.1
  done
  assert_eq 0 "$n" "no process '$1' is left behind"
}

# ob_tree: a checkout-shaped copy (health/, lib/, routes/) with this case's
# private permissions; OB_TREE.
ob_tree() {
  OB_TREE="$CASE_DIR/tree"
  rm -rf "$OB_TREE"; mkdir -p "$OB_TREE"
  cp -R "$NICE_DNS_ROOT/health" "$NICE_DNS_ROOT/lib" "$NICE_DNS_ROOT/routes" "$OB_TREE/"
  chmod -R go-w "$OB_TREE"
}

ob_cli() {
  OB_OUT="$(bash "$@" 2>"$CASE_DIR/cli.err")"
  OB_RC=$?
  OB_ERR="$(cat "$CASE_DIR/cli.err")"
}

# ─────────────────────────── platform endpoints ──────────────────────────────

t_linux_adapter_queries_pod_loopback_endpoint() {
  ob_setup linux
  ob_observe
  assert_rc 0 "$OB_RC" "observe runs: $OB_ERR"
  ob_expect local-service healthy '10\.88\.0\.5'
  assert_match '^dig .*@127\.0\.0\.1 pi\.hole' "$(cat "$FAKE_LOG")" "Linux probes Pi-hole on the pod loopback"
  assert_not_match '@172\.31\.240\.250' "$(cat "$FAKE_LOG")" "Linux never queries the macOS dnsnet address"
}

t_macos_adapter_queries_pihole_dnsnet_address() {
  ob_setup macos
  ob_observe
  assert_rc 0 "$OB_RC" "observe runs: $OB_ERR"
  ob_expect local-service healthy '172\.31\.240\.250'
  ob_expect local-cache healthy
  ob_expect filtering healthy
  assert_match '^dig .*@172\.31\.240\.250 pi\.hole' "$(cat "$FAKE_LOG")" "macOS probes Pi-hole at its dnsnet address"
  assert_not_match '^dig .*@127\.0\.0\.1' "$(cat "$FAKE_LOG")" "macOS never queries 127.0.0.1"
}

# ─────────────────────────── DNS owner ───────────────────────────────────────

t_linux_dns_owner_reads_active_resolv_conf() {
  ob_setup linux
  ob_observe; ob_expect dns-owner healthy '127\.0\.0\.1'
  printf 'nameserver 127.0.0.53\noptions edns0 trust-ad\n' >"$ND_RESOLV_CONF"
  ob_observe; ob_expect dns-owner unhealthy '127\.0\.0\.53' "systemd-resolved stub is not nice-dns"
  printf 'nameserver 127.0.0.1\nnameserver 1.1.1.1\n' >"$ND_RESOLV_CONF"
  ob_observe; ob_expect dns-owner unhealthy '1\.1\.1\.1' "a public fallback nameserver behind 127.0.0.1 is drift"
  printf '# nameserver 1.1.1.1\n; nameserver 9.9.9.9\n  nameserver 127.0.0.1\nsearch lan\n' >"$ND_RESOLV_CONF"
  ob_observe; ob_expect dns-owner healthy '' "comments are not nameservers"
  rm -f "$ND_RESOLV_CONF"
  ob_observe; ob_expect dns-owner unhealthy 'missing' "no resolv.conf is not owned"
  assert_not_match '^(networksetup|scutil)' "$(cat "$FAKE_LOG")" "Linux never asks macOS tools"
}

t_macos_dns_owner_all_active_services_pinned() {
  ob_setup macos
  ob_observe
  ob_expect dns-owner healthy '3 active services'
  assert_match '^networksetup -getdnsservers Thunderbolt Bridge$' "$(cat "$FAKE_LOG")" "every enabled service is inspected"
  assert_not_match 'getdnsservers \*?USB' "$(cat "$FAKE_LOG")" "a disabled service is not inspected"
  assert_match '^scutil --dns$' "$(cat "$FAKE_LOG")" "the effective resolver is read natively"
}

t_macos_dns_owner_one_drifted_service_is_unhealthy() {
  ob_setup macos
  printf '1.1.1.1\n1.0.0.1\n' >"$FAKE/dns/Wi-Fi"
  ob_observe
  ob_expect dns-owner unhealthy 'Wi-Fi=1\.1\.1\.1,1\.0\.0\.1' "one drifted service"
  assert_not_match 'Ethernet=' "$(ob_reason dns-owner)" "pinned services are not reported as drift"
  ob_platform macos
  : >"$FAKE/dns/Thunderbolt Bridge"
  ob_observe
  ob_expect dns-owner unhealthy 'Thunderbolt Bridge=unset' "a service with no DNS servers is drift"
  ob_platform macos
  printf '172.31.240.250\n1.1.1.1\n' >"$FAKE/dns/Ethernet"
  ob_observe
  ob_expect dns-owner unhealthy 'Ethernet=172\.31\.240\.250,1\.1\.1\.1' "a public server beside Pi-hole is drift"
}

t_macos_dns_owner_uses_native_inspection_not_resolv_conf() {
  ob_setup macos
  printf 'nameserver 172.31.240.250\n' >"$ND_RESOLV_CONF"
  printf '10.64.0.1\n' >"$FAKE/scutil_ns"
  ob_observe
  ob_expect dns-owner unhealthy 'resolver #1.*10\.64\.0\.1' "scutil's effective resolver decides, not resolv.conf"
  ob_platform macos
  printf 'nameserver 127.0.0.1\n' >"$ND_RESOLV_CONF"
  ob_observe
  ob_expect dns-owner healthy '' "a Linux-style resolv.conf is irrelevant on macOS"
}

# ─────────────────────────── runtime ─────────────────────────────────────────

t_runtime_cli_missing_down_and_container_missing_are_distinct() {
  local plat cli r1 r2 r3 r
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    if [ "$plat" = macos ]; then cli=container; else cli=podman; fi
    ob_observe; ob_expect runtime healthy '^running: '
    mv "$OB_BIN/$cli" "$CASE_DIR/$cli.away"
    ob_observe; ob_expect runtime unhealthy '^cli-missing: ' "$plat: no runtime CLI"
    r1="$(ob_reason runtime)"
    for r in $(ob_routes); do ob_expect "route:$r" indeterminate 'runtime' "$plat: route $r cannot be probed without a runtime"; done
    mv "$CASE_DIR/$cli.away" "$OB_BIN/$cli"
    : >"$FAKE/rt.down"
    ob_observe; ob_expect runtime unhealthy '^runtime-down: ' "$plat: runtime not responding"
    r2="$(ob_reason runtime)"
    rm -f "$FAKE/rt.down"
    printf 'pi-hole\ntor-haproxy\n' >"$FAKE/running"
    ob_observe; ob_expect runtime unhealthy '^containers-missing: unbound' "$plat: a container is missing"
    r3="$(ob_reason runtime)"
    assert_ne "${r1%%:*}" "${r2%%:*}" "$plat: missing CLI and down runtime differ"
    assert_ne "${r2%%:*}" "${r3%%:*}" "$plat: down runtime and missing container differ"
    printf 'pi-hole\nunbound\n' >"$FAKE/running"
    ob_observe; ob_expect runtime unhealthy '^containers-missing: .*tor-' "$plat: no proxy container"
    for r in $(ob_routes); do ob_expect "route:$r" unhealthy 'not running' "$plat: route $r with no proxy"; done
    printf 'pi-hole\nunbound\ntor-haproxy\n' >"$FAKE/running"
    : >"$FAKE/rt.hang"
    ND_HEALTH_CMD_DEADLINE=1 ob_observe; ob_expect runtime indeterminate '^deadline: ' "$plat: a hung runtime is indeterminate"
    rm -f "$FAKE/rt.hang"
    ob_no_proc "sleep $(cat "$FAKE/hang_secs")"
  done
}

t_macos_runtime_error_line_with_exit_zero_is_down() {
  ob_setup macos
  : >"$FAKE/rt.errexit0"
  ob_observe
  ob_expect runtime unhealthy '^runtime-down: .*Error: XPC' "an Error: line is a failure even with exit 0"
  assert_not_match '^container ps' "$(cat "$FAKE_LOG")" "container ps (a missing plugin on Apple container) is never used"
}

t_macos_container_cli_found_at_fallback_path() {
  ob_setup macos
  mkdir -p "$CASE_DIR/opt"
  mv "$OB_BIN/container" "$CASE_DIR/opt/container"
  ND_CONTAINER_FALLBACK="$CASE_DIR/opt/container"
  ob_observe
  ob_expect runtime healthy '' "the fallback CLI path is used when container is not on PATH"
  ob_expect route:cloudflare-onion healthy
  assert_match '^container exec tor-haproxy /usr/local/bin/nice-dns-route-probe' "$(cat "$FAKE_LOG")" "probes run through the fallback CLI"
  : >"$FAKE_LOG"
  ND_CONTAINER_FALLBACK="$CASE_DIR/no-such-dir/container" CONTAINER_BIN="$CASE_DIR/opt/container" ob_observe
  ob_expect runtime healthy '' "CONTAINER_BIN is honoured"
}

# ─────────────────────────── DNS answers ─────────────────────────────────────

t_nxdomain_is_healthy_transport_and_servfail_is_not() {
  local plat
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    ob_dig cloudflare.com NXDOMAIN
    printf 'nxdomain\n' >"$FAKE/probe/18531"
    printf 'servfail\n' >"$FAKE/probe/18532"
    ob_observe
    ob_expect local-cache healthy 'NXDOMAIN' "$plat: NXDOMAIN through Pi-hole is an answer"
    ob_expect route:cloudflare-onion healthy 'NXDOMAIN' "$plat: a probe's NXDOMAIN is working transport"
    ob_expect route:cloudflare-exit unhealthy 'SERVFAIL' "$plat: a probe's SERVFAIL is not"
    ob_dig cloudflare.com SERVFAIL
    ob_observe
    ob_expect local-cache unhealthy 'SERVFAIL' "$plat: SERVFAIL through Pi-hole is not an answer"
    ob_dig pi.hole SERVFAIL
    ob_observe
    ob_expect local-service unhealthy 'SERVFAIL' "$plat: FTL answering SERVFAIL for pi.hole"
  done
}

t_dig_timeout_is_indeterminate_not_unhealthy() {
  local plat
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    rm -f "$FAKE/dig/pi.hole" "$FAKE/dig/doubleclick.net" "$FAKE/dig/cloudflare.com"
    ob_observe
    ob_expect local-service indeterminate 'timed out' "$plat: dig's own timeout"
    ob_expect filtering indeterminate 'timed out'
    ob_expect local-cache indeterminate 'timed out'
    printf 'no-answer\n' >"$FAKE/probe/853"
    ob_observe
    ob_expect route:cloudflare-legacy unhealthy 'no-answer' "$plat: the probe's own bounded verdict is a result"
  done
}

t_deadline_kills_hung_command_tree_within_budget() {
  local v el
  ob_setup linux
  v="$(cat "$FAKE/hang_secs")"
  : >"$FAKE/dig/pi.hole.hang"
  SECONDS=0
  ND_HEALTH_DNS_DEADLINE=1 ob_observe
  el=$SECONDS
  ob_expect local-service indeterminate '^deadline' "a hung dig is indeterminate, not unhealthy"
  ob_expect local-cache healthy '' "the next observation still runs"
  assert_match '^[0-6]$' "$el" "observe returned within budget (took ${el}s)"
  ob_no_proc "sleep $v"
  # The helper itself: the command's whole process tree dies at the deadline.
  SECONDS=0
  ob_lib "nd_bounded 1 \"\$TMPDIR/o\" \"\$TMPDIR/e\" sh -c 'sleep $v & sleep $v & wait'; echo rc=\$?"
  el=$SECONDS
  assert_match '^rc=124$' "$OB_OUT" "a deadline hit returns 124"
  assert_match '^[1-3]$' "$el" "killed within the deadline plus the grace second (took ${el}s)"
  ob_no_proc "sleep $v"
  ob_lib "nd_bounded 5 \"\$TMPDIR/o\" \"\$TMPDIR/e\" sh -c 'echo hi; exit 3'; echo rc=\$?; cat \"\$TMPDIR/o\""
  assert_match '^rc=3$' "$OB_OUT" "a finished command keeps its own exit status"
  assert_match '^hi$' "$OB_OUT" "and its output"
  ob_lib "nd_bounded 5 \"\$TMPDIR/o\" \"\$TMPDIR/e\" no-such-command-xyz; echo rc=\$?"
  assert_match '^rc=127$' "$OB_OUT" "a missing command is 127"
}

t_hung_route_probe_is_indeterminate_and_others_still_report() {
  local el
  ob_setup linux
  printf 'hang\n' >"$FAKE/probe/18532"
  SECONDS=0
  ND_HEALTH_PROBE_DEADLINE=1 ob_observe
  el=$SECONDS
  ob_expect route:cloudflare-exit indeterminate '^deadline' "a hung probe is indeterminate"
  ob_expect route:cloudflare-onion healthy
  ob_expect route:quad9-exit healthy
  assert_match '^[0-6]$' "$el" "probes run within one deadline (took ${el}s)"
  ob_no_proc "sleep $(cat "$FAKE/hang_secs")"
}

t_cname_chain_and_multiple_addresses_parse_fully() {
  ob_setup linux
  ob_dig cloudflare.com NOERROR "cloudflare.com CNAME edge.example.net." "edge.example.net CNAME edge2.example.net." \
    "edge2.example.net A 104.16.1.1" "edge2.example.net A 104.16.1.2"
  ob_dig doubleclick.net NOERROR "doubleclick.net CNAME sink.example." "sink.example A 0.0.0.0" "sink.example A 0.0.0.0"
  ob_dig pi.hole NOERROR "other.example A 1.2.3.4" "pi.hole CNAME nowhere.example."
  ob_observe
  ob_expect local-cache healthy '104\.16\.1\.1 104\.16\.1\.2' "a CNAME first line is followed to both addresses"
  ob_expect filtering healthy '' "every address behind the CNAME is the sinkhole"
  ob_expect local-service unhealthy 'no A record' "an unrelated owner's A record is not pi.hole's"
  ob_dig doubleclick.net NOERROR "doubleclick.net A 0.0.0.0" "doubleclick.net A 142.250.1.1"
  ob_observe
  ob_expect filtering unhealthy '142\.250\.1\.1' "a real address after a first 0.0.0.0 is not blocked"
  ob_dig_file "$CASE_DIR/d1" cloudflare.com NOERROR "Cloudflare.COM CNAME a.example." "A.Example A 9.9.9.8"
  ob_lib "nd_dig_parse \"$CASE_DIR/d1\" cloudflare.com"
  assert_eq "response${OB_TAB}NOERROR${OB_TAB}9.9.9.8" "$OB_OUT" "owner names compare case-insensitively"
}

t_error_text_on_stdout_never_counts_as_answer() {
  local f="$CASE_DIR/d"
  ob_setup linux
  printf ';; communications error to 127.0.0.1#53: timed out\n;; communications error to 127.0.0.1#53: timed out\n\n; <<>> DiG 9.18.39 <<>> -p 53 @127.0.0.1 pi.hole A\n; (1 server found)\n;; global options: +cmd\n;; no servers could be reached\n' >"$f"
  ob_lib "nd_dig_parse \"$f\" pi.hole"; assert_eq "timeout${OB_TAB}-${OB_TAB}-" "$OB_OUT" "communications errors are a timeout"
  printf ';; Connection to 172.31.240.250#53(172.31.240.250) for pi.hole failed: timed out.\n;; connection timed out; no servers could be reached\n' >"$f"
  ob_lib "nd_dig_parse \"$f\" pi.hole"; assert_eq "timeout${OB_TAB}-${OB_TAB}-" "$OB_OUT" "the macOS dig 9.10.6 TCP timeout text"
  printf ';; communications error to 127.0.0.1#53: connection refused\n;; communications error to 127.0.0.1#53: connection refused\n\n; <<>> DiG 9.18.39 <<>> pi.hole\n;; global options: +cmd\n;; no servers could be reached\n' >"$f"
  ob_lib "nd_dig_parse \"$f\" pi.hole"; assert_eq "refused${OB_TAB}-${OB_TAB}-" "$OB_OUT" "connection refused"
  printf ';; Warning: Message parser reports malformed message packet.\n0.0.0.0\n;; ANSWER SECTION:\npi.hole. 0 IN A 0.0.0.0\n' >"$f"
  ob_lib "nd_dig_parse \"$f\" pi.hole"; assert_eq "unparsed${OB_TAB}-${OB_TAB}-" "$OB_OUT" "records without a response header are not an answer"
  { printf ';; communications error to 127.0.0.1#53: timed out\n'; ob_dig_file "$CASE_DIR/ok" pi.hole NOERROR "pi.hole A 10.1.1.1"; cat "$CASE_DIR/ok"; } >"$f"
  ob_lib "nd_dig_parse \"$f\" pi.hole"; assert_eq "response${OB_TAB}NOERROR${OB_TAB}10.1.1.1" "$OB_OUT" "an answer after a retried timeout counts"
  # Through the observation: refused is unhealthy, error text is never healthy.
  printf ';; communications error to 127.0.0.1#53: connection refused\n;; no servers could be reached\n' >"$FAKE/dig/pi.hole"; printf '9\n' >"$FAKE/dig/pi.hole.rc"
  ob_observe; ob_expect local-service unhealthy 'refused'
  printf ';; Warning: 0.0.0.0\n0.0.0.0\n' >"$FAKE/dig/doubleclick.net"
  ob_observe; ob_expect filtering indeterminate 'no DNS response' "error text is never read as the sinkhole"
}

# ─────────────────────────── cache vs upstream (OP-CACHE-NOT-UPSTREAM) ───────

t_local_cache_healthy_while_every_route_unhealthy_stays_separate() {
  local plat r n
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    for r in 18531 18532 18533 853; do printf 'no-answer\n' >"$FAKE/probe/$r"; done
    ob_observe
    ob_expect local-cache healthy 'not upstream health' "$plat: Pi-hole still answers (cache or stale)"
    for r in $(ob_routes); do ob_expect "route:$r" unhealthy 'no-answer' "$plat: route $r is down"; done
    n="$(printf '%s\n' "$OB_OUT" | grep -c "^obs${OB_TAB}local-cache${OB_TAB}")"
    assert_eq 1 "$n" "$plat: exactly one local-cache record, separate from the route records"
    # The CLI's run no longer reads a cached answer as chain health.
    ob_tree
    ob_cli "$OB_TREE/health/nice-dns-health" run
    assert_rc 1 "$OB_RC" "$plat: run fails while every upstream route is down: $OB_ERR"
    assert_match 'FAIL \[.*chain-resolves' "$(cat "$(ob_logdir)/health.log")" "$plat: chain-resolves fails despite the cached answer"
    assert_match 'OK   local-cache' "$(cat "$(ob_logdir)"/failure-*.log)" "$plat: the dump still shows the local answer as a separate result"
  done
}

ob_logdir() {
  if [ "$ND_PLATFORM" = macos ]; then printf '%s\n' "$HOME/Library/Logs/nice-dns-health"; else printf '%s\n' "$XDG_STATE_HOME/nice-dns-health"; fi
}

# ─────────────────────────── routes ──────────────────────────────────────────

t_one_record_per_route_in_table() {
  local want got plat
  ob_setup linux
  want="$(ob_routes | sed 's/^/route:/')"
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    ob_observe
    got="$(printf '%s\n' "$OB_OUT" | awk -F '\t' '$1 == "obs" && $2 ~ /^route:/ { print $2 }')"
    assert_eq "$want" "$got" "$plat: one record per route, in table order"
    assert_match '^route:cloudflare-legacy$' "$got" "$plat: the compat route is observed too"
  done
  printf '# test table\nschema\tnice-dns-routes/1\nalpha\t18600\ta.example.net\tp1\tidentity\nbeta\t18601\tb.example.net\tp2\tcompat\n' >"$CASE_DIR/routes.tsv"
  ND_ROUTES_FILE="$CASE_DIR/routes.tsv" ob_observe
  got="$(printf '%s\n' "$OB_OUT" | awk -F '\t' '$1 == "obs" && $2 ~ /^route/ { print $2 }' | tr '\n' ' ')"
  assert_eq "route:alpha route:beta " "$got" "the table, not a built-in list, decides the routes"
  printf 'schema\tnice-dns-routes/1\nalpha\t18600\ta.example.net\tp1\tidentity\nbeta\t18600\tb.example.net\tp2\tidentity\n' >"$CASE_DIR/routes.tsv"
  ND_ROUTES_FILE="$CASE_DIR/routes.tsv" ob_observe
  ob_expect route-table unhealthy 'port 18600' "an invalid table is reported, not guessed around"
  assert_not_match "^obs${OB_TAB}route:" "$OB_OUT" "no route record comes from an invalid table"
}

t_probe_uses_each_route_port_and_tls_name() {
  local r port name
  ob_setup linux
  ob_observe
  while IFS="$OB_TAB" read -r r port name _; do
    case "$r" in ''|'#'*|schema) continue ;; esac
    assert_match "^podman exec tor-haproxy /usr/local/bin/nice-dns-route-probe $port $name\$" "$(cat "$FAKE_LOG")" "linux route $r probes its own port and TLS name"
    ob_expect "route:$r" healthy ":$port as $name"
  done <"$NICE_DNS_ROOT/routes/providers.tsv"
  ob_platform macos
  printf 'pi-hole\nunbound\ntor-socat\n' >"$FAKE/running"
  ob_observe
  assert_match '^container exec tor-socat /usr/local/bin/nice-dns-route-probe 18533 dns\.quad9\.net$' "$(cat "$FAKE_LOG")" "macOS execs in the socat proxy"
  assert_not_match 'tor-haproxy' "$(cat "$FAKE_LOG")" "the variant that runs is the one probed"
  printf 'wrong-port\n' >"$FAKE/probe/18531"
  printf 'garbage\n' >"$FAKE/probe/18532"
  ob_observe
  ob_expect route:cloudflare-onion indeterminate 'different port' "a verdict for another port is not this route's"
  ob_expect route:cloudflare-exit indeterminate 'no verdict' "an exec failure gives no verdict"
}

t_observations_query_only_controlled_names() {
  ob_setup linux
  ob_observe
  assert_eq "cloudflare.com doubleclick.net pi.hole " \
    "$(awk '$1 == "dig" { for (i = 2; i <= NF; i++) if ($i !~ /^[-+@]/ && $(i - 1) != "-p" && $i != "A") print $i }' "$FAKE_LOG" | LC_ALL=C sort -u | tr '\n' ' ')" \
    "only the fixed probe names are queried"
  assert_not_match 'nice-dns-route-probe [0-9]+ [a-z0-9.-]+ ' "$(cat "$FAKE_LOG")" "route probes pass no query name (the probe's controlled default)"
  ND_HEALTH_CACHE_NAME='evil.example;id' ob_observe
  ob_expect local-cache indeterminate 'invalid' "a malformed probe name is refused"
}

# ─────────────────────────── output format ───────────────────────────────────

t_observe_output_is_valid_tsv_with_one_line_reasons() {
  local plat
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    : >"$FAKE/rt.down"
    printf 'garbage\n' >"$FAKE/probe/18531"
    ob_observe
    assert_match "^schema${OB_TAB}nice-dns-observations/1\$" "$(printf '%s\n' "$OB_OUT" | head -n 1)" "$plat: schema row first"
    assert_eq "" "$(printf '%s\n' "$OB_OUT" | awk -F '\t' 'NR > 1 && ($1 != "obs" || NF != 5)')" "$plat: every record has exactly 5 fields"
    assert_eq "" "$(printf '%s\n' "$OB_OUT" | awk -F '\t' 'NR > 1 && $5 == ""')" "$plat: every record has a reason"
    printf '%s\n' "$OB_OUT" >"$CASE_DIR/obs.tsv"
    ob_lib "nd_health_validate <\"$CASE_DIR/obs.tsv\"; echo rc=\$?"
    assert_match '^rc=0$' "$OB_OUT" "$plat: the observation output validates"
    ob_observe
    if [ "$plat" = linux ]; then
      assert_match 'runtime-down: .*database is locked second line' "$(ob_reason runtime)" "$plat: a multi-line error with tabs becomes one line"
    else
      assert_match 'runtime-down: .*failed to connect' "$(ob_reason runtime)" "$plat: the runtime's error is the reason"
    fi
    assert_eq "runtime dns-owner local-service filtering local-cache route:cloudflare-onion route:cloudflare-exit route:quad9-exit route:cloudflare-legacy " \
      "$(printf '%s\n' "$OB_OUT" | awk -F '\t' '$1 == "obs" { print $2 }' | tr '\n' ' ')" "$plat: the documented names, in order"
  done
}

t_validator_rejects_malformed_observations() {
  local ok bad
  ob_setup linux
  ok="$(printf 'schema\tnice-dns-observations/1\n'; for n in runtime dns-owner local-service filtering local-cache route:a; do printf 'obs\t%s\thealthy\t1\tfine\n' "$n"; done)"
  printf '%s\n' "$ok" >"$CASE_DIR/v"
  ob_lib "nd_health_validate <\"$CASE_DIR/v\"; echo rc=\$?"; assert_match '^rc=0$' "$OB_OUT" "a well-formed set validates"
  # shellcheck disable=SC2016  # literal sed scripts; $(id) must stay text
  for bad in "s/^schema.*/schema\tnice-dns-observations\/2/" 's/runtime\thealthy/runtime\tgreen/' 's/dns-owner\thealthy\t1/dns-owner\thealthy\tx/' \
             's/filtering\thealthy\t1\tfine/filtering\thealthy\t1\tfi\tne/' 's/local-cache/eval $(id)/' 's/route:a/route:a\nobs\troute:a\thealthy\t1\tdup/' \
             '/local-service/d' 's/fine$//'; do
    printf '%s\n' "$ok" | sed "$bad" >"$CASE_DIR/v"
    ob_lib "nd_health_validate <\"$CASE_DIR/v\"; echo rc=\$?"
    assert_match '^rc=1$' "$OB_OUT" "rejected after: $bad"
  done
}

# ─────────────────────────── CLI ─────────────────────────────────────────────

t_cli_observe_and_run_from_checkout_layout() {
  local plat
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    ob_tree
    ob_cli "$OB_TREE/health/nice-dns-health" observe
    assert_rc 0 "$OB_RC" "$plat: observe from a checkout layout: $OB_ERR"
    printf '%s\n' "$OB_OUT" >"$CASE_DIR/obs.tsv"
    assert_match "^obs${OB_TAB}local-service${OB_TAB}healthy" "$OB_OUT" "$plat: observe prints records"
    ob_lib "nd_health_validate <\"$CASE_DIR/obs.tsv\"; echo rc=\$?"; assert_match '^rc=0$' "$OB_OUT" "$plat: CLI output validates"
    ob_cli "$OB_TREE/health/nice-dns-health" run
    assert_rc 0 "$OB_RC" "$plat: run passes on a healthy stack: $OB_ERR"
    assert_match 'OK  all checks passed' "$(cat "$(ob_logdir)/health.log")" "$plat: run logs a pass"
    if [ "$plat" = macos ]; then
      assert_match '^dig .*@172\.31\.240\.250' "$(cat "$FAKE_LOG")" "macOS run queries the dnsnet address"
      assert_not_match '@127\.0\.0\.1' "$(cat "$FAKE_LOG")" "macOS run never queries 127.0.0.1"
    fi
    printf 'no-answer\n' >"$FAKE/probe/18531"
    ob_cli "$OB_TREE/health/nice-dns-health" run
    assert_rc 1 "$OB_RC" "$plat: an unhealthy route fails the run"
    assert_match 'FAIL \[route:cloudflare-onion\]' "$(tail -n 1 "$(ob_logdir)/health.log")" "$plat: the failed observation is named"
    assert_not_match 'chain-resolves' "$(tail -n 1 "$(ob_logdir)/health.log")" "$plat: a usable route is not a chain outage"
    rm -f "$FAKE/probe/18531"
    printf 'hang\n' >"$FAKE/probe/18531"
    ND_HEALTH_PROBE_DEADLINE=1 ob_cli "$OB_TREE/health/nice-dns-health" run
    assert_rc 1 "$OB_RC" "$plat: an indeterminate result is not a pass"
    assert_match 'INDETERMINATE \[route:cloudflare-onion\]' "$(tail -n 1 "$(ob_logdir)/health.log")" "$plat: indeterminate is logged as such"
    rm -f "$FAKE/probe/18531"
  done
}

t_cli_run_keeps_recovery_on_upstream_outage() {
  local plat r cli
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    if [ "$plat" = macos ]; then cli=container; else cli=podman; fi
    for r in 18531 18532 18533 853; do printf 'servfail\n' >"$FAKE/probe/$r"; done
    ob_tree
    NICE_DNS_RESTART_GRACE_SECS=0 ob_cli "$OB_TREE/health/nice-dns-health" run
    assert_match 'full-outage detected' "$(cat "$(ob_logdir)/health.log")" "$plat: first failing run starts the grace window"
    # Sub-plan 3 Task 1.3: the restart is an acknowledged request; this fake
    # image never answers, so it is logged as not acknowledged and followed
    # by one service restart, which is not acknowledged either (the fake
    # container never comes back with a new start).
    ND_RECOVERY_ACK_S=2 ND_RECOVERY_SERVICE_S=4 NICE_DNS_RESTART_GRACE_SECS=0 ob_cli "$OB_TREE/health/nice-dns-health" run
    assert_not_match 'tor-restart-flag' "$(cat "$FAKE_LOG")" "$plat: the unacknowledged flag is never used"
    assert_match "^$cli exec tor-haproxy test -d /app/data/control\$" "$(cat "$FAKE_LOG")" "$plat: the acknowledged restart is requested"
    assert_match 'tor restart run-[0-9]+: not-acknowledged' "$(cat "$(ob_logdir)/health.log")" "$plat: an unanswered request is logged as not acknowledged"
    assert_not_match 'triggered graceful' "$(cat "$(ob_logdir)/health.log")" "$plat: a request is never logged as a done restart"
    if [ "$plat" = macos ]; then
      assert_match '^launchctl kickstart -k gui/[0-9]+/org\.nice-dns\.start-container$' "$(cat "$FAKE_LOG")" "$plat: one service-level fallback"
    else
      assert_match '^systemctl --user restart tor-haproxy\.service$' "$(cat "$FAKE_LOG")" "$plat: one service-level fallback"
    fi
    assert_match 'service restart run-[0-9]+-svc: not-acknowledged' "$(cat "$(ob_logdir)/health.log")" "$plat: a fallback without a new container start is not acknowledged"
  done
}

t_installed_copy_finds_libraries_after_checkout_moves() {
  local plat root
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    ob_tree
    ob_cli "$OB_TREE/health/nice-dns-health" install
    assert_rc 0 "$OB_RC" "$plat: install with stubbed scheduler: $OB_ERR"
    if [ "$plat" = macos ]; then root="$HOME/Library/Application Support/nice-dns-health"; else root="$XDG_DATA_HOME/nice-dns-health"; fi
    assert_file "$root/lib/health.sh" "$plat: libraries installed"
    assert_file "$root/lib/platform/$plat.sh" "$plat: platform adapter installed"
    assert_file "$root/routes/providers.tsv" "$plat: route table installed"
    assert_eq "" "$(find "$root" \( -perm -0020 -o -perm -0002 \) -print)" "$plat: nothing installed is group or world writable"
    rm -rf "$OB_TREE"
    ob_cli "$HOME/.local/bin/nice-dns-health" observe
    assert_rc 0 "$OB_RC" "$plat: the installed copy observes after the checkout is gone: $OB_ERR"
    assert_match "^obs${OB_TAB}route:quad9-exit${OB_TAB}healthy" "$OB_OUT" "$plat: installed copy reads the installed route table"
    ob_cli "$HOME/.local/bin/nice-dns-health" uninstall
    assert_no_path "$root" "$plat: uninstall removes the libraries"
    assert_no_path "$HOME/.local/bin/nice-dns-health" "$plat: and the script"
  done
}

t_installed_lookup_refuses_unsafe_or_symlinked_lib_dir() {
  local root bin
  ob_setup linux
  ob_tree
  ob_cli "$OB_TREE/health/nice-dns-health" install
  assert_rc 0 "$OB_RC" "install: $OB_ERR"
  root="$XDG_DATA_HOME/nice-dns-health" bin="$HOME/.local/bin/nice-dns-health"
  printf '\n: >"%s/canary"\n' "$CASE_DIR" >>"$root/lib/health.sh"
  ob_cli "$bin" observe
  assert_rc 0 "$OB_RC" "a safe installed tree is used: $OB_ERR"
  assert_file "$CASE_DIR/canary" "the canary proves the library is sourced"
  rm -f "$CASE_DIR/canary"
  chmod g+w "$root/lib"
  ob_cli "$bin" observe
  assert_rc 2 "$OB_RC" "group-writable lib dir refused"
  assert_match 'writable by group or others' "$OB_ERR" "says why"
  assert_no_path "$CASE_DIR/canary" "nothing was sourced from it"
  chmod g-w "$root/lib"; chmod o+w "$root/lib/platform/linux.sh"
  ob_cli "$bin" observe
  assert_rc 2 "$OB_RC" "world-writable adapter refused"
  chmod o-w "$root/lib/platform/linux.sh"
  mv "$root/lib" "$root/lib.real"; ln -s lib.real "$root/lib"
  ob_cli "$bin" observe
  assert_rc 2 "$OB_RC" "symlinked lib dir refused"
  assert_match 'symlink' "$OB_ERR" "says it is a symlink"
  assert_no_path "$CASE_DIR/canary" "nothing was sourced through the symlink"
  rm "$root/lib"; mv "$root/lib.real" "$root/lib"
  mv "$root/lib/health.sh" "$CASE_DIR/h.sh"; ln -s "$CASE_DIR/h.sh" "$root/lib/health.sh"
  ob_cli "$bin" observe
  assert_rc 2 "$OB_RC" "symlinked library file refused"
  rm "$root/lib/health.sh"; mv "$CASE_DIR/h.sh" "$root/lib/health.sh"
  ob_cli "$bin" run
  assert_rc 0 "$OB_RC" "restored tree works again for run: $OB_ERR"
  assert_file "$CASE_DIR/canary" "sourced again once safe"
  # The checkout layout gets the same checks.
  chmod g+w "$OB_TREE/lib"
  ob_cli "$OB_TREE/health/nice-dns-health" observe
  assert_rc 2 "$OB_RC" "a group-writable checkout lib dir is refused too"
}

t_existing_cli_subcommands_still_work() {
  local plat
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    ob_tree
    ob_cli "$OB_TREE/health/nice-dns-health" help
    assert_rc 0 "$OB_RC" "$plat: help"
    assert_match '^  observe ' "$OB_OUT" "$plat: usage lists observe"
    ob_cli "$OB_TREE/health/nice-dns-health" logs
    assert_rc 0 "$OB_RC" "$plat: logs"
    ob_cli "$OB_TREE/health/nice-dns-health" failures
    assert_rc 0 "$OB_RC" "$plat: failures"
    ob_cli "$OB_TREE/health/nice-dns-health" status
    assert_rc 0 "$OB_RC" "$plat: status"
    ob_cli "$OB_TREE/health/nice-dns-health" start
    assert_rc 0 "$OB_RC" "$plat: start"
    ob_cli "$OB_TREE/health/nice-dns-health" stop
    assert_rc 0 "$OB_RC" "$plat: stop"
    ob_cli "$OB_TREE/health/nice-dns-health" bogus
    assert_rc 2 "$OB_RC" "$plat: unknown command"
    # The same tree with its libraries unusable: commands that need none still work.
    chmod g+w "$OB_TREE/lib"
    ob_cli "$OB_TREE/health/nice-dns-health" status
    assert_rc 0 "$OB_RC" "$plat: status needs no library"
  done
}

# ─────────────────────────── macOS interpreter ───────────────────────────────

t_bash32_runs_observations() {
  local w="$CASE_DIR/b32" img=docker.io/library/bash:3.2 out rc
  if ! podman image exists "$img" 2>/dev/null; then
    fail "image $img is not available locally; the Bash 3.2 proof cannot run (pull it: podman pull $img)"
  fi
  mkdir -p "$w"
  ob_write_stubs "$w/bin"
  ob_fake_data "$w/fake" linux
  printf 'nameserver 127.0.0.1\n' >"$w/resolv.conf"
  cat >"$w/inner.sh" <<'INNER'
set -u
case "$BASH_VERSION" in 3.2.*) ;; *) echo "not bash 3.2: $BASH_VERSION"; exit 90 ;; esac
echo "bash=$BASH_VERSION"
PATH="/work/bin:$PATH" FAKE=/work/fake FAKE_LOG=/work/fake/calls.log ND_RESOLV_CONF=/work/resolv.conf
ND_CONTAINER_FALLBACK=/nonexistent/container TMPDIR=/tmp
export PATH FAKE FAKE_LOG ND_RESOLV_CONF ND_CONTAINER_FALLBACK TMPDIR
for plat in linux macos; do
  if [ "$plat" = macos ]; then echo 172.31.240.250 >/work/fake/addr; else echo 127.0.0.1 >/work/fake/addr; fi
  ND_PLATFORM=$plat bash -c '. /src/lib/health.sh && nd_health_observe 60' >/work/obs-$plat.tsv 2>/work/obs-$plat.err
  echo "observe-$plat=$?"
  ND_PLATFORM=$plat bash -c '. /src/lib/health.sh && nd_health_validate' </work/obs-$plat.tsv
  echo "validate-$plat=$?"
done
bash -c '. /src/lib/health.sh && nd_dig_parse /work/fake/dig/cloudflare.com cloudflare.com' | tr '\t' '|'
v=$(cat /work/fake/hang_secs)
SECONDS=0
ND_PLATFORM=linux bash -c '. /src/lib/health.sh && nd_bounded 1 /tmp/o /tmp/e sh -c "sleep $1 & sleep $1 & wait"' _ "$v"
echo "bounded=$? secs=$SECONDS"
sleep 1
echo "left=$(ps | grep -c "[s]leep $v")"
# The CLI itself (macOS runs it with /bin/bash 3.2): healthy, indeterminate
# only (an empty FAILED_CHECKS under set -u) and failing runs.
mkdir -p /tmp/tree /tmp/home && cp -R /src/health /src/lib /src/routes /tmp/tree/ && chmod -R go-w /tmp/tree
HOME=/tmp/home XDG_STATE_HOME=/tmp/home/state XDG_DATA_HOME=/tmp/home/share XDG_CONFIG_HOME=/tmp/home/config
export HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CONFIG_HOME
for plat in linux macos; do
  if [ "$plat" = macos ]; then echo 172.31.240.250 >/work/fake/addr; FAKE_UNAME=Darwin; log=$HOME/Library/Logs/nice-dns-health/health.log
  else echo 127.0.0.1 >/work/fake/addr; FAKE_UNAME=Linux; log=$XDG_STATE_HOME/nice-dns-health/health.log; fi
  export FAKE_UNAME
  bash /tmp/tree/health/nice-dns-health run >/dev/null 2>/work/cli-$plat.err; echo "cli-run-$plat=$?"
  echo hang >/work/fake/probe/18531
  ND_HEALTH_PROBE_DEADLINE=1 bash /tmp/tree/health/nice-dns-health run >/dev/null 2>>/work/cli-$plat.err; echo "cli-indeterminate-$plat=$?"
  for p in 18531 18532 18533 853; do echo servfail >/work/fake/probe/$p; done
  bash /tmp/tree/health/nice-dns-health run >/dev/null 2>>/work/cli-$plat.err; echo "cli-fail-$plat=$?"
  rm -f /work/fake/probe/*
  sed "s/^/log-$plat: /" "$log"
  sed "s/^/err-$plat: /" /work/cli-$plat.err
done
INNER
  out="$(podman run --rm --network none --pull=never -v "$NICE_DNS_ROOT:/src:ro" -v "$w:/work" "$img" bash /work/inner.sh 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  assert_rc 0 "$rc" "the bash 3.2 container ran"
  assert_match '^bash=3\.2\.' "$out" "the interpreter is Bash 3.2"
  assert_match '^observe-linux=0$' "$out" "linux observe under 3.2"
  assert_match '^observe-macos=0$' "$out" "macos observe under 3.2"
  assert_match '^validate-linux=0$' "$out" "linux output validates under 3.2"
  assert_match '^validate-macos=0$' "$out" "macos output validates under 3.2"
  assert_match '^response\|NOERROR\|104\.16\.132\.229 104\.16\.133\.229$' "$out" "dig parse under 3.2 (BusyBox awk)"
  assert_match '^bounded=124 secs=[12]$' "$out" "the deadline holds under 3.2"
  assert_match '^left=0$' "$out" "no process left under 3.2"
  assert_eq 9 "$(awk -F '\t' '$1 == "obs" && $3 == "healthy"' "$w/obs-linux.tsv" | wc -l | tr -d ' ')" "all nine linux observations healthy under 3.2"
  assert_eq 9 "$(awk -F '\t' '$1 == "obs" && $3 == "healthy"' "$w/obs-macos.tsv" | wc -l | tr -d ' ')" "all nine macos observations healthy under 3.2"
  for p in linux macos; do
    assert_match "^cli-run-$p=0\$" "$out" "$p: CLI run passes under 3.2"
    assert_match "^cli-indeterminate-$p=1\$" "$out" "$p: CLI indeterminate run under 3.2"
    assert_match "^cli-fail-$p=1\$" "$out" "$p: CLI failing run under 3.2"
    assert_match "^log-$p: .* OK  all checks passed\$" "$out" "$p: pass logged under 3.2"
    assert_match "^log-$p: .* INDETERMINATE \\[route:cloudflare-onion\\]" "$out" "$p: indeterminate logged under 3.2"
    assert_match "^log-$p: .* FAIL \\[.*chain-resolves\\]" "$out" "$p: chain outage logged under 3.2"
    # (Faking Darwin on this userland, the existing log rotation's BSD
    # `stat -f %z` prints GNU/BusyBox noise; only shell errors count here.)
    assert_not_match "^err-$p: .*(unbound variable|syntax error|command not found|bad substitution)" "$out" "$p: no Bash 3.2 shell error from the CLI"
  done
}
