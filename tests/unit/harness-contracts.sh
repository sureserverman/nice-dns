# shellcheck shell=bash
# Group: harness-contracts (unit, tier local) — Task 1.1 of sub-plan 01.
#
# Sourced by tests/run.sh, which provides the assert_* helpers and exports
# NICE_DNS_ROOT, RUN_ID, ARTIFACT_DIR and CASE_DIR. Every case is a t_*
# function; every file a case writes lives under $CASE_DIR. Nested runner
# invocations are pointed at $CASE_DIR through NICE_DNS_TEST_ARTIFACTS, so
# they never touch the operator's default artifact root or the checkout.
#
# Helpers use the hc_ prefix so the runner does not collect them as cases.

hc_runner() { printf '%s\n' "$NICE_DNS_ROOT/tests/run.sh"; }

# hc_run <args...>: run the runner with nested artifacts under $CASE_DIR.
# Sets HC_RC and HC_OUT (stdout+stderr). HC_MANIFESTS, when set, selects a
# temporary manifest directory; otherwise the real manifests are used.
hc_run() {
  local out="$CASE_DIR/hc-run.out"
  (
    if [ -n "${HC_MANIFESTS:-}" ]; then
      NICE_DNS_TEST_MANIFESTS="$HC_MANIFESTS"; export NICE_DNS_TEST_MANIFESTS
    else
      unset NICE_DNS_TEST_MANIFESTS
    fi
    NICE_DNS_TEST_ARTIFACTS="${HC_ARTIFACTS:-$CASE_DIR/nested}"
    export NICE_DNS_TEST_ARTIFACTS
    bash "$(hc_runner)" "$@"
  ) >"$out" 2>&1
  HC_RC=$?
  HC_OUT="$(cat "$out")"
}

# hc_inventory <args...>: same capture contract for tests/inventory.sh.
hc_inventory() {
  local out="$CASE_DIR/hc-inv.out"
  (
    NICE_DNS_TEST_ARTIFACTS="${HC_ARTIFACTS:-$CASE_DIR/nested}"
    export NICE_DNS_TEST_ARTIFACTS
    bash "$NICE_DNS_ROOT/tests/inventory.sh" "$@"
  ) >"$out" 2>&1
  HC_RC=$?
  HC_OUT="$(cat "$out")"
}

# hc_manifests <dir>: create a temp manifest dir with real matrix/privacy-ops
# copies and an empty group registry and stage list.
hc_manifests() {
  local d="$1"
  mkdir -p "$d"
  cp "$NICE_DNS_ROOT/tests/manifests/matrix.tsv" "$d/" 2>/dev/null || true
  cp "$NICE_DNS_ROOT/tests/manifests/privacy-ops.tsv" "$d/" 2>/dev/null || true
  printf '# kind\tgroup\tfile\ttier\n' >"$d/groups.tsv"
  printf '# stage\tkind\tgroup\n' >"$d/stages.tsv"
}

# hc_group_file <path> <body>: write a sourced group file.
hc_group_file() { printf '%s\n' "$2" >"$1"; }

hc_passing_group='t_ok() { assert_eq 1 1 "trivial"; printf "%s\t%s\n" "$RUN_ID" "$ARTIFACT_DIR" >"$ARTIFACT_DIR/probe.tsv"; }'

# ─────────────────────────── runner: listing and selection ───────────────────

t_list_shows_harness_contracts_with_cases() {
  hc_run --list
  assert_rc 0 "$HC_RC" "--list on the real registry"
  assert_match '(^|[[:space:]])unit[[:space:]]+harness-contracts[[:space:]].*cases=[1-9][0-9]*' "$HC_OUT" \
    "--list must show harness-contracts with a nonzero case count"
}

t_list_flags_missing_and_empty_groups() {
  local m="$CASE_DIR/m"
  hc_manifests "$m"
  hc_group_file "$CASE_DIR/empty.sh" 'helper_only() { :; }'
  printf 'unit\tghost\t%s\tlocal\n' "$CASE_DIR/does-not-exist.sh" >>"$m/groups.tsv"
  printf 'unit\thollow\t%s\tlocal\n' "$CASE_DIR/empty.sh" >>"$m/groups.tsv"
  HC_MANIFESTS="$m" hc_run --list
  assert_nonzero "$HC_RC" "--list must fail when a group is missing or empty"
  assert_match 'ghost.*MISSING' "$HC_OUT" "missing group file reported"
  assert_match 'hollow.*(EMPTY|cases=0)' "$HC_OUT" "zero-case group reported"
}

t_unknown_group_rejected() {
  hc_run unit no-such-group
  assert_rc 2 "$HC_RC" "unknown group exit code"
  assert_match 'unknown group' "$HC_OUT" "unknown group message"
  assert_not_match '(^|[[:space:]])PASS' "$HC_OUT" "nothing may pass"
}

t_unknown_kind_rejected() {
  hc_run bogus harness-contracts
  assert_rc 2 "$HC_RC" "unknown kind exit code"
  assert_match 'unknown kind' "$HC_OUT" "unknown kind message"
}

t_kind_mismatch_rejected() {
  hc_run integration harness-contracts
  assert_rc 2 "$HC_RC" "group registered under another kind"
  assert_match 'unknown group' "$HC_OUT" "kind/group mismatch message"
}

t_unknown_option_rejected() {
  hc_run unit harness-contracts --no-such-option
  assert_rc 2 "$HC_RC" "unknown option exit code"
  assert_match 'unknown option' "$HC_OUT" "unknown option message"
}

t_zero_case_group_rejected() {
  local m="$CASE_DIR/m"
  hc_manifests "$m"
  hc_group_file "$CASE_DIR/empty.sh" 'not_a_case() { :; }'
  printf 'unit\thollow\t%s\tlocal\n' "$CASE_DIR/empty.sh" >>"$m/groups.tsv"
  HC_MANIFESTS="$m" hc_run unit hollow
  assert_nonzero "$HC_RC" "zero collected cases must never be green"
  assert_match 'collected=0' "$HC_OUT" "summary reports zero collected"
  assert_not_match '(^|[[:space:]])PASS' "$HC_OUT" "no PASS line"
}

t_missing_group_file_rejected() {
  local m="$CASE_DIR/m"
  hc_manifests "$m"
  printf 'unit\tghost\t%s\tlocal\n' "$CASE_DIR/nope.sh" >>"$m/groups.tsv"
  HC_MANIFESTS="$m" hc_run unit ghost
  assert_nonzero "$HC_RC" "registered group whose file is missing"
  assert_match 'missing' "$HC_OUT" "missing file message"
}

t_live_tier_refused_without_live() {
  local m="$CASE_DIR/m" marker="$CASE_DIR/live-ran"
  hc_manifests "$m"
  hc_group_file "$CASE_DIR/live.sh" "t_live() { : >\"$marker\"; assert_eq 1 1; }"
  printf 'live\tlivegrp\t%s\tlive\n' "$CASE_DIR/live.sh" >>"$m/groups.tsv"
  HC_MANIFESTS="$m" hc_run live livegrp
  assert_rc 3 "$HC_RC" "live tier without --live is NOT RUN"
  assert_match 'NOT RUN' "$HC_OUT" "refusal says it was not run"
  assert_not_match '(^|[[:space:]])PASS' "$HC_OUT" "refusal is never a pass"
  assert_no_path "$marker" "live case body must not execute"
  HC_MANIFESTS="$m" hc_run live livegrp --live
  assert_rc 3 "$HC_RC" "--live without --targets is NOT RUN"
  assert_no_path "$marker" "live case body must not execute without targets"
}

t_slow_tier_refused_without_include_slow() {
  local m="$CASE_DIR/m" marker="$CASE_DIR/slow-ran"
  hc_manifests "$m"
  hc_group_file "$CASE_DIR/slow.sh" "t_slow() { : >\"$marker\"; assert_eq 1 1; }"
  printf 'unit\tslowgrp\t%s\tslow\n' "$CASE_DIR/slow.sh" >>"$m/groups.tsv"
  HC_MANIFESTS="$m" hc_run unit slowgrp
  assert_rc 3 "$HC_RC" "slow tier without --include-slow is NOT RUN"
  assert_match 'NOT RUN' "$HC_OUT" "refusal says it was not run"
  assert_no_path "$marker" "slow case body must not execute"
  HC_MANIFESTS="$m" hc_run unit slowgrp --include-slow
  assert_rc 0 "$HC_RC" "slow tier runs with --include-slow"
  assert_file "$marker" "slow case body executed once opted in"
}

t_registry_rejects_live_kind_on_local_tier() {
  local m="$CASE_DIR/m"
  hc_manifests "$m"
  hc_group_file "$CASE_DIR/g.sh" "$hc_passing_group"
  printf 'live\tsneaky\t%s\tlocal\n' "$CASE_DIR/g.sh" >>"$m/groups.tsv"
  HC_MANIFESTS="$m" hc_run live sneaky
  assert_rc 2 "$HC_RC" "a live-kind group registered as local tier is a registry error"
}

t_unknown_stage_rejected() {
  hc_run stage no-such-stage
  assert_rc 2 "$HC_RC" "unknown stage exit code"
  assert_match 'unknown stage' "$HC_OUT" "unknown stage message"
}

t_stage_with_unregistered_group_rejected() {
  local m="$CASE_DIR/m"
  hc_manifests "$m"
  printf 'dangling\tunit\tnot-registered\n' >>"$m/stages.tsv"
  HC_MANIFESTS="$m" hc_run stage dangling
  assert_rc 2 "$HC_RC" "stage naming an unregistered group"
  assert_match 'not-registered' "$HC_OUT" "names the bad group"
}

t_stage_runs_listed_groups() {
  local m="$CASE_DIR/m"
  hc_manifests "$m"
  hc_group_file "$CASE_DIR/g.sh" "$hc_passing_group"
  hc_group_file "$CASE_DIR/h.sh" 't_one() { assert_eq a a; }
t_two() { assert_eq b b; }'
  printf 'unit\tga\t%s\tlocal\nunit\tgb\t%s\tlocal\n' "$CASE_DIR/g.sh" "$CASE_DIR/h.sh" >>"$m/groups.tsv"
  printf 'pair\tunit\tga\npair\tunit\tgb\n' >>"$m/stages.tsv"
  # Every stage checks scenario coverage first: give the synthetic registry
  # one operation covered by one of its own cases.
  printf 'TEST-OP\tsynthetic operation\n' >"$m/privacy-ops.tsv"
  printf '# variant\tmeaning\n' >"$m/variants.tsv"
  printf 'S-TEST\tTEST-OP\tunit\tga\tt_ok\tbaseline\n' >"$m/scenarios.tsv"
  HC_MANIFESTS="$m" hc_run stage pair
  assert_rc 0 "$HC_RC" "stage of two passing groups"
  assert_match 'collected=3 passed=3 failed=0' "$HC_OUT" "stage aggregates every group"
}

t_stage_with_one_empty_group_fails() {
  local m="$CASE_DIR/m"
  hc_manifests "$m"
  hc_group_file "$CASE_DIR/g.sh" "$hc_passing_group"
  hc_group_file "$CASE_DIR/e.sh" '# no cases here'
  printf 'unit\tga\t%s\tlocal\nunit\tge\t%s\tlocal\n' "$CASE_DIR/g.sh" "$CASE_DIR/e.sh" >>"$m/groups.tsv"
  printf 'mixed\tunit\tga\nmixed\tunit\tge\n' >>"$m/stages.tsv"
  printf 'TEST-OP\tsynthetic operation\n' >"$m/privacy-ops.tsv"
  printf '# variant\tmeaning\n' >"$m/variants.tsv"
  printf 'S-TEST\tTEST-OP\tunit\tga\tt_ok\tbaseline\n' >"$m/scenarios.tsv"
  HC_MANIFESTS="$m" hc_run stage mixed
  assert_nonzero "$HC_RC" "a stage with one empty group is not green even when the other passes"
  assert_match 'result=fail' "$HC_OUT" "stage result is fail"
}

t_real_stages_reference_registered_groups() {
  local stages="$NICE_DNS_ROOT/tests/manifests/stages.tsv" n
  assert_file "$stages" "stages manifest exists"
  n="$(grep -c '^baseline-contracts	' "$stages" || true)"
  assert_match '^[1-9][0-9]*$' "$n" "baseline-contracts has at least one group"
  n="$(grep -c '^baseline	' "$stages" || true)"
  assert_match '^[1-9][0-9]*$' "$n" "baseline has at least one group"
  hc_run --list
  assert_not_match 'UNREGISTERED' "$HC_OUT" "every stage row resolves to a registered group"
}

t_plan_and_receipt_are_blocked() {
  hc_run plan baseline --fresh-fixtures --include-slow --live --targets x --matrix all
  assert_rc 4 "$HC_RC" "plan is BLOCKED"
  assert_match 'not implemented until Task 2\.2' "$HC_OUT" "plan message"
  hc_run receipt baseline --require-matrix all
  assert_rc 4 "$HC_RC" "receipt is BLOCKED"
  assert_match 'BLOCKED' "$HC_OUT" "receipt says BLOCKED"
}

# ─────────────────────────── runner: run identity and artifacts ──────────────

t_artifact_dir_outside_checkout_with_receipt() {
  local m="$CASE_DIR/m" root="$CASE_DIR/art" runs d rid adir
  hc_manifests "$m"
  hc_group_file "$CASE_DIR/g.sh" "$hc_passing_group"
  printf 'unit\tprobe\t%s\tlocal\n' "$CASE_DIR/g.sh" >>"$m/groups.tsv"
  HC_ARTIFACTS="$root" HC_MANIFESTS="$m" hc_run unit probe
  assert_rc 0 "$HC_RC" "probe group passes"
  runs="$(find "$root/runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  assert_eq 1 "$runs" "exactly one run dir created"
  d="$(find "$root/runs" -mindepth 1 -maxdepth 1 -type d)"
  assert_file "$d/probe.tsv" "case wrote into ARTIFACT_DIR"
  rid="$(cut -f1 "$d/probe.tsv")"; adir="$(cut -f2 "$d/probe.tsv")"
  assert_eq "$(basename "$d")" "$rid" "run dir is named by RUN_ID"
  assert_eq "$d" "$adir" "ARTIFACT_DIR exported to cases"
  assert_match '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$' "$rid" "RUN_ID is UTC stamp + random suffix"
  case "$adir/" in "$NICE_DNS_ROOT"/*) fail "artifact dir $adir is inside the checkout" ;; esac
  assert_file "$d/receipt.tsv" "creation receipt present"
  assert_match "run_id	$rid" "$(cat "$d/receipt.tsv")" "receipt run_id"
  assert_match 'created_utc	[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' "$(cat "$d/receipt.tsv")" "receipt UTC time"
  assert_match 'git_head	[0-9a-f]{40}' "$(cat "$d/receipt.tsv")" "receipt git HEAD"
  assert_match 'command	.*unit.*probe' "$(cat "$d/receipt.tsv")" "receipt command line"
}

t_artifact_root_inside_checkout_refused() {
  local inside="$NICE_DNS_ROOT/tests/reports/must-not-exist-$RUN_ID"
  HC_ARTIFACTS="$inside" hc_run unit harness-contracts
  assert_rc 2 "$HC_RC" "artifact root inside the checkout is refused"
  assert_match 'inside the checkout' "$HC_OUT" "refusal message"
  assert_no_path "$inside" "nothing created inside the checkout"
}

t_two_runs_get_distinct_run_ids() {
  local m="$CASE_DIR/m" root="$CASE_DIR/art2" n
  hc_manifests "$m"
  hc_group_file "$CASE_DIR/g.sh" "$hc_passing_group"
  printf 'unit\tprobe\t%s\tlocal\n' "$CASE_DIR/g.sh" >>"$m/groups.tsv"
  HC_ARTIFACTS="$root" HC_MANIFESTS="$m" hc_run unit probe
  assert_rc 0 "$HC_RC" "first run"
  HC_ARTIFACTS="$root" HC_MANIFESTS="$m" hc_run unit probe
  assert_rc 0 "$HC_RC" "second run"
  n="$(find "$root/runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  assert_eq 2 "$n" "two runs, two distinct run dirs"
}

t_case_isolation_and_summary() {
  local m="$CASE_DIR/m"
  hc_manifests "$m"
  hc_group_file "$CASE_DIR/g.sh" 't_a_fails() { assert_eq 1 2 "deliberate"; }
t_b_exits() { exit 7; }
t_c_passes() { assert_eq ok ok; }'
  printf 'unit\tmixed\t%s\tlocal\n' "$CASE_DIR/g.sh" >>"$m/groups.tsv"
  HC_MANIFESTS="$m" hc_run unit mixed
  assert_rc 1 "$HC_RC" "any failure makes the group fail"
  assert_match 'FAIL[[:space:]]+t_a_fails' "$HC_OUT" "failing case reported"
  assert_match 'FAIL[[:space:]]+t_b_exits' "$HC_OUT" "exiting case reported, not fatal to the run"
  assert_match 'PASS[[:space:]]+t_c_passes' "$HC_OUT" "later case still ran"
  assert_match 'collected=3 passed=1 failed=2' "$HC_OUT" "summary line"
}

t_case_without_assertions_fails() {
  local m="$CASE_DIR/m"
  hc_manifests "$m"
  hc_group_file "$CASE_DIR/g.sh" 't_vacuous() { :; }'
  printf 'unit\tvacuous\t%s\tlocal\n' "$CASE_DIR/g.sh" >>"$m/groups.tsv"
  HC_MANIFESTS="$m" hc_run unit vacuous
  assert_rc 1 "$HC_RC" "a case that asserts nothing is not green"
  assert_match 'no assertions' "$HC_OUT" "reason reported"
}

# ─────────────────────────── validators: matrix ──────────────────────────────

t_matrix_real_passes() {
  hc_run check-matrix "$NICE_DNS_ROOT/tests/manifests/matrix.tsv"
  assert_rc 0 "$HC_RC" "real matrix has the eight cells"
}

t_matrix_each_single_cell_deletion_fails() {
  local src="$NICE_DNS_ROOT/tests/manifests/matrix.tsv" line n=0 f cell
  assert_file "$src" "real matrix manifest exists"
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    f="$CASE_DIR/matrix-minus-$n.tsv"
    grep -vxF "$line" "$src" >"$f"
    cell="$(printf '%s' "$line" | tr '\t' '/')"
    hc_run check-matrix "$f"
    assert_nonzero "$HC_RC" "deleting cell $cell must fail"
    assert_match "missing.*$cell" "$HC_OUT" "error names missing cell $cell"
  done <"$src"
  assert_eq 8 "$n" "exercised all eight single-cell deletions"
}

t_matrix_duplicate_cell_fails() {
  local src="$NICE_DNS_ROOT/tests/manifests/matrix.tsv" f="$CASE_DIR/dup.tsv"
  assert_file "$src" "real matrix manifest exists"
  cat "$src" >"$f"
  printf 'linux\thaproxy\tstandard\n' >>"$f"
  hc_run check-matrix "$f"
  assert_nonzero "$HC_RC" "duplicate cell must fail"
  assert_match 'duplicate.*linux/haproxy/standard' "$HC_OUT" "names the duplicate"
}

t_matrix_unknown_value_fails() {
  local src="$NICE_DNS_ROOT/tests/manifests/matrix.tsv" f="$CASE_DIR/unk.tsv"
  assert_file "$src" "real matrix manifest exists"
  cat "$src" >"$f"
  printf 'windows\thaproxy\tstandard\n' >>"$f"
  hc_run check-matrix "$f"
  assert_nonzero "$HC_RC" "unknown platform must fail"
  assert_match 'unknown.*windows' "$HC_OUT" "names the unknown value"
}

t_matrix_malformed_row_fails() {
  local src="$NICE_DNS_ROOT/tests/manifests/matrix.tsv" f="$CASE_DIR/bad.tsv"
  assert_file "$src" "real matrix manifest exists"
  cat "$src" >"$f"
  printf 'linux haproxy standard\n' >>"$f"
  hc_run check-matrix "$f"
  assert_nonzero "$HC_RC" "row without three tab-separated fields must fail"
}

# ─────────────────────────── validators: workflow contracts ──────────────────

hc_doc() { printf '%s\n' "$NICE_DNS_ROOT/docs/workflows/dns-lifecycle.md"; }

t_contracts_real_doc_passes() {
  hc_run check-contracts "$(hc_doc)"
  assert_rc 0 "$HC_RC" "real workflow doc satisfies the contract check"
}

t_contracts_each_workflow_deletion_fails() {
  local id f
  assert_file "$(hc_doc)" "workflow doc exists"
  for id in WF-DNS-001 WF-DNS-002 WF-DNS-003 WF-DNS-004; do
    f="$CASE_DIR/doc-minus-$id.md"
    sed "s/$id//g" "$(hc_doc)" >"$f"
    hc_run check-contracts "$f"
    assert_nonzero "$HC_RC" "doc without $id must fail"
    assert_match "$id" "$HC_OUT" "error names $id"
  done
}

t_contracts_each_privacy_op_deletion_fails() {
  local ops="$NICE_DNS_ROOT/tests/manifests/privacy-ops.tsv" id rest f n=0
  assert_file "$ops" "privacy-ops manifest exists"
  while IFS="$(printf '\t')" read -r id rest; do
    case "$id" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    f="$CASE_DIR/doc-minus-$id.md"
    sed "s/\[$id\]//g" "$(hc_doc)" >"$f"
    hc_run check-contracts "$f"
    assert_nonzero "$HC_RC" "doc without [$id] must fail"
    assert_match "$id" "$HC_OUT" "error names $id"
  done <"$ops"
  assert_match '^[1-9][0-9]*$' "$n" "at least one mandatory operation exercised"
}

t_contracts_unknown_operation_tag_fails() {
  local f="$CASE_DIR/doc-unknown.md"
  assert_file "$(hc_doc)" "workflow doc exists"
  { cat "$(hc_doc)"; printf '\n- stray invariant [SEC-NOT-A-REAL-OP]\n'; } >"$f"
  hc_run check-contracts "$f"
  assert_nonzero "$HC_RC" "tag not in privacy-ops.tsv must fail"
  assert_match 'SEC-NOT-A-REAL-OP' "$HC_OUT" "names the unknown tag"
}

t_contracts_missing_subsection_fails() {
  local f="$CASE_DIR/doc-noinv.md"
  assert_file "$(hc_doc)" "workflow doc exists"
  assert_match '^#+ Invariants' "$(awk '/^## WF-DNS-002/{w=1;next} /^## /{w=0} w' "$(hc_doc)")" \
    "precondition: WF-DNS-002 has an Invariants heading"
  awk '/^## WF-DNS-002/{inwf=1} /^## /&&!/^## WF-DNS-002/{inwf=0}
       inwf && /^#+ Invariants/{next} {print}' "$(hc_doc)" >"$f"
  hc_run check-contracts "$f"
  assert_nonzero "$HC_RC" "WF-DNS-002 without an Invariants section must fail"
  assert_match 'WF-DNS-002.*Invariants' "$HC_OUT" "names the section"
}

t_privacy_ops_manifest_wellformed() {
  local ops="$NICE_DNS_ROOT/tests/manifests/privacy-ops.tsv" id meaning extra dups n=0
  assert_file "$ops" "privacy-ops manifest exists"
  while IFS="$(printf '\t')" read -r id meaning extra; do
    case "$id" in ''|'#'*) continue ;; esac
    assert_match '^(SEC|PRIV|EVD|REC)-[A-Z0-9]+(-[A-Z0-9]+)*$' "$id" "operation id shape"
    assert_ne "" "$meaning" "operation $id has a meaning"
    assert_eq "" "${extra:-}" "operation $id has exactly two columns"
    n=$((n + 1))
  done <"$ops"
  assert_match '^[1-9][0-9]*$' "$n" "manifest lists at least one operation"
  dups="$(grep -v '^#' "$ops" | cut -f1 | sort | uniq -d)"
  assert_eq "" "$dups" "operation ids are unique"
}

# ─────────────────────────── inventory ───────────────────────────────────────

# hc_fixture_repo <dir> [untracked-bridge-eval]: tiny committed git repo.
hc_fixture_repo() {
  (
    HOME="$CASE_DIR/home"; export HOME
    GIT_CONFIG_NOSYSTEM=1; export GIT_CONFIG_NOSYSTEM
    mkdir -p "$HOME" "$1"
    cd "$1" || exit 1
    git init -q . || exit 1
    printf 'fixture\n' >README
    git add README
    git -c user.name=fixture -c user.email=fixture@example.invalid \
        -c commit.gpgsign=false commit -q -m fixture || exit 1
    if [ "${2:-}" = untracked-bridge-eval ]; then
      mkdir -p bridge-eval && printf 'bin\n' >bridge-eval/bridge-eval
    fi
  )
}

hc_fixture_siblings() {
  local s="$1"
  hc_fixture_repo "$s/tor-haproxy" untracked-bridge-eval || return 1
  hc_fixture_repo "$s/tor-socat" || return 1
  hc_fixture_repo "$s/hardened-unbound" || return 1
  hc_fixture_repo "$s/pi-hole-hardened" || return 1
}

t_inventory_records_every_repo() {
  local s="$CASE_DIR/sibs" out="$CASE_DIR/inv" r f nfiles
  hc_fixture_siblings "$s"
  assert_rc 0 "$?" "fixture sibling repos created"
  NICE_DNS_SIBLINGS_DIR="$s" hc_inventory baseline --out "$out"
  assert_rc 0 "$HC_RC" "inventory succeeds with all five repos"
  for r in nice-dns tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
    f="$out/$r.inventory.tsv"
    assert_file "$f" "inventory file for $r"
    assert_match 'head	[0-9a-f]{40}' "$(cat "$f")" "$r has a full 40-hex HEAD"
    nfiles="$(grep -c '^file	' "$f" || true)"
    assert_match '^[1-9][0-9]*$' "$nfiles" "$r has a non-empty file list"
  done
  assert_match 'untrusted	bridge-eval/bridge-eval' "$(cat "$out/tor-haproxy.inventory.tsv")" \
    "untracked bridge-eval binary flagged untrusted"
  assert_file "$out/content-sweep.tsv" "content sweep recorded"
}

t_inventory_file_list_not_truncated() {
  local s="$CASE_DIR/sibs" out="$CASE_DIR/inv" want got
  hc_fixture_siblings "$s"
  NICE_DNS_SIBLINGS_DIR="$s" hc_inventory baseline --out "$out"
  assert_rc 0 "$HC_RC" "inventory succeeds"
  want="$(GIT_OPTIONAL_LOCKS=0 git -C "$NICE_DNS_ROOT" ls-files | wc -l | tr -d ' ')"
  got="$(grep -c '^file	' "$out/nice-dns.inventory.tsv" || true)"
  assert_eq "$want" "$got" "nice-dns file list equals git ls-files exactly"
}

t_inventory_missing_sibling_fails() {
  local s="$CASE_DIR/sibs" out="$CASE_DIR/inv"
  hc_fixture_repo "$s/tor-haproxy"
  hc_fixture_repo "$s/tor-socat"
  hc_fixture_repo "$s/hardened-unbound"
  NICE_DNS_SIBLINGS_DIR="$s" hc_inventory baseline --out "$out"
  assert_nonzero "$HC_RC" "missing sibling must fail"
  assert_match 'pi-hole-hardened' "$HC_OUT" "names the missing sibling"
}

t_inventory_default_out_is_run_scoped() {
  local s="$CASE_DIR/sibs" root="$CASE_DIR/inv-art" path
  hc_fixture_siblings "$s"
  HC_ARTIFACTS="$root" NICE_DNS_SIBLINGS_DIR="$s" hc_inventory baseline
  assert_rc 0 "$HC_RC" "inventory with default output"
  path="$(printf '%s\n' "$HC_OUT" | tail -n 1)"
  assert_match "^$root/runs/[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}/inventory\$" "$path" \
    "prints a run-scoped output path"
  assert_file "$(dirname "$path")/receipt.tsv" "inventory run has a creation receipt"
  assert_file "$path/nice-dns.inventory.tsv" "inventory written there"
}

t_inventory_unknown_mode_rejected() {
  hc_inventory nonsense
  assert_rc 2 "$HC_RC" "unknown inventory mode"
}
