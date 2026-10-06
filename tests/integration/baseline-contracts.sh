# shellcheck shell=bash
# Group integration/baseline-contracts (sub-plan 01, Stage 1 gate).
#
# Interaction scenarios across the Stage 1 outputs: the runner and its
# manifests (Task 1.1), the fixtures (Task 1.2) and the collector/stats
# (Task 1.3). Single-task assertions live in the unit groups; these cases
# only test how the pieces fit together, and that a missing mandatory
# scenario or an omitted variant is refused before anything runs.

# shellcheck source=tests/fixtures/fixture.sh
. "$NICE_DNS_ROOT/tests/fixtures/fixture.sh"

BC_RUN="$NICE_DNS_ROOT/tests/run.sh"
BC_MAN="$NICE_DNS_ROOT/tests/manifests"

bc_manifests() {
  # Private copy of the manifests (with absolute group paths) to mutate.
  mkdir -p "$CASE_DIR/m"
  cp "$BC_MAN"/*.tsv "$CASE_DIR/m/"
  awk -F '\t' -v OFS='\t' -v r="$NICE_DNS_ROOT" '/^#/ || NF < 4 { print; next } { $3 = r "/" $3; print }' \
    "$BC_MAN/groups.tsv" >"$CASE_DIR/m/groups.tsv"
  bc_check
  assert_rc 0 "$BC_RC" "the unmodified manifest copy passes check-scenarios: $BC_OUT"
}

bc_check() {
  BC_OUT="$(NICE_DNS_TEST_MANIFESTS="$CASE_DIR/m" bash "$BC_RUN" check-scenarios 2>&1)"
  BC_RC=$?
}

t_scenarios_real_manifest_passes() {
  BC_OUT="$(bash "$BC_RUN" check-scenarios 2>&1)"
  assert_rc 0 $? "check-scenarios on the real manifests: $BC_OUT"
  assert_match 'active=[1-9][0-9]*' "$BC_OUT" "reports active scenarios"
  assert_match 'deferred=' "$BC_OUT" "reports deferred scenarios by owner"
}

t_each_privacy_op_without_scenario_fails() {
  local op n=0
  bc_manifests
  for op in $(grep -v '^#' "$BC_MAN/privacy-ops.tsv" | cut -f1); do
    n=$((n + 1))
    awk -F '\t' -v o="$op" '$2 != o' "$BC_MAN/scenarios.tsv" >"$CASE_DIR/m/scenarios.tsv"
    bc_check
    assert_nonzero "$BC_RC" "removing every scenario for $op must fail"
    assert_match "$op" "$BC_OUT" "refusal names $op"
  done
  assert_eq 22 "$n" "all 22 mandatory operations were exercised"
}

t_each_variant_without_active_scenario_fails() {
  local v n=0
  bc_manifests
  for v in $(grep -v '^#' "$BC_MAN/variants.tsv" | cut -f1); do
    n=$((n + 1))
    awk -F '\t' -v c="variant:$v" '$2 != c' "$BC_MAN/scenarios.tsv" >"$CASE_DIR/m/scenarios.tsv"
    bc_check
    assert_nonzero "$BC_RC" "omitting variant $v must fail"
    assert_match "$v" "$BC_OUT" "refusal names $v"
  done
  [ "$n" -ge 20 ] || fail "only $n variants exercised"
}

t_deferred_row_cannot_satisfy_a_variant() {
  bc_manifests
  awk -F '\t' -v OFS='\t' '$2 == "variant:tls/expired" { $3 = "-"; $4 = "-"; $5 = "-"; $6 = "transport" } { print }' \
    "$BC_MAN/scenarios.tsv" >"$CASE_DIR/m/scenarios.tsv"
  bc_check
  assert_nonzero "$BC_RC" "a variant covered only by a deferred row"
  assert_match 'tls/expired' "$BC_OUT" "refusal names the variant"
}

t_scenario_pointing_at_missing_case_fails() {
  bc_manifests
  sed 's/t_dot_expired_rejected/t_no_such_case/' "$BC_MAN/scenarios.tsv" >"$CASE_DIR/m/scenarios.tsv"
  bc_check
  assert_nonzero "$BC_RC" "missing case"
  assert_match 't_no_such_case' "$BC_OUT" "refusal names the missing case"
}

t_scenario_rows_are_well_formed() {
  local bad
  bc_manifests
  for bad in 'X1	SEC-NOPE	-	-	-	transport' 'X2	variant:tls/nope	unit	fixtures	t_dot_expired_rejected	baseline' \
    'X3	SEC-TLS-NAME	-	-	-	someone' 'X4	SEC-TLS-NAME	unit	no-group	t_x	baseline' \
    'X5	SEC-TLS-NAME	unit	fixtures	-	baseline' 'S1-TLS-GOOD	SEC-TLS-NAME	-	-	-	transport' 'X7	SEC-TLS-NAME	-	-'; do
    { cat "$BC_MAN/scenarios.tsv"; printf '%s\n' "$bad"; } >"$CASE_DIR/m/scenarios.tsv"
    bc_check
    assert_nonzero "$BC_RC" "malformed row accepted: $bad"
  done
}

t_stage_refuses_before_running_when_coverage_missing() {
  local out rc
  bc_manifests
  awk -F '\t' '$2 != "variant:dnssec/bogus-rejected"' "$BC_MAN/scenarios.tsv" >"$CASE_DIR/m/scenarios.tsv"
  out="$(NICE_DNS_TEST_MANIFESTS="$CASE_DIR/m" bash "$BC_RUN" stage baseline-contracts 2>&1)"
  rc=$?
  assert_nonzero "$rc" "stage with an omitted variant"
  assert_match 'dnssec/bogus-rejected' "$out" "stage refusal names the omitted variant"
  assert_not_match '^== ' "$out" "no group ran"
}

t_fixture_collector_stats_pipeline() {
  # Fixture -> collector -> stats inside one runner artifact dir: every
  # attempt (answered, NXDOMAIN, timeout, SERVFAIL) reaches the report.
  local s="$CASE_DIR/samples.tsv" st rows
  fx_start "$CASE_DIR/fx" || fail "fixture did not start"
  trap 'fx_stop "$CASE_DIR/fx"' EXIT
  printf 'target_id\tpipeline\nplatform\tlinux\nproxy\tsocat\npihole\thardened\nsource_rev\t%s\nimages\tnone:fixture\n' \
    "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)" >"$CASE_DIR/id.tsv"
  printf 'p-warm\thit\tsigned.fixture.test\tA\np-cold\tmiss\t{nonce}.fixture.test\tA\np-drop\tmiss\tdrop.fixture.test\tA\np-sf\tmiss\tservfail.fixture.test\tA\n' \
    >"$CASE_DIR/w.tsv"
  set -- --resolver "127.0.0.1#$(fx_port "$CASE_DIR/fx" dns)" --identity "$CASE_DIR/id.tsv" --workloads "$CASE_DIR/w.tsv" --out "$s" --timeout-ms 1000
  bash "$NICE_DNS_ROOT/tests/live/collect.sh" "$@" --workload p-warm --count 3 >/dev/null 2>&1
  assert_rc 0 $? "warm"
  bash "$NICE_DNS_ROOT/tests/live/collect.sh" "$@" --workload p-cold --count 2 >/dev/null 2>&1
  assert_rc 0 $? "cold NXDOMAIN answers"
  bash "$NICE_DNS_ROOT/tests/live/collect.sh" "$@" --workload p-drop --count 1 >/dev/null 2>&1
  assert_nonzero $? "drop"
  bash "$NICE_DNS_ROOT/tests/live/collect.sh" "$@" --workload p-sf --count 1 >/dev/null 2>&1
  assert_nonzero $? "servfail"
  rows="$(grep -vc '^#' "$s")"
  assert_eq 8 "$rows" "header + 7 attempted queries"
  assert_eq "$RUN_ID" "$(awk -F '\t' 'NR > 2 { print $1 }' "$s" | sort -u)" "runner RUN_ID flows into every sample"
  st="$(bash "$NICE_DNS_ROOT/tests/reports/stats.sh" "$s")"
  assert_rc 0 $? "stats"
  assert_eq 7 "$(printf '%s\n' "$st" | awk -F '\t' 'NR > 1 { a += $2 } END { print a }')" "report attempted equals rows"
  assert_match '^p-drop	1	0	1	1	1\.0000	1\.0000	n/a	' "$st" "timeout kept in the denominator"
  assert_match '^p-sf	1	0	1	0	1\.0000	0\.0000	' "$st" "servfail is a failure, not a timeout"
  assert_match '^p-cold	2	2	0	0	0\.0000	' "$st" "NXDOMAIN is an answer"
  case "$s" in "$ARTIFACT_DIR"/*) ;; *) fail "samples outside the run's artifact dir" ;; esac
}

t_collector_accepts_exactly_the_matrix_cells() {
  local p x h rc
  fx_start "$CASE_DIR/fx" || fail "fixture did not start"
  trap 'fx_stop "$CASE_DIR/fx"' EXIT
  printf 'w\thit\tsigned.fixture.test\tA\n' >"$CASE_DIR/w.tsv"
  while IFS='	' read -r p x h; do
    case "$p" in ''|'#'*) continue ;; esac
    printf 'target_id\tt\nplatform\t%s\nproxy\t%s\npihole\t%s\nsource_rev\tr\nimages\ti\n' "$p" "$x" "$h" >"$CASE_DIR/id.tsv"
    bash "$NICE_DNS_ROOT/tests/live/collect.sh" --resolver "127.0.0.1#$(fx_port "$CASE_DIR/fx" dns)" \
      --identity "$CASE_DIR/id.tsv" --workloads "$CASE_DIR/w.tsv" --workload w --count 1 --out "$CASE_DIR/s-$p-$x-$h.tsv" >/dev/null 2>&1
    assert_rc 0 $? "matrix cell $p/$x/$h accepted"
  done <"$BC_MAN/matrix.tsv"
  printf 'target_id\tt\nplatform\twindows\nproxy\thaproxy\npihole\tstandard\nsource_rev\tr\nimages\ti\n' >"$CASE_DIR/id.tsv"
  bash "$NICE_DNS_ROOT/tests/live/collect.sh" --resolver "127.0.0.1#$(fx_port "$CASE_DIR/fx" dns)" \
    --identity "$CASE_DIR/id.tsv" --workloads "$CASE_DIR/w.tsv" --workload w --count 1 --out "$CASE_DIR/s-off.tsv" >/dev/null 2>&1
  rc=$?
  assert_eq 2 "$rc" "an identity outside the eight-cell matrix is refused"
  assert_no_path "$CASE_DIR/s-off.tsv" "no samples for an off-matrix identity"
}

t_contracts_ops_and_scenarios_agree() {
  local out op
  out="$(bash "$BC_RUN" check-contracts "$NICE_DNS_ROOT/docs/workflows/dns-lifecycle.md" 2>&1)"
  assert_rc 0 $? "contracts: $out"
  for op in $(grep -v '^#' "$BC_MAN/privacy-ops.tsv" | cut -f1); do
    assert_match "\\[$op\\]" "$(cat "$NICE_DNS_ROOT/docs/workflows/dns-lifecycle.md")" "$op tagged in the workflow contract"
    assert_match "	$op	" "$(cat "$BC_MAN/scenarios.tsv")" "$op has a scenario row"
  done
}

t_each_scenario_names_a_distinct_property() {
  # One variant = one property: a variant may not be carried by two different
  # cases, or deleting either case would go unnoticed.
  local dup
  dup="$(awk -F '\t' '!/^#/ && $2 ~ /^variant:/ && $5 != "-" { if (($2) in c && c[$2] != $5) print $2; c[$2] = $5 }' "$BC_MAN/scenarios.tsv")"
  assert_eq "" "$dup" "variants carried by more than one case"
}

t_no_generated_files_tracked() {
  assert_eq "" "$(git -C "$NICE_DNS_ROOT" ls-files | grep -E '(^|/)__pycache__/|\.py[co]$')" "compiled Python is not tracked"
  assert_match '__pycache__' "$(cat "$NICE_DNS_ROOT/.gitignore")" ".gitignore excludes __pycache__"
}
