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
OB_TOOLS="awk basename bash cat chmod comm cp cut date dirname env expr find grep head id kill ln ls mkdir mktemp mv od readlink rm sed sh sha256sum sleep sort stat tail tee touch tr uniq wc xargs"

ob_platforms() {
  local p="${NICE_DNS_OPT_PLATFORMS:-all}" x out=""
  [ "$p" = all ] && { printf 'linux macos\n'; return 0; }
  for x in $(printf '%s' "$p" | tr ',' ' '); do
    case "$x" in linux|macos) out="$out $x" ;; *) fail "unknown --platforms value '$x' (all, linux, macos)" ;; esac
  done
  printf '%s\n' "$out"
}

. "$NICE_DNS_ROOT/tests/fixtures/health-fakes.sh"

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
  # A healthy host has an installed generation (install-drift, BL-045).
  ob_install_state
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
  local plat drift
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
    if [ "$plat" = linux ]; then drift="install-drift "; else drift=""; fi
    assert_eq "runtime container:pi-hole container:unbound proxy dns-owner ${drift}local-service filtering local-cache route:cloudflare-onion route:cloudflare-exit route:quad9-exit route:cloudflare-legacy unbound " \
      "$(printf '%s\n' "$OB_OUT" | awk -F '\t' '$1 == "obs" { print $2 }' | tr '\n' ' ')" "$plat: the documented names, in order (install-drift on Linux only; no proxy name, so no container:<proxy>, while the runtime is down)"
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
    assert_match 'FAIL \[route:cloudflare-onion\]' "$(grep -v " controller " "$(ob_logdir)/health.log" | tail -n 1)" "$plat: the failed observation is named"
    assert_not_match 'chain-resolves' "$(grep -v " controller " "$(ob_logdir)/health.log" | tail -n 1)" "$plat: a usable route is not a chain outage"
    rm -f "$FAKE/probe/18531"
    printf 'hang\n' >"$FAKE/probe/18531"
    ND_HEALTH_PROBE_DEADLINE=1 ob_cli "$OB_TREE/health/nice-dns-health" run
    assert_rc 1 "$OB_RC" "$plat: an indeterminate result is not a pass"
    assert_match 'INDETERMINATE \[route:cloudflare-onion\]' "$(grep -v " controller " "$(ob_logdir)/health.log" | tail -n 1)" "$plat: indeterminate is logged as such"
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
    # Since the Sub-plan 3 Stage 1 gate, `run` decides through the controller
    # pass (lib/policy.sh): with no startup allowance and no grace, the first
    # failing run restarts Tor. This fake image never answers, so the request
    # is not acknowledged and one service restart follows, which is not
    # acknowledged either (the container never comes back with a new start).
    ND_POLICY_STARTUP_S=0 ND_RECOVERY_ACK_S=2 ND_RECOVERY_SERVICE_S=4 NICE_DNS_RESTART_GRACE_SECS=0 ob_cli "$OB_TREE/health/nice-dns-health" run
    assert_not_match 'tor-restart-flag' "$(cat "$FAKE_LOG")" "$plat: the unacknowledged flag is never used"
    assert_match "^$cli exec tor-haproxy test -d /app/data/control\$" "$(cat "$FAKE_LOG")" "$plat: the acknowledged restart is requested"
    assert_match 'controller action=restart-component target=tor result=not-acknowledged' "$(cat "$(ob_logdir)/health.log")" "$plat: the run log carries the controller's decision and its real result"
    assert_not_match 'triggered graceful' "$(cat "$(ob_logdir)/health.log")" "$plat: a request is never logged as a done restart"
    if [ "$plat" = macos ]; then
      assert_match '^launchctl kickstart -k gui/[0-9]+/org\.nice-dns\.start-container$' "$(cat "$FAKE_LOG")" "$plat: one service-level fallback"
    else
      assert_match '^systemctl --user restart tor-haproxy\.service$' "$(cat "$FAKE_LOG")" "$plat: one service-level fallback"
    fi
    # The next run is inside the cooldown: the same state stops a second restart.
    : >"$FAKE_LOG"
    ND_POLICY_STARTUP_S=0 NICE_DNS_RESTART_GRACE_SECS=0 ob_cli "$OB_TREE/health/nice-dns-health" run
    assert_not_match 'test -d /app/data/control' "$(cat "$FAKE_LOG")" "$plat: no second restart inside the cooldown"
    assert_match 'controller action=no-op' "$(tail -n 1 "$(ob_logdir)/health.log")" "$plat: the controller holds"
  done
}

t_installed_copy_finds_libraries_after_checkout_moves() {
  local plat root bundle
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    ob_tree
    ob_cli "$OB_TREE/health/nice-dns-health" install
    assert_rc 0 "$OB_RC" "$plat: install with stubbed scheduler: $OB_ERR"
    if [ "$plat" = macos ]; then root="$HOME/Library/Application Support/nice-dns-health"; else root="$XDG_DATA_HOME/nice-dns-health"; fi
    # Since Sub-plan 3 Task 2.1 the libraries live in a versioned bundle.
    bundle="$root/bundles/$(awk -F '\t' '$1 == "bundle" { print $2 }' "$root/install.tsv")"
    assert_file "$bundle/lib/health.sh" "$plat: libraries installed"
    assert_file "$bundle/lib/platform/$plat.sh" "$plat: platform adapter installed"
    assert_file "$bundle/routes/providers.tsv" "$plat: route table installed"
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
  # The installed copy reads its versioned bundle (Sub-plan 3 Task 2.1).
  root="$XDG_DATA_HOME/nice-dns-health" bin="$HOME/.local/bin/nice-dns-health"
  root="$root/bundles/$(awk -F '\t' '$1 == "bundle" { print $2 }' "$root/install.tsv")"
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
# An installed generation (install-drift, BL-045): a healthy Linux host.
g=20261012T120000Z-0123456789ab
mkdir -p "$XDG_STATE_HOME/nice-dns-install/generations/$g"
echo "$g" >"$XDG_STATE_HOME/nice-dns-install/current"
printf 'schema\tnice-dns-install-prepare/1\n' >"$XDG_STATE_HOME/nice-dns-install/generations/$g/prepare.tsv"
mkdir -p "$XDG_CONFIG_HOME/containers/systemd"
printf '[Pod]\nPublishPort=127.0.0.1:53:53/udp\n' >"$XDG_CONFIG_HOME/containers/systemd/nice-dns.pod"
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
  assert_eq 14 "$(awk -F '\t' '$1 == "obs" && $3 == "healthy"' "$w/obs-linux.tsv" | wc -l | tr -d ' ')" "all fourteen linux observations healthy under 3.2 (proxy, unbound, then the three container records added)"
  assert_eq 14 "$(awk -F '\t' '$1 == "obs" && $3 == "healthy"' "$w/obs-macos.tsv" | wc -l | tr -d ' ')" "all fourteen macos observations healthy under 3.2 (proxy, unbound, then the three container records added)"
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

t_failure_dump_reads_logs_and_holds_no_bridge_material() {
  # Task 2.3 privacy-safe diagnostics (PRIV-NO-SECRETS): the dump reads each
  # container's recent log with the platform CLI's own flag and never carries
  # bridge lines, certificates or fingerprints (Tor's log and, on macOS,
  # `container inspect`, whose JSON holds the proxy's BRIDGE environment).
  local plat r d fp=0123456789ABCDEF0123456789ABCDEF01234567
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    for r in 18531 18532 18533 853; do printf 'no-answer\n' >"$FAKE/probe/$r"; done
    printf '%s\n' "Sep 25 [notice] Bootstrapped 100% (done): Done" \
      "Sep 25 [warn] Bridge at obfs4 192.0.2.9:443 $fp cert=AbCdEfGhIjKlMnOpQrStUv0123+/= iat-mode=0 unreachable" \
      "BRIDGE1=obfs4 192.0.2.10:443 $fp cert=ZyXwVuTsRqPoNmLkJiHg9876+/= iat-mode=0" >"$FAKE/logs"
    ob_tree
    ob_cli "$OB_TREE/health/nice-dns-health" run
    d="$(cat "$(ob_logdir)"/failure-*.log)"
    assert_match 'Bootstrapped 100%' "$d" "$plat: the dump holds the containers' recent log"
    assert_not_match 'unknown option' "$d" "$plat: read with the CLI's own tail flag"
    assert_not_match 'cert=[A-Za-z0-9+/=]{6}' "$d" "$plat: no bridge certificate"
    assert_not_match "$fp" "$d" "$plat: no bridge fingerprint"
    assert_not_match '192\.0\.2\.(9|10):443' "$d" "$plat: no bridge address"
    if [ "$plat" = macos ]; then
      assert_not_match '^container inspect' "$(cat "$FAKE_LOG")" "macos: the dump never runs container inspect (its JSON holds the BRIDGE environment)"
    fi
  done
}

t_probe_timeout_is_unhealthy_not_indeterminate() {
  # A frozen Tor: the probe's own timeout (error=timeout) is a verdict, so the
  # route is unhealthy and the outage clock can run. Live evidence: Sub-plan 3
  # Task 2.3 on mint, where probes killed by the host deadline read as
  # indeterminate and the controller never saw the outage.
  local plat r
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    for r in 18531 18532 18533 853; do printf 'timeout\n' >"$FAKE/probe/$r"; done
    ob_observe
    for r in $(ob_routes); do ob_expect "route:$r" unhealthy 'no-answer' "$plat: route $r timed out in the probe"; done
  done
}

# Sub-plan 5 Task 1.3: the proxy's generation, which changes when the proxy
# restarts or is recreated (the policy's fresh-proxy rule, ARCH-04).
t_proxy_generation_is_observed_and_changes_on_restart() {
  local plat g1 g2
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    ob_observe
    ob_expect proxy healthy '^generation:[0-9a-f]{16}$' "$plat: the proxy's generation"
    g1="$(ob_reason proxy)"
    printf '2026-09-28T21:00:00Z\n' >"$FAKE/started"
    ob_observe
    g2="$(ob_reason proxy)"
    assert_ne "$g1" "$g2" "$plat: a restarted proxy has a new generation"
    ob_observe
    assert_eq "$g2" "$(ob_reason proxy)" "$plat: and it is stable while the proxy runs"
    rm -f "$FAKE/started"
  done
}

# Tier-1 review (Suggestion): a healthy proxy record must carry a well-formed
# generation, checked at the same boundary as the other structural rules.
t_validator_checks_the_proxy_generation() {
  local base out
  base="$(printf 'schema\tnice-dns-observations/1\n'; for n in runtime dns-owner local-service filtering local-cache route:a; do printf 'obs\t%s\thealthy\t1\tfine\n' "$n"; done)"
  printf '%s\nobs\tproxy\thealthy\t1\tgeneration:0123456789abcdef\n' "$base" | bash -c '. "$1" && nd_health_validate' _ "$OB_HEALTH" 2>/dev/null
  assert_rc 0 "$?" "a well-formed generation"
  out="$(printf '%s\nobs\tproxy\thealthy\t1\tgeneration:xyz\n' "$base" | bash -c '. "$1" && nd_health_validate' _ "$OB_HEALTH" 2>&1)"
  assert_nonzero "$?" "a malformed generation is refused"
  assert_match 'generation' "$out" "and named"
  printf '%s\nobs\tproxy\tindeterminate\t9\tdeadline: inspect\n' "$base" | bash -c '. "$1" && nd_health_validate' _ "$OB_HEALTH" 2>/dev/null
  assert_rc 0 "$?" "an indeterminate proxy record needs no generation"
}

# Without a hashing tool the proxy record is indeterminate, never a healthy
# record with an empty generation (controller-interaction's reduced PATH).
t_proxy_generation_without_a_hash_tool_is_indeterminate() {
  local plat t
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    for t in sha256sum shasum; do rm -f "$OB_BIN/$t"; done
    ob_observe
    ob_expect proxy indeterminate '^unknown: no sha256sum or shasum' "$plat: no hash tool"
  done
}

# ─────────────────────────── container states (restart policy) ──────────────
#
# container:pi-hole, container:unbound and container:<proxy> follow runtime:
# each container's own state, with its restart count as the reason's last
# words ("restarts N"), which the restart policy reads. Linux reads podman
# inspect ($FAKE/state_<name> is its output); macOS reads the STATE column of
# `container ls -a` and counts restarts in the controller's restarts.tsv.

# ob_restarts <name> <count>...: macOS restart counter rows.
ob_restarts() {
  export ND_STATE_DIR="$CASE_DIR/state"
  mkdir -p "$ND_STATE_DIR"; : >"$ND_STATE_DIR/restarts.tsv"
  while [ $# -ge 2 ]; do printf '%s\t%s\n' "$1" "$2" >>"$ND_STATE_DIR/restarts.tsv"; shift 2; done
}

t_container_running_records_follow_runtime_for_each_proxy_variant() {
  local plat v names
  ob_setup linux
  ob_restarts
  for plat in $(ob_platforms); do
    for v in haproxy socat; do
      ob_platform "$plat"
      printf 'pi-hole\nunbound\ntor-%s\n' "$v" >"$FAKE/running"
      ob_observe
      assert_rc 0 "$OB_RC" "$plat/$v: observe runs: $OB_ERR"
      ob_expect container:pi-hole healthy '^running: .*restarts 0$' "$plat/$v: container:pi-hole runs"
      ob_expect container:unbound healthy '^running: .*restarts 0$' "$plat/$v: container:unbound runs"
      ob_expect "container:tor-$v" healthy '^running: .*restarts 0$' "$plat/$v: container:tor-$v runs"
      names="$(printf '%s\n' "$OB_OUT" | awk -F '\t' '$1 == "obs" { print $2 }' | head -n 4 | tr '\n' ' ')"
      assert_eq "runtime container:pi-hole container:unbound container:tor-$v " "$names" "$plat/$v: the container records follow runtime"
      printf '%s\n' "$OB_OUT" | bash -c '. "$1" && nd_health_validate' _ "$OB_HEALTH" || fail "$plat/$v: the set with container records is valid: $OB_OUT"
    done
  done
  # Linux: the count is the unit's NRestarts. Quadlet runs each container
  # with --replace --rm, so every systemd restart is a new container and
  # podman's own RestartCount stays 0 (mint, 2026-11-05); it is ignored.
  ob_platform linux
  printf 'running healthy 9 0\n' >"$FAKE/state_pi-hole"
  printf 3 >"$FAKE/nrestarts_pi-hole.service"
  printf 'running starting 0 0\n' >"$FAKE/state_unbound"
  printf 1 >"$FAKE/nrestarts_unbound.service"
  ob_observe
  ob_expect container:pi-hole healthy '^running: health healthy restarts 3$' "linux: the unit's restart count is the reason's last words, not podman's"
  ob_expect container:unbound healthy '^running: health starting restarts 1$' "linux: a starting health check is running"
  assert_match 'systemctl --user show -p NRestarts --value pi-hole.service' "$(cat "$FAKE_LOG")" "linux: the count is read from the container's unit"
}

t_container_podman_unhealthy_carries_the_last_check_output() {
  ob_setup linux
  printf 2 >"$FAKE/nrestarts_unbound.service"
  printf 'running unhealthy 0 0\n@@nd-health-log@@ an older failure\n\n@@nd-health-log@@ dig: couldn'"'"'t get address\tfor\n  127.0.0.1#5335\n\n' >"$FAKE/state_unbound"
  ob_observe
  ob_expect container:unbound unhealthy "^unhealthy: dig: couldn't get address for 127\\.0\\.0\\.1#5335 restarts 2\$" "linux: the last check's output, on one line"
  assert_not_match 'older failure' "$(ob_reason container:unbound)" "linux: only the last check's output"
  printf 'running unhealthy 0 0\n' >"$FAKE/state_unbound"; printf 5 >"$FAKE/nrestarts_unbound.service"
  ob_observe
  ob_expect container:unbound unhealthy '^unhealthy: .*restarts 5$' "linux: unhealthy without a check log"
  printf 'running unhealthy 0 0\n@@nd-health-log@@ %0300d\n' 7 >"$FAKE/state_unbound"; printf 0 >"$FAKE/nrestarts_unbound.service"
  ob_observe
  ob_expect container:unbound unhealthy '^unhealthy: 0+ restarts 0$' "linux: a long check output never cuts the restart count off"
}

t_container_paused_is_unhealthy() {
  ob_setup linux
  printf 'paused healthy 0 0\n' >"$FAKE/state_tor-haproxy"; printf 1 >"$FAKE/nrestarts_tor-haproxy.service"
  ob_observe
  ob_expect container:tor-haproxy unhealthy '^paused restarts 1$' "linux: a paused proxy"
}

t_container_exited_reports_its_exit_code_and_restarts() {
  local plat
  ob_setup linux
  printf 'exited none 0 134\n' >"$FAKE/state_pi-hole"; printf 4 >"$FAKE/nrestarts_pi-hole.service"
  ob_observe
  ob_expect container:pi-hole unhealthy '^exited: rc 134 restarts 4$' "linux: an aborted Pi-hole"
  printf 'stopped healthy 0 1\n' >"$FAKE/state_pi-hole"; printf 0 >"$FAKE/nrestarts_pi-hole.service"
  ob_observe
  ob_expect container:pi-hole unhealthy '^exited: rc 1 restarts 0$' "linux: a stopped container is exited"
  for st in created initialized configured stopping removing; do
    printf '%s none 0 0\n' "$st" >"$FAKE/state_pi-hole"
    ob_observe
    ob_expect container:pi-hole indeterminate "^transient: state $st restarts 0\$" "linux: $st is on the way up or down, not exited"
  done
  for plat in $(ob_platforms); do
    [ "$plat" = macos ] || continue
    ob_platform macos
    ob_restarts unbound 2 pi-hole 7
    printf 'pi-hole\ntor-haproxy\n' >"$FAKE/running"; printf 'unbound\n' >"$FAKE/stopped"
    ob_observe
    ob_expect container:unbound unhealthy '^exited: rc \? restarts 2$' "macos: a stopped Unbound; Apple container has no exit code"
    ob_expect container:pi-hole healthy '^running: health none restarts 7$' "macos: the count comes from restarts.tsv"
  done
}

t_container_inspect_failure_is_indeterminate() {
  local plat cli
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    if [ "$plat" = linux ]; then
      : >"$FAKE/state_unbound.fail"
      ob_observe
      ob_expect container:unbound indeterminate '^unknown: the state of unbound is not readable .*no such object.* restarts [?]$' "linux: inspect failed, with the runtime's error"
      ob_expect container:pi-hole healthy '' "linux: the other containers still report"
      printf 'garbage line\n' >"$FAKE/state_pi-hole"
      ob_observe
      ob_expect container:pi-hole indeterminate '^unknown: .*pi-hole.* restarts [?]$' "linux: unparseable inspect output"
      rm -f "$FAKE/state_pi-hole" "$FAKE/state_unbound.fail"
      : >"$FAKE/nrestarts.fail"
      ob_observe
      ob_expect container:pi-hole indeterminate '^unknown: the restart count of pi-hole is not readable .*Failed to connect to bus.* restarts [?]$' "linux: no restart count, with the manager's error"
      rm -f "$FAKE/nrestarts.fail"
    else
      printf 'pi-hole\ntor-haproxy\n' >"$FAKE/running"
      ob_observe
      ob_expect container:unbound indeterminate '^unknown: the state of unbound is not readable .* restarts [?]$' "macos: no row for the container"
    fi
    ob_platform "$plat"
    if [ "$plat" = macos ]; then cli=container; else cli=podman; fi
    : >"$FAKE/rt.down"
    ob_observe
    ob_expect container:pi-hole indeterminate '^runtime' "$plat: no runtime, no container state"
    ob_expect container:unbound indeterminate '^runtime' "$plat: no runtime, no container state"
    rm -f "$FAKE/rt.down"
    printf '%s\n' "$OB_OUT" | bash -c '. "$1" && nd_health_validate' _ "$OB_HEALTH" || fail "$plat: indeterminate container records validate: $OB_OUT"
    assert_match "^$cli " "$(cat "$FAKE_LOG")" "$plat: the runtime CLI was asked"
  done
}

t_container_macos_health_is_none() {
  ob_setup macos
  ob_restarts tor-haproxy 3 unbound x
  ob_observe
  ob_expect container:tor-haproxy healthy '^running: health none restarts 3$' "macos: no health check, restarts from restarts.tsv"
  ob_expect container:unbound healthy '^running: health none restarts 0$' "macos: a malformed count is 0"
  ob_expect container:pi-hole healthy '^running: health none restarts 0$' "macos: no row is 0"
  rm -f "$ND_STATE_DIR/restarts.tsv"
  ob_observe
  ob_expect container:tor-haproxy healthy '^running: health none restarts 0$' "macos: no counter file is 0"
  assert_not_match '^container inspect' "$(cat "$FAKE_LOG")" "macos: never container inspect (its JSON holds the BRIDGE environment)"
}

t_container_state_deadline_keeps_the_pass_inside_its_budget() {
  local plat t0 el
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    : >"$FAKE/state.hang"
    t0=$SECONDS
    ND_HEALTH_CMD_DEADLINE=2 ob_observe 8
    el=$((SECONDS - t0))
    ob_expect container:pi-hole indeterminate '^deadline' "$plat: a hung state read is indeterminate"
    ob_expect container:tor-haproxy indeterminate '^deadline' "$plat: every container's read is bounded"
    assert_eq 1 "$((el <= 12))" "$plat: the pass ends near its 8 s budget (took $el s)"
    rm -f "$FAKE/state.hang"
    ob_no_proc "sleep $(cat "$FAKE/hang_secs")"
  done
}

t_validator_container_records_are_optional_and_carry_restarts() {
  local base out
  ob_setup linux
  base="$(printf 'schema\tnice-dns-observations/1\n'; for n in runtime dns-owner local-service filtering local-cache route:a; do printf 'obs\t%s\thealthy\t1\tfine\n' "$n"; done)"
  printf '%s\n' "$base" | bash -c '. "$1" && nd_health_validate' _ "$OB_HEALTH" 2>/dev/null
  assert_rc 0 "$?" "a set without container records is valid"
  printf '%s\nobs\tcontainer:pi-hole\thealthy\t1\trunning: health none restarts 0\nobs\tcontainer:unbound\tunhealthy\t1\texited: rc ? restarts 2\nobs\tcontainer:tor-socat\tindeterminate\t1\tdeadline: no answer restarts ?\n' "$base" \
    | bash -c '. "$1" && nd_health_validate' _ "$OB_HEALTH" 2>/dev/null
  assert_rc 0 "$?" "well-formed container records"
  out="$(printf '%s\nobs\tcontainer:pi-hole\thealthy\t1\trunning: health none\n' "$base" | bash -c '. "$1" && nd_health_validate' _ "$OB_HEALTH" 2>&1)"
  assert_nonzero "$?" "a container record without its restart count is refused"
  assert_match 'restarts' "$out" "and named"
  printf '%s\nobs\tcontainer:tor-haproxy\thealthy\t1\trunning: health none restarts 0\n' "$base" | bash -c '. "$1" && nd_health_validate' _ "$OB_HEALTH" 2>/dev/null
  assert_rc 0 "$?" "container:tor-haproxy is a known name"
}

# ─────────────────────────── install drift (BL-045) ──────────────────────────
#
# install-drift (Linux; files only): unhealthy "install-security-drift" when
# no install generation is recorded (an install from before generations) or
# an installed quadlet publishes host port 53 off loopback (an install from
# before 57db2a3 published 0.0.0.0:53, an open resolver for the LAN).

t_a_wildcard_53_publish_is_security_drift() {
  local pub q
  ob_setup linux
  ob_install_state
  ob_observe
  ob_expect install-drift healthy "generation $OB_GEN; the quadlets declare :53 on loopback only"
  printf '%s\n' "$OB_OUT" | bash -c '. "$1" && nd_health_validate' _ "$OB_HEALTH" || fail "valid with install-drift: $OB_OUT"
  for pub in 53:53/udp 0.0.0.0:53:53/tcp 192.168.1.5:53:53 '[::]:53:53/udp' 50-60:50-60/udp '[::'; do
    ob_install_state 127.0.0.1:53:53/tcp "$pub"
    ob_observe
    ob_expect install-drift unhealthy 'install-security-drift: the quadlets declare :53 on' "$pub is security drift"
  done
  for pub in '[::1]:53:53/udp' 'localhost:53:53' 127.0.0.53:53:53 0.0.0.0:8880:80 53/udp 127.0.0.1:50-60:50-60 1000-2000:1000-2000; do
    ob_install_state 127.0.0.1:53:53/tcp "$pub"
    ob_observe
    ob_expect install-drift healthy "" "$pub is not security drift"
  done
  # The other ways a unit declares a publish, and its drop-ins.
  q="$XDG_CONFIG_HOME/containers/systemd"
  ob_install_state
  printf '[Container]\nPodmanArgs=--cap-add=NET_ADMIN --publish 0.0.0.0:53:53/udp\n' >"$q/pi-hole.container"
  ob_observe
  ob_expect install-drift unhealthy 'pi-hole.container PodmanArgs|0\.0\.0\.0 \(pi-hole.container' "PodmanArgs --publish"
  ob_install_state
  printf '[Container]\nPodmanArgs=-p53:53\n' >"$q/unbound.container"
  ob_observe
  ob_expect install-drift unhealthy 'every address \(unbound.container' "PodmanArgs -p"
  ob_install_state
  printf '[Container]\nNetwork=host\n' >"$q/pi-hole.container"
  ob_observe
  ob_expect install-drift unhealthy 'the host network' "Network=host"
  ob_install_state
  mkdir -p "$q/nice-dns.pod.d"; printf '[Pod]\nPublishPort=53:53/udp\n' >"$q/nice-dns.pod.d/90-local.conf"
  ob_observe
  ob_expect install-drift unhealthy 'nice-dns.pod.d/90-local.conf' "a drop-in's publish"
  rm -rf "$q/nice-dns.pod.d"
  # Another product's quadlet is not nice-dns's.
  ob_install_state
  printf '[Container]\nPublishPort=53:53/udp\n' >"$q/other-dns.container"
  ob_observe
  ob_expect install-drift healthy "" "another product's quadlet is not read"
}

t_a_missing_generation_is_security_drift() {
  ob_setup linux
  ob_install_state
  rm -f "$XDG_STATE_HOME/nice-dns-install/current"
  ob_observe
  ob_expect install-drift unhealthy 'install-security-drift: no install generation is recorded'
  printf 'not-a-generation\n' >"$XDG_STATE_HOME/nice-dns-install/current"
  ob_observe
  ob_expect install-drift unhealthy 'install-security-drift: no install generation is recorded' "a malformed current is not a generation"
  ob_install_state
  rm -f "$XDG_STATE_HOME/nice-dns-install/generations/$OB_GEN/prepare.tsv"
  ob_observe
  ob_expect install-drift unhealthy 'install-security-drift: no install generation is recorded' "a generation without its manifest"
  # An install under way (its generation neither activated nor rolled back)
  # is not drift: the controller runs before the install makes it current.
  ob_install_state
  rm -f "$XDG_STATE_HOME/nice-dns-install/current" "$XDG_STATE_HOME/nice-dns-install/generations/$OB_GEN/activated"
  ob_observe
  ob_expect install-drift indeterminate "install under way: generation $OB_GEN" "an install under way"
  printf 'status\trolled-back\n' >>"$XDG_STATE_HOME/nice-dns-install/generations/$OB_GEN/prepare.tsv"
  ob_observe
  ob_expect install-drift unhealthy 'no install generation is recorded' "a rolled-back first install"
  ob_install_state
  rm -f "$XDG_STATE_HOME/nice-dns-install/current"
  ob_observe
  ob_expect install-drift unhealthy 'no install generation is recorded' "an activated generation that is no longer current (uninstalled)"
  # No nice-dns.pod: nothing to judge.
  ob_install_state
  rm -f "$XDG_CONFIG_HOME/containers/systemd/nice-dns.pod"
  ob_observe
  ob_expect install-drift indeterminate "no nice-dns.pod" "no quadlet to read"
  # macOS has no install-drift observation; the set is still valid.
  ob_platform macos
  ob_observe
  assert_eq "" "$(ob_verdict install-drift)" "no install-drift record on macOS"
  printf '%s\n' "$OB_OUT" | bash -c '. "$1" && nd_health_validate' _ "$OB_HEALTH" || fail "macOS set valid without install-drift"
}

# ob_unbound_reset: a working Unbound.
ob_unbound_reset() { rm -f "$FAKE/unbound_control" "$FAKE/exec_hang" "$FAKE/unbound_probe_rc" "$FAKE/unbound_probe_hang"; }

t_unbound_is_observed_on_its_own_evidence() {
  local plat
  ob_setup linux
  export ND_HEALTH_CMD_DEADLINE=1
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    ob_observe
    ob_expect unbound healthy 'control and route answer' "$plat: a working Unbound"
    printf '%s\n' "$OB_OUT" | bash -c '. "$1" && nd_health_validate' _ "$OB_HEALTH" || fail "$plat: the set with an unbound record is valid"

    ob_unbound_reset; echo refused >"$FAKE/unbound_control"
    ob_observe
    ob_expect unbound unhealthy '^control: .*Connection refused' "$plat: a refused control socket is Unbound's own failure"

    ob_unbound_reset; echo 1 >"$FAKE/unbound_probe_rc"
    ob_observe
    ob_expect unbound unhealthy '^route: ' "$plat: a failed route probe"

    # A frozen daemon (live, mint 2026-10-30, SIGSTOP): control hangs, exec answers.
    ob_unbound_reset; echo hang >"$FAKE/unbound_control"
    ob_observe
    ob_expect unbound unhealthy '^control: .*no answer' "$plat: control hangs while the container still execs"

    ob_unbound_reset; echo hang >"$FAKE/unbound_control"; : >"$FAKE/exec_hang"
    ob_observe
    ob_expect unbound indeterminate 'deadline' "$plat: a timeout with no working exec is no evidence"

    ob_unbound_reset; echo missing >"$FAKE/unbound_control"
    ob_observe
    ob_expect unbound indeterminate 'no unbound-control' "$plat: an image without the control client (exit 127)"

    ob_unbound_reset; echo missing >"$FAKE/unbound_probe_rc"
    ob_observe
    ob_expect unbound indeterminate 'probe-route cannot run' "$plat: an image without the probe (exit 127)"

    ob_unbound_reset; echo 126 >"$FAKE/unbound_probe_rc"
    ob_observe
    ob_expect unbound indeterminate 'probe-route cannot run' "$plat: exit 126 is the same"

    ob_unbound_reset; : >"$FAKE/unbound_probe_hang"
    ND_HEALTH_UNBOUND_PROBE_DEADLINE=1 ob_observe
    ob_expect unbound indeterminate 'deadline' "$plat: a route probe past its deadline"

    ob_unbound_reset; printf 'pi-hole\ntor-haproxy\n' >"$FAKE/running"
    ob_observe
    ob_expect unbound indeterminate 'not running' "$plat: a missing container is the runtime observation's fault"
    printf 'pi-hole\nunbound\ntor-haproxy\n' >"$FAKE/running"
    ob_unbound_reset
  done
}

t_unbound_observation_stays_inside_the_budget() {
  local plat t0
  ob_setup linux
  export ND_HEALTH_CMD_DEADLINE=1 ND_HEALTH_UNBOUND_PROBE_DEADLINE=30
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    echo hang >"$FAKE/unbound_control"; : >"$FAKE/unbound_probe_hang"; : >"$FAKE/exec_hang"
    t0=$SECONDS
    ob_observe 4
    assert_eq 0 "$(( SECONDS - t0 > 10 ))" "$plat: the pass ends near its budget, took $(( SECONDS - t0 )) s"
    ob_expect unbound indeterminate '' "$plat: a spent budget acts on nothing"
    ob_unbound_reset
  done
}

t_tick_writes_one_failure_dump_per_outage() {
  local plat now g
  ob_setup linux
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    ob_tree
    rm -rf "$XDG_STATE_HOME/nice-dns-health" "$HOME/Library/Logs/nice-dns-health" "$XDG_STATE_HOME/nice-dns/controller" "$HOME/Library/Application Support/nice-dns/controller"
    for g in 18531 18532 18533 853; do printf 'servfail\n' >"$FAKE/probe/$g"; done
    now="$(date +%s)"
    export ND_STATE_DIR="$CASE_DIR/ctl-$plat"
    mkdir -p "$ND_STATE_DIR"; chmod 700 "$ND_STATE_DIR"
    # Past the cap and the cooldown, not yet at the retry: every pass escalates.
    printf 'schema\tnice-dns-controller-state/1\ngeneration\t1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\t-\noutage_since\t%s\noutage_restarts\t2\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t%s\n' \
      "$((now - 60))" "$((now - 7200))" "$((now - 3600))" "$((now - 600))" >"$ND_STATE_DIR/state.tsv"
    chmod 600 "$ND_STATE_DIR/state.tsv"
    ND_BOOT_ID=boot-a bash "$OB_TREE/health/nice-dns-health" tick >"$CASE_DIR/tick1" 2>&1
    assert_match '^action	escalate$' "$(cat "$CASE_DIR/tick1")" "$plat: the pass escalates"
    ND_BOOT_ID=boot-a bash "$OB_TREE/health/nice-dns-health" tick >"$CASE_DIR/tick2" 2>&1
    assert_match '^action	escalate$' "$(cat "$CASE_DIR/tick2")" "$plat: and so does the next"
    assert_eq 1 "$(find "$HOME" -name 'failure-*.log' | wc -l | tr -d ' ')" "$plat: one dump for the outage"
    assert_match 'route:cloudflare-exit' "$(cat "$(find "$HOME" -name 'failure-*.log' | head -n 1)")" "$plat: it holds the observations"
    find "$HOME" -name 'failure-*.log' -exec rm -f {} +
    unset ND_STATE_DIR
    rm -f "$FAKE/probe/"*
  done
}

t_a_runtime_exec_failure_is_never_unbounds_fault() {
  local plat
  ob_setup linux
  export ND_HEALTH_CMD_DEADLINE=1
  for plat in $(ob_platforms); do
    ob_platform "$plat"
    # A warning before the error, as podman prints with its bus refused.
    echo exec-error >"$FAKE/unbound_control"
    ob_observe
    ob_expect unbound indeterminate 'could not exec' "$plat: exit 125 with a warning first is the runtime's failure"
    ob_unbound_reset
    echo exec-error >"$FAKE/unbound_probe_rc"
    ob_observe
    ob_expect unbound indeterminate 'could not exec' "$plat: the same from the route probe"
    ob_unbound_reset
  done
}

t_the_first_escalation_dump_is_bounded() {
  local g now t0
  ob_setup linux
  ob_tree
  for g in 18531 18532 18533 853; do printf 'servfail\n' >"$FAKE/probe/$g"; done
  now="$(date +%s)"
  export ND_STATE_DIR="$CASE_DIR/ctl" ND_FAILURE_DUMP_S=2
  mkdir -p "$ND_STATE_DIR"; chmod 700 "$ND_STATE_DIR"
  printf 'schema\tnice-dns-controller-state/1\ngeneration\t1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\t-\noutage_since\t%s\noutage_restarts\t2\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t%s\n' \
    "$((now - 60))" "$((now - 7200))" "$((now - 3600))" "$((now - 600))" >"$ND_STATE_DIR/state.tsv"
  chmod 600 "$ND_STATE_DIR/state.tsv"
  # The dump's own `logs` hangs, as on a wedged runtime; the observations do not use it.
  printf '%s\n' 1 >"$FAKE/logs.hang"
  t0=$SECONDS
  ND_BOOT_ID=boot-a bash "$OB_TREE/health/nice-dns-health" tick >"$CASE_DIR/out" 2>&1
  assert_match '^action	escalate$' "$(cat "$CASE_DIR/out")" "the pass escalates"
  assert_eq 1 "$(( SECONDS - t0 <= 25 ))" "a hung dump does not hold the pass: $(( SECONDS - t0 )) s"
  unset ND_STATE_DIR ND_FAILURE_DUMP_S
}

# BL-053: podman ps leaves a paused container out, so a paused Unbound read as
# containers-missing and the repair started a unit that already ran.
t_a_paused_container_is_listed_not_missing() {
  ob_setup linux
  printf 'unbound\n' >"$FAKE/paused"; printf 'paused healthy 0 0\n' >"$FAKE/state_unbound"
  ob_observe
  ob_expect runtime healthy '^running: pi-hole unbound tor-haproxy$' "linux: a paused Unbound is listed, not missing"
  ob_expect container:unbound unhealthy '^paused restarts 0$' "linux: its own record says paused"
}
