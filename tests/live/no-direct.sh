# shellcheck shell=bash
# Group live/no-direct (Sub-plan 5, Task 2.1; PRIV-NO-DIRECT,
# PRIV-BOOTSTRAP-DECLARED; qualification scenario QU-NO-DIRECT). Run with
#   tests/run.sh live no-direct --live --targets FILE --platforms all
#
# On each target, as installed: tcpdump on the default-route interface of
# each address family, ports 53 and 853 (target.sh capture-dns), while 20 A
# and 20 AAAA queries for fresh probe names go through the client resolver
# and the installed controller refreshes the bridge pool once. Judged here,
# from the target's rows:
#   - no packet leaves the host to port 853, and none carries a probe name;
#   - a packet to port 53 off the host goes only to bridge-eval's bootstrap
#     resolvers (../tor-socat/bridge-eval/pool.go: 1.1.1.1, 9.9.9.9,
#     8.8.8.8) and asks only for bridges.torproject.org: the declared
#     exception (release/bootstrap.tsv "bridges"), never a client query;
#   - the capture works: a deliberate direct query for a canary name
#     (ndcanary<hex>.example.com to 9.9.9.9) is seen leaving the host; it is
#     the harness's own, excluded from the judgement;
#   - the probes were answered through the stack (36 of 40 at least), so
#     the capture saw a working resolver, not a silent one.
# A family without a default route is recorded as such (neither target has
# IPv6 egress on 2026-10-02): its AAAA queries then travel over IPv4 only.
# Evidence: $ARTIFACT_DIR/no-direct/<alias>/ (capture.tsv, verdict.tsv).

# shellcheck source=tests/live/controller-lib.sh
. "$NICE_DNS_ROOT/tests/live/controller-lib.sh"

cs_dir() { printf '%s\n' "$ARTIFACT_DIR/no-direct/$1"; }

NDX_BOOT_RESOLVERS="1.1.1.1 9.9.9.9 8.8.8.8"
NDX_BOOT_NAME=bridges.torproject.org

# ndx_violations <capture.tsv>: one line per packet that breaks the rules.
ndx_violations() {
  awk -F '\t' -v boot="$NDX_BOOT_RESOLVERS" -v name="$NDX_BOOT_NAME" '
    BEGIN { n = split(boot, b, " "); for (i = 1; i <= n; i++) ok[b[i]] = 1 }
    $1 != "packet" { next }
    $6 ~ /^ndcanary[0-9a-f]+\.example\.com$/ && $4 == "9.9.9.9" { next }
    $6 ~ /^nd[0-9a-f]+\.example\.com$/ { print "probe name off the host: " $0; next }
    $6 == "<other>" { print "an undeclared name off the host: " $0; next }
    $3 == "out" && $5 == 853 { print "DNS over TLS off the host: " $0; next }
    $3 == "out" && !($4 in ok) { print "DNS to an undeclared resolver: " $0; next }
    $3 == "out" && $6 != "-" && $6 != name { print "an undeclared bootstrap name: " $0; next }' "$1"
}

ndx_capture() {
  local plat="$1" a="$2" d c n ok boot
  d="$(cs_dir "$a")"; mkdir -p "$d"
  cs_t "$a" snapshot >"$d/snapshot.out" 2>>"$d/ops.log" || fail "$a: snapshot"
  c="$d/capture.tsv"
  cs_t "$a" capture-dns --count 20 >"$c" 2>>"$d/ops.log" || fail "$a: capture-dns failed: $(tail -n 5 "$d/ops.log")"
  assert_match '^interface	ipv4	[A-Za-z0-9]+$' "$(grep '^interface	ipv4' "$c")" "$a: an IPv4 default-route interface was captured"
  # The positive control: the capture saw the deliberate canary query leave.
  assert_ne 0 "$(awk -F '\t' -v q="$(awk -F '\t' '$1 == "canary" { print $2 }' "$c")" '$1 == "packet" && $3 == "out" && $4 == "9.9.9.9" && $6 == q' "$c" | grep -c .)" \
    "$a: the capture sees a direct query (the canary) leave the host"
  n="$(awk -F '\t' '$1 == "query"' "$c" | grep -c .)"
  assert_eq 40 "$n" "$a: 20 A and 20 AAAA probe queries"
  ok="$(awk -F '\t' '$1 == "query" && ($4 == "NOERROR" || $4 == "NXDOMAIN")' "$c" | grep -c .)"
  [ "$ok" -ge 36 ] || fail "$a: only $ok of 40 probes answered: the capture did not watch a working resolver"
  assert_eq "" "$(ndx_violations "$c")" "$a: no direct query left the host"
  boot="$(awk -F '\t' -v name="$NDX_BOOT_NAME" '$1 == "packet" && $3 == "out" && $6 == name' "$c" | grep -c .)"
  {
    printf 'target\t%s\nplatform\t%s\n' "$a" "$plat"
    grep '^interface	' "$c"
    printf 'probes_answered\t%s/40\n' "$ok"
    printf 'packets\t%s\n' "$(awk -F '\t' '$1 == "packet"' "$c" | grep -c .)"
    printf 'bootstrap_lookups\t%s\n' "$boot"
    grep '^bridges_refresh	' "$c"
    printf 'violations\t0\n'
  } >"$d/verdict.tsv"
}

t_1_capture() {
  local p
  cs_selection
  for p in $(cs_platforms); do
    cs_alias "$p"
    ( ndx_capture "$p" "$CS_ALIAS" ) || fail "the capture on $CS_ALIAS failed (see the case log)"
  done
}

t_2_evidence_is_private() {
  local hits
  [ -d "$ARTIFACT_DIR/no-direct" ] || fail "no evidence: t_1 did not run"
  hits="$(grep -rlE 'obfs4 [0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+|cert=[A-Za-z0-9+/=]{16,}' "$ARTIFACT_DIR/no-direct" 2>/dev/null)"
  assert_eq "" "$hits" "no bridge line in the evidence"
  hits="$(awk -F '\t' '$1 == "packet" && $6 != "-" && $6 != "<other>" && $6 != "bridges.torproject.org" && $6 !~ /^nd(canary)?[0-9a-f]+\.example\.com$/' \
    "$ARTIFACT_DIR"/no-direct/*/capture.tsv 2>/dev/null)"
  assert_eq "" "$hits" "no query name but probe names and the declared bootstrap name"
}
