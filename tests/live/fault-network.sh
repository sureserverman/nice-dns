# shellcheck shell=bash
# Group live/fault-network (Sub-plan 5, Task 2.1; FQ-NETWORK-LOSS;
# qualification scenario QU-NETWORK-LOSS). Run with
#   tests/run.sh live fault-network --live --targets FILE --platforms all
#
# On each target in turn, as installed, with the controller's schedules
# running (it may act; nothing here repairs anything):
#   before   a fresh name resolves through Pi-hole (route-report client_fresh)
#   loss     target.sh fault-network drops every outbound packet to a
#            non-private address for NDF_LOSS_S (120 s): Linux an nft table,
#            macOS a pf anchor; the LAN and this session stay up, and a
#            restore on the target lifts it after NICE_DNS_FREEZE_MAX_SECS
#            (600) whatever happens here. Fresh names must not resolve
#            meanwhile (fail closed), and every DNS destination the fault
#            dropped must be one of bridge-eval's declared bootstrap
#            resolvers (port 53; the controller may refresh bridges during
#            an outage): anything else is a direct query. The fault's own
#            canary (one direct query to 149.112.112.112 at its start) must
#            be recorded, so the recording is proven able to see one.
#   return   heal-network lifts the fault; a fresh name must resolve within
#            NDF_RETURN_S (420 s) with no manual repair, and the controller
#            then reports the chain up (controller-report: an answering route
#            and Pi-hole's own name).
# Evidence: $ARTIFACT_DIR/fault-network/<alias>/ (reports, verdict.tsv).

# shellcheck source=tests/live/controller-lib.sh
. "$NICE_DNS_ROOT/tests/live/controller-lib.sh"

cs_dir() { printf '%s\n' "$ARTIFACT_DIR/fault-network/$1"; }

NDF_LOSS_S="${NDF_LOSS_S:-120}"
NDF_RETURN_S="${NDF_RETURN_S:-420}"
NDF_BOOT_RESOLVERS="1.1.1.1 9.9.9.9 8.8.8.8"

# ndf_fresh <alias> <name>: route-report into <dir>/<name>.tsv; prints the
# rcode of its fresh name through Pi-hole.
ndf_fresh() {
  local f
  f="$(cs_dir "$1")/$2.tsv"
  cs_t "$1" route-report >"$f" 2>>"$(cs_dir "$1")/ops.log" || true
  awk -F '\t' '$1 == "section" { on = ($2 == "route"); next } on && $1 == "client_fresh" { print $2; exit }' "$f"
}

ndf_answered() { case "$1" in NOERROR|NXDOMAIN) return 0 ;; esac; return 1; }

ndf_cell() {
  local plat="$1" a="$2" d r t0 i bad back=""
  d="$(cs_dir "$a")"; mkdir -p "$d"
  cs_t "$a" snapshot >"$d/snapshot.out" 2>>"$d/ops.log" || fail "$a: snapshot"
  r="$(ndf_fresh "$a" before)"
  ndf_answered "$r" || fail "$a: the stack does not answer before the fault ($r)"
  trap 'cs_t "'"$a"'" heal-network >>"'"$d"'/heal-trap.tsv" 2>>"'"$d"'/ops.log"' EXIT
  NICE_DNS_FREEZE_MAX_SECS=600 cs_t "$a" fault-network >"$d/fault.tsv" 2>>"$d/ops.log" || fail "$a: fault-network: $(tail -n 3 "$d/ops.log")"
  assert_match '^fault	in-place$' "$(grep '^fault	' "$d/fault.tsv")" "$a: the fault is in place"
  t0="$(date +%s)"; i=0
  while [ $(( $(date +%s) - t0 )) -lt "$NDF_LOSS_S" ]; do
    sleep 25; i=$((i + 1))
    r="$(ndf_fresh "$a" "loss-$i")"
    ! ndf_answered "$r" || fail "$a: a fresh name resolved $(( $(date +%s) - t0 )) s into the loss: something reached a resolver around the fault"
  done
  cs_t "$a" heal-network >"$d/heal.tsv" 2>>"$d/ops.log" || fail "$a: heal-network"
  trap - EXIT
  assert_match '^fault	lifted$' "$(grep '^fault	' "$d/heal.tsv")" "$a: the fault is lifted"
  # The positive control: the canary the fault sent at its start was dropped
  # and recorded, so an empty list below means no attempt, not a blind spot.
  assert_eq 1 "$(awk -F '\t' '$1 == "dns_attempt" && $2 == "149.112.112.112" && $3 == 53' "$d/heal.tsv" | grep -c .)" \
    "$a: the fault recorded its own canary query"
  bad="$(awk -F '\t' -v boot="$NDF_BOOT_RESOLVERS" 'BEGIN { n = split(boot, b, " "); for (i = 1; i <= n; i++) ok[b[i]] = 1; ok["149.112.112.112"] = 1 }
    $1 == "dns_attempt" && !($2 in ok && $3 == 53)' "$d/heal.tsv")"
  assert_eq "" "$bad" "$a: during the loss no DNS was tried but the declared bootstrap lookups"
  t0="$(date +%s)"; i=0
  while [ $(( $(date +%s) - t0 )) -lt "$NDF_RETURN_S" ]; do
    i=$((i + 1))
    r="$(ndf_fresh "$a" "return-$i")"
    if ndf_answered "$r"; then back="$(( $(date +%s) - t0 ))"; break; fi
    sleep 15
  done
  [ -n "$back" ] || fail "$a: no fresh name resolved within $NDF_RETURN_S s after the network returned"
  cs_report "$a" after || fail "$a: controller-report"
  ca_up "$d/after.tsv" || fail "$a: the controller does not report the chain up after the return"
  {
    printf 'target\t%s\nplatform\t%s\nloss_s\t%s\nloss_checks\t%s\n' "$a" "$plat" "$NDF_LOSS_S" "$(find "$d" -name 'loss-*.tsv' | grep -c .)"
    printf 'dns_attempts\t%s\n' "$(awk -F '\t' '$1 == "dns_attempt"' "$d/heal.tsv" | grep -c .)"
    awk -F '\t' '$1 == "dns_attempt"' "$d/heal.tsv"
    printf 'first_answer_after_return_s\t%s\nmanual_repair\tnone\n' "$back"
  } >"$d/verdict.tsv"
}

t_1_network_loss() {
  local p
  cs_selection
  for p in $(cs_platforms); do
    cs_alias "$p"
    ( ndf_cell "$p" "$CS_ALIAS" ) || fail "the network loss on $CS_ALIAS failed (see the case log)"
  done
}

t_2_evidence_is_private() {
  [ -d "$ARTIFACT_DIR/fault-network" ] || fail "no evidence: t_1 did not run"
  assert_eq "" "$(grep -rlE 'obfs4 |cert=|iat-mode=' "$ARTIFACT_DIR/fault-network" 2>/dev/null)" "no bridge line in the evidence"
}
