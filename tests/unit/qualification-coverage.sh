# shellcheck shell=bash
# Group unit/qualification-coverage (sub-plan 05, Task 2.1; ARCH-09).
#
# Every mandatory fault and lifecycle scenario (tests/manifests/faults.tsv)
# carries the proof kinds it needs in scenarios.tsv (check-scenarios), with
# nothing left deferred, and its live evidence has a scenario in a receipt
# the qualification receipt requires. The negative cases remove one proof or
# one receipt scenario and require the validators to fail and name it.
#
# Helpers use the qc_ prefix so the runner does not collect them as cases.

QC_MAN="$NICE_DNS_ROOT/tests/manifests"

# qc_run <args...>: the runner with nested artifacts under $CASE_DIR; QC_M,
# when set, selects a manifest directory. Sets QC_RC and QC_OUT.
qc_run() {
  (
    if [ -n "${QC_M:-}" ]; then NICE_DNS_TEST_MANIFESTS="$QC_M"; export NICE_DNS_TEST_MANIFESTS
    else unset NICE_DNS_TEST_MANIFESTS
    fi
    NICE_DNS_TEST_ARTIFACTS="$CASE_DIR/nested"; export NICE_DNS_TEST_ARTIFACTS
    bash "$NICE_DNS_ROOT/tests/run.sh" "$@"
  ) >"$CASE_DIR/qc-run.out" 2>&1
  QC_RC=$?
  QC_OUT="$(cat "$CASE_DIR/qc-run.out")"
}

# qc_copy <dir>: every real manifest, with the group registry's files made
# absolute so the copy resolves the same cases.
qc_copy() {
  mkdir -p "$1"
  cp "$QC_MAN"/*.tsv "$1/"
  awk -F '\t' -v r="$NICE_DNS_ROOT" 'BEGIN { OFS = "\t" } /^#/ || NF != 4 { print; next } { if ($3 !~ /^\//) $3 = r "/" $3; print }' \
    "$QC_MAN/groups.tsv" >"$1/groups.tsv"
}

qc_faults() { awk -F '\t' '!/^#/ && NF >= 4 { print $1 }' "$QC_MAN/faults.tsv"; }
qc_field() { awk -F '\t' -v f="$1" -v c="$2" '!/^#/ && $1 == f { print $c }' "$QC_MAN/faults.tsv"; }

# qc_rv <args...>: runs in a subshell with the receipt-verifier helpers
# (rv_build, rv, rv_edit) loaded, so their cases are never collected here.
qc_rv() (
  # shellcheck source=tests/unit/receipt-verifier-tests.sh
  . "$NICE_DNS_ROOT/tests/unit/receipt-verifier-tests.sh"
  "$@"
)

t_every_fault_carries_its_needed_proofs() {
  local f n=0
  qc_run check-scenarios
  assert_rc 0 "$QC_RC" "the committed scenarios pass: $QC_OUT"
  for f in $(qc_faults); do
    n=$((n + 1))
    assert_match "^fault $f needs=$(qc_field "$f" 2 | sed 's/+/[+]/') fixture=[0-9]+ live=[0-9]+ deferred=0\$" \
      "$(printf '%s\n' "$QC_OUT" | grep "^fault $f ")" "$f: its proofs are all active"
  done
  assert_eq 13 "$n" "thirteen mandatory faults (faults.tsv)"
  assert_eq "" "$(printf '%s\n' "$QC_OUT" | grep '^  deferred fault:')" "no fault is left to a later owner"
}

t_no_direct_is_proven_on_a_real_target() {
  local row
  row="$(awk -F '\t' '$1 == "OP-NO-DIRECT"' "$QC_MAN/scenarios.tsv")"
  assert_match '^OP-NO-DIRECT	PRIV-NO-DIRECT	live	[a-z-]+	t_[a-z0-9_]+	qualification$' "$row" \
    "PRIV-NO-DIRECT has its live proof, no longer deferred"
}

t_live_evidence_lands_in_a_required_receipt() {
  local f needs rc r sc
  for f in $(qc_faults); do
    needs="$(qc_field "$f" 2)" rc="$(qc_field "$f" 3)"
    case "$needs" in
      *live*)
        r="${rc%%:*}" sc="${rc#*:}"
        assert_match '^[a-z]+:[A-Z][A-Z0-9-]+$' "$rc" "$f names receipt:scenario"
        assert_file "$QC_MAN/$r.tsv" "$f: receipt manifest $r"
        assert_eq 1 "$(awk -F '\t' -v s="$sc" '$1 == "scenario" && $2 == s' "$QC_MAN/$r.tsv" | grep -c .)" \
          "$f: $r.tsv declares $sc"
        if [ "$r" != qualification ]; then
          assert_eq 1 "$(awk -F '\t' -v r="$r" '$1 == "requires" && $2 == r' "$QC_MAN/qualification.tsv" | grep -c .)" \
            "$f: the qualification receipt requires $r"
        fi ;;
      *) assert_eq - "$rc" "$f has no live evidence to place" ;;
    esac
  done
}

t_a_removed_fault_fails_the_scenario_check() {
  local m="$CASE_DIR/m" f
  for f in FQ-STATE-CORRUPT FQ-NETWORK-LOSS; do
    rm -rf "$m"; qc_copy "$m"
    awk -F '\t' -v c="fault:$f" '$2 != c' "$QC_MAN/scenarios.tsv" >"$m/scenarios.tsv"
    QC_M="$m" qc_run check-scenarios
    assert_nonzero "$QC_RC" "scenarios without $f"
    assert_match "fault $f has no scenario row" "$QC_OUT" "names $f"
  done
}

t_a_fixture_cannot_stand_in_for_a_live_proof() {
  local m="$CASE_DIR/m"
  qc_copy "$m"
  awk -F '\t' '!($2 == "fault:FQ-WAKE" && $3 == "live")' "$QC_MAN/scenarios.tsv" >"$m/scenarios.tsv"
  assert_ne 0 "$(awk -F '\t' '$2 == "fault:FQ-WAKE" && $3 != "live"' "$m/scenarios.tsv" | grep -c .)" "its fixture rows stay"
  QC_M="$m" qc_run check-scenarios
  assert_nonzero "$QC_RC" "FQ-WAKE with fixture proofs only"
  assert_match 'fault FQ-WAKE needs a live proof' "$QC_OUT" "names the missing kind"
  qc_copy "$m"
  awk -F '\t' '!($2 == "fault:FQ-STATE-CORRUPT" && $3 != "live")' "$QC_MAN/scenarios.tsv" >"$m/scenarios.tsv"
  printf 'QC-STATE-LIVE\tfault:FQ-STATE-CORRUPT\tlive\tcontroller-wake\tt_1_wake\tqualification\n' >>"$m/scenarios.tsv"
  QC_M="$m" qc_run check-scenarios
  assert_nonzero "$QC_RC" "a live case cannot stand in for a fixture either"
  assert_match 'fault FQ-STATE-CORRUPT needs a fixture proof' "$QC_OUT" "names the missing kind"
}

t_an_unknown_fault_or_need_is_refused() {
  local m="$CASE_DIR/m"
  qc_copy "$m"
  printf 'QC-NOPE\tfault:FQ-NOPE\tunit\tstate-policy\tt_state_dir_must_be_private_and_real\tqualification\n' >>"$m/scenarios.tsv"
  QC_M="$m" qc_run check-scenarios
  assert_nonzero "$QC_RC" "a row for an undeclared fault"
  assert_match "unknown fault 'FQ-NOPE'" "$QC_OUT" "names it"
  qc_copy "$m"
  printf 'FQ-ODD\tsometimes\t-\ta need that is no proof kind\n' >>"$m/faults.tsv"
  QC_M="$m" qc_run check-scenarios
  assert_nonzero "$QC_RC" "a fault whose need is not a proof kind"
  assert_match "faults.tsv: FQ-ODD needs 'sometimes'" "$QC_OUT" "names it"
}

t_a_qualification_receipt_missing_a_scenario_fails() {
  local sc n=0
  qc_rv rv_build qualification "$CASE_DIR/q" || fail "cannot build a qualification receipt"
  QC_RV_OUT="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$CASE_DIR/q/receipt.tsv" --require-matrix all 2>&1)"
  assert_rc 0 $? "a complete qualification receipt verifies: $QC_RV_OUT"
  for sc in $(awk -F '\t' '$1 == "scenario" { print $2 }' "$QC_MAN/qualification.tsv"); do
    n=$((n + 1))
    rm -rf "$CASE_DIR/q"
    qc_rv rv_build qualification "$CASE_DIR/q" || fail "cannot build a qualification receipt"
    awk -F '\t' -v OFS='\t' -v s="$sc" '$1 == "scenario" && $2 == s && !done { done = 1; next } { print }' \
      "$CASE_DIR/q/receipt.tsv" >"$CASE_DIR/q/r.new" && mv "$CASE_DIR/q/r.new" "$CASE_DIR/q/receipt.tsv"
    QC_RV_OUT="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$CASE_DIR/q/receipt.tsv" --require-matrix all 2>&1)"
    assert_nonzero $? "a qualification receipt without one $sc row"
    assert_match "$sc" "$QC_RV_OUT" "the failure names $sc"
  done
  assert_eq 4 "$n" "every qualification scenario exercised"
}
