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

# shellcheck source=tests/live/fault-lib.sh
. "$NICE_DNS_ROOT/tests/live/fault-lib.sh"

cs_dir() { printf '%s\n' "$ARTIFACT_DIR/fault-network/$1"; }

ndf_cell() {
  local plat="$1" a="$2" d r back
  d="$(cs_dir "$a")"; mkdir -p "$d"
  cs_t "$a" snapshot >"$d/snapshot.out" 2>>"$d/ops.log" || fail "$a: snapshot"
  r="$(ndf_fresh "$a" "$d/before.tsv")"
  ndf_answered "$r" || fail "$a: the stack does not answer before the fault ($r)"
  back="$(ndf_loss "$a" "$d")" || fail "$a: the network loss failed"
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
