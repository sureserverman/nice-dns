# shellcheck shell=bash
# Group unit/soak-verdict (sub-plan 05 Task 2.2; ARCH-09).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR). The
# soak's stability rule (tests/reports/soak-verdict.py; user decisions
# 2026-10-04): steady timeouts and failures each at most 1 in 100, p95
# recorded and never gated, under 30 steady samples not judged.

SV="$NICE_DNS_ROOT/tests/reports/soak-verdict.py"

# sv_row <workload> <timeouts k/n> <failures k/n> [p95_us]: a check.tsv
# workload row in perf-acceptance's shape.
sv_row() {
  printf 'workload\tmacos/socat/standard\t%s\tfail\tclass=miss\tsource=frozen\tn_cand=%s\tbudget=30\ttimeouts_cand=%s\ttimeout_ci95_cand=0-1\tfailures_cand=%s\tfailure_ci95_cand=0-1\tnx_cand=0/1\tp50_cand=400000\tp95_cand=%s\ttimeout_limit=0/30\ttimeout=fail\n' \
    "$1" "${2#*/}" "$2" "$3" "${4:-2396000}"
}

sv_run() { python3 "$SV" "$CASE_DIR/check.tsv"; }
sv_get() { printf '%s\n' "$2" | awk -F '\t' -v w="$1" '$1 == "workload" && $2 == w { print $3; exit }'; }

t_one_percent_is_the_boundary() {
  local out
  { printf '# schema\tx\n'; sv_row cold 8/864 8/864; sv_row warm 0/1440 0/1440 4100; } >"$CASE_DIR/check.tsv"
  out="$(sv_run)"; assert_rc 0 $? "judged: $out"
  assert_eq pass "$(sv_get cold "$out")" "8/864 is within 1 in 100"
  assert_eq pass "$(sv_get warm "$out")" "0/1440 passes"
  sv_row cold 9/864 9/864 >"$CASE_DIR/check.tsv"
  out="$(sv_run)"
  assert_eq fail "$(sv_get cold "$out")" "9/864 is over 1 in 100"
  assert_match 'timeouts 9/864 over 1/100' "$out" "and says why"
  sv_row cold 1/100 1/100 >"$CASE_DIR/check.tsv"
  assert_eq pass "$(sv_get cold "$(sv_run)")" "exactly 1/100 passes"
  sv_row cold 2/100 2/100 >"$CASE_DIR/check.tsv"
  assert_eq fail "$(sv_get cold "$(sv_run)")" "2/100 fails"
}

t_the_failed_mac_soak_still_fails() {
  # Run 20261002T205552Z-cbc82d85, the mac cell: 39/864 cold timeouts.
  sv_row cold 39/864 39/864 3420000 >"$CASE_DIR/check.tsv"
  assert_eq fail "$(sv_get cold "$(sv_run)")" "the bridge stalls fail the new rule too"
  # The same run's mint cell: 2/864.
  sv_row cold 2/864 2/864 1668543 >"$CASE_DIR/check.tsv"
  assert_eq pass "$(sv_get cold "$(sv_run)")" "mint's 2/864 passes"
}

t_failures_are_judged_apart_from_timeouts() {
  local out
  sv_row cold 0/864 12/864 >"$CASE_DIR/check.tsv"
  out="$(sv_run)"
  assert_eq fail "$(sv_get cold "$out")" "12/864 SERVFAILs fail even with no timeout"
  assert_match 'failures 12/864 over 1/100' "$out" "and says why"
}

t_p95_is_recorded_never_gated() {
  local out
  sv_row cold 0/864 0/864 9999999 >"$CASE_DIR/check.tsv"
  out="$(sv_run)"
  assert_eq pass "$(sv_get cold "$out")" "a 10 s p95 does not fail the soak"
  assert_match 'p95=9999999' "$out" "but it is in the verdict"
  sv_row cold 0/864 0/864 inf >"$CASE_DIR/check.tsv"
  assert_eq pass "$(sv_get cold "$(sv_run)")" "an unbounded p95 does not either"
}

t_too_few_samples_are_not_judged() {
  local out
  sv_row cold 0/29 0/29 >"$CASE_DIR/check.tsv"
  out="$(sv_run)"
  assert_eq insufficient "$(sv_get cold "$out")" "29 samples are not enough"
  sv_row cold 5/29 5/29 >"$CASE_DIR/check.tsv"
  assert_eq insufficient "$(sv_get cold "$(sv_run)")" "not a fail either"
  sv_row cold 0/30 0/30 >"$CASE_DIR/check.tsv"
  assert_eq pass "$(sv_get cold "$(sv_run)")" "30 are"
}

t_bad_input_is_refused() {
  local rc
  printf '# schema\tx\n' >"$CASE_DIR/check.tsv"
  sv_run >/dev/null 2>&1; rc=$?
  assert_eq 2 "$rc" "no workload rows is refused"
  sv_row cold 9/8 9/8 >"$CASE_DIR/check.tsv"
  sv_run >/dev/null 2>&1; rc=$?
  assert_eq 2 "$rc" "more timeouts than samples is refused"
  sv_row cold 5/864 3/864 >"$CASE_DIR/check.tsv"
  sv_run >/dev/null 2>&1; rc=$?
  assert_eq 2 "$rc" "more timeouts than failures is refused"
  sv_row cold 1/864 1/800 >"$CASE_DIR/check.tsv"
  sv_run >/dev/null 2>&1; rc=$?
  assert_eq 2 "$rc" "counts over different sample totals are refused"
  printf 'workload\tc\tcold\tfail\ttimeouts_cand=x\tfailures_cand=1/2\n' >"$CASE_DIR/check.tsv"
  sv_run >/dev/null 2>&1; rc=$?
  assert_eq 2 "$rc" "a malformed count is refused"
  python3 "$SV" "$CASE_DIR/missing.tsv" >/dev/null 2>&1; rc=$?
  assert_eq 2 "$rc" "an unreadable file is refused"
}
