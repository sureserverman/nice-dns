# shellcheck shell=bash
# Group integration/install-lifecycle-dryrun (Sub-plan 4, Task 2.3). The dry
# run the live-gates rule asks for before live/install-lifecycle touches a
# target: the live group's own cases (t_1..t_6, sourced unchanged) run
# against tests/fixtures/lifecycle-adapter.sh, a fake target.sh with the same
# operations and report format, and must pass on a well-behaved fake; then
# each defect the live checks exist for is seeded in a fresh fake and the step
# that should catch it must fail. Nothing touches a host.
#
# The one live check the dry run cannot keep is "the checkout is committed"
# (the archive is of HEAD): a dry run of uncommitted work is the point, so
# NICE_DNS_IL_DRY_RUN=1 skips it and says so.

# The fake evidence stays out of the run's own install-lifecycle/, which the
# installers receipt of a plan run reads.
DR_RUN_DIR="$ARTIFACT_DIR"
ARTIFACT_DIR="$DR_RUN_DIR/dryrun"
mkdir -p "$ARTIFACT_DIR"
NICE_DNS_TARGET_ADAPTER="$NICE_DNS_ROOT/tests/fixtures/lifecycle-adapter.sh"
NICE_DNS_IL_DRY_RUN=1
NICE_DNS_OPT_TARGETS=fake-targets.env
NICE_DNS_OPT_VARIANTS=representative
NICE_DNS_OPT_PLATFORMS=all
export ARTIFACT_DIR NICE_DNS_TARGET_ADAPTER NICE_DNS_IL_DRY_RUN NICE_DNS_OPT_TARGETS NICE_DNS_OPT_VARIANTS NICE_DNS_OPT_PLATFORMS

# shellcheck source=tests/live/install-lifecycle.sh
. "$NICE_DNS_ROOT/tests/live/install-lifecycle.sh"

# dr_catches <defect> <step...>: in a fresh fake with <defect> seeded, the
# steps run in order and one of them fails (the live check bites).
dr_catches() {
  local brk="$1" s out
  shift
  out="$(
    ARTIFACT_DIR="$CASE_DIR/art-$brk" IL_FAKE_DIR="$CASE_DIR/art-$brk/il-fake"
    export ARTIFACT_DIR IL_FAKE_DIR
    mkdir -p "$IL_FAKE_DIR" && printf '%s\n' "$brk" >"$IL_FAKE_DIR/break"
    for s in "$@"; do
      ( il_each "$s" ) >"$CASE_DIR/$brk-$s.log" 2>&1 || { echo "caught-by:$s"; exit 0; }
    done
    echo "not-caught"
  )"
  assert_match "^caught-by:$(printf '%s' "${!#}")\$" "$out" "the seeded defect '$brk' fails the step meant to catch it ($out)"
}

t_z_dry_run_catches_every_seeded_defect() {
  dr_catches admin-open       il_before il_upgrade
  dr_catches image-mismatch   il_before il_upgrade
  dr_catches listen-all       il_before il_upgrade
  dr_catches sudoers-extra    il_before il_upgrade
  dr_catches public-sample    il_before il_upgrade
  dr_catches marker-lost      il_before il_upgrade il_state
  dr_catches volume-left      il_before il_upgrade il_state il_uninstall
  dr_catches dns-not-restored il_before il_upgrade il_state il_uninstall
}

# ── The gate flow (plan installers, --matrix all; user decisions 2026-09-28) ──
# dr_gate_flow <defect|none>: in a fresh fake, a representative run R1 (the
# cells to reuse), then with <defect> seeded the gate run R2: the lifecycle on
# each platform's other proxy (a switch) with R1's cells reused, the hardened
# entrypoints, and the installers receipt, linked to this host's newest real
# controller receipt. Prints caught-by:<step> or passed.
dr_gate_flow() {
  local brk="$1" base="$CASE_DIR/gate-$1" real_root
  real_root="$(dirname "$(dirname "$DR_RUN_DIR")")"
  (
    R1=20260101T000100Z-0000000a R2=20260101T000200Z-0000000b
    IL_FAKE_DIR="$base/fake" NICE_DNS_IR_CONTROLLER_ROOT="$real_root"
    IL_FAKE_BUNDLE="$( . "$NICE_DNS_ROOT/tests/live/installers-receipt.sh"; ir_expected_bundle HEAD )"
    export IL_FAKE_DIR NICE_DNS_IR_CONTROLLER_ROOT IL_FAKE_BUNDLE
    mkdir -p "$IL_FAKE_DIR"
    rows() { local g="$1" c; shift; for c in "$@"; do printf '%s\tfile\t%s\tpass\n' "$g" "$c"; done >>"$ARTIFACT_DIR/results.tsv"; }
    ARTIFACT_DIR="$base/root/runs/$R1" RUN_ID="$R1"; export ARTIFACT_DIR RUN_ID
    mkdir -p "$ARTIFACT_DIR"
    for s in il_before il_upgrade il_state il_uninstall il_final; do
      ( il_each "$s" ) >"$base-r1-$s.log" 2>&1 || { echo "setup-failed:$s"; exit 0; }
    done
    rows live/install-lifecycle t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private
    # A run that did not pass every case is never reused.
    [ "$brk" = reuse-run-failed ] && sed -i '3s/pass$/fail/' "$ARTIFACT_DIR/results.tsv"
    case "$brk" in none|reuse-run-failed) ;; *) printf '%s\n' "$brk" >"$IL_FAKE_DIR/break" ;; esac
    ARTIFACT_DIR="$base/root/runs/$R2" RUN_ID="$R2" NICE_DNS_OPT_MATRIX=all NICE_DNS_CELL_REUSE_RUNS="$base/root/runs/$R1"
    export ARTIFACT_DIR RUN_ID NICE_DNS_OPT_MATRIX NICE_DNS_CELL_REUSE_RUNS
    mkdir -p "$ARTIFACT_DIR"
    for s in il_before il_upgrade il_state il_uninstall il_final; do
      ( il_each "$s" ) >"$base-r2-$s.log" 2>&1 || { echo "caught-by:$s"; exit 0; }
    done
    rows live/install-lifecycle t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private
    ( . "$NICE_DNS_ROOT/tests/live/install-hardened.sh"; il_each il_hardened ) >"$base-r2-hardened.log" 2>&1 || { echo "caught-by:il_hardened"; exit 0; }
    rows live/install-hardened t_1_hardened_entrypoints t_2_evidence_is_private
    mkdir -p "$ARTIFACT_DIR/cases/integration-installers-interaction/t_bootstrap_use_is_declared"
    echo "dry run: stands in for the inventory check's log" >"$ARTIFACT_DIR/cases/integration-installers-interaction/t_bootstrap_use_is_declared/case.log"
    rows integration/installers-interaction t_bootstrap_use_is_declared
    [ "$brk" = step-missing ] && sed -i '/^il_state$/d' "$ARTIFACT_DIR/install-lifecycle/lin1/passed.tsv"
    ( CASE_DIR="$base/receipt-case"; mkdir -p "$CASE_DIR"; . "$NICE_DNS_ROOT/tests/live/installers-receipt.sh"; ir_receipt ) >"$base-r2-receipt.log" 2>&1 || { echo "caught-by:ir_receipt"; exit 0; }
    echo passed
  )
}

t_y_gate_flow_switches_reuses_and_writes_a_verified_receipt() {
  local out r
  out="$(dr_gate_flow none)"
  assert_eq passed "$out" "the clean gate flow passes ($(tail -n 15 "$CASE_DIR"/gate-none-r2-*.log 2>/dev/null | tail -n 15))"
  r="$CASE_DIR/gate-none/root/runs/20260101T000200Z-0000000b/install-lifecycle"
  assert_eq socat "$(awk -F '\t' '$1 == "proxy" { print $2 }' "$r/lin1/cell.tsv")" "linux ran its other proxy (a switch from haproxy)"
  assert_eq haproxy "$(awk -F '\t' '$1 == "proxy" { print $2 }' "$r/mac1/cell.tsv")" "macOS ran its other proxy (a switch from socat)"
  assert_match '^linux/haproxy/standard	/' "$(cat "$r/reused-linux.tsv")" "linux's haproxy cell was reused from R1"
  assert_match '^macos/socat/standard	/' "$(cat "$r/reused-macos.tsv")" "macOS's socat cell was reused from R1"
  r="$CASE_DIR/gate-none/root/receipts/installers/20260101T000200Z-0000000b/receipt.tsv"
  assert_file "$r" "the receipt was written"
  assert_eq 4 "$(awk -F '\t' '$1 == "cell" && $7 == "observed"' "$r" | grep -c .)" "four observed standard cells"
  assert_eq 2 "$(awk -F '\t' '$1 == "reuse"' "$r" | grep -c .)" "two of them reused"
  assert_eq 4 "$(awk -F '\t' '$1 == "entrypoint" && $3 == "pass"' "$r" | grep -c .)" "all four entrypoints pass"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" --require-dep controller --require-entrypoints all --require-platform-proxies all >/dev/null 2>&1
  assert_rc 0 "$?" "and it verifies as the master gate asks"
}

t_z_gate_flow_catches_every_seeded_defect() {
  local b w out
  for b in reuse-run-failed:il_before old-proxy-left:il_upgrade hardened-standard:il_hardened bundle-mismatch:ir_receipt step-missing:ir_receipt; do
    w="${b#*:}"; b="${b%%:*}"
    out="$(dr_gate_flow "$b")"
    assert_eq "caught-by:$w" "$out" "the seeded defect '$b' fails $w"
  done
}

# A rerun after a passed gate run: every cell and entrypoint is reused, both
# platforms are skipped, and the receipt still verifies (DEC-009).
t_y_rerun_skips_what_is_proven() {
  local base="$CASE_DIR/gate-none" out r
  out="$(dr_gate_flow none)"
  assert_eq passed "$out" "the first gate flow passes"
  out="$(
    R1=20260101T000100Z-0000000a R2=20260101T000200Z-0000000b R3=20260101T000300Z-0000000c
    IL_FAKE_DIR="$base/fake" NICE_DNS_IR_CONTROLLER_ROOT="$(dirname "$(dirname "$DR_RUN_DIR")")"
    IL_FAKE_BUNDLE="$( . "$NICE_DNS_ROOT/tests/live/installers-receipt.sh"; ir_expected_bundle HEAD )"
    ARTIFACT_DIR="$base/root/runs/$R3" RUN_ID="$R3" NICE_DNS_OPT_MATRIX=all
    NICE_DNS_CELL_REUSE_RUNS="$base/root/runs/$R1 $base/root/runs/$R2"
    export IL_FAKE_DIR NICE_DNS_IR_CONTROLLER_ROOT IL_FAKE_BUNDLE ARTIFACT_DIR RUN_ID NICE_DNS_OPT_MATRIX NICE_DNS_CELL_REUSE_RUNS
    mkdir -p "$ARTIFACT_DIR"
    for s in il_before il_upgrade il_state il_uninstall il_final; do
      ( il_each "$s" ) >"$base-r3-$s.log" 2>&1 || { echo "failed:$s"; exit 0; }
    done
    for c in t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private; do
      printf 'live/install-lifecycle\tfile\t%s\tpass\n' "$c"; done >>"$ARTIFACT_DIR/results.tsv"
    ( . "$NICE_DNS_ROOT/tests/live/install-hardened.sh"; il_each il_hardened ) >"$base-r3-hardened.log" 2>&1 || { echo "failed:il_hardened"; exit 0; }
    printf 'live/install-hardened\tfile\tt_1_hardened_entrypoints\tpass\n' >>"$ARTIFACT_DIR/results.tsv"
    mkdir -p "$ARTIFACT_DIR/cases/integration-installers-interaction/t_bootstrap_use_is_declared"
    echo "dry run" >"$ARTIFACT_DIR/cases/integration-installers-interaction/t_bootstrap_use_is_declared/case.log"
    printf 'integration/installers-interaction\tfile\tt_bootstrap_use_is_declared\tpass\n' >>"$ARTIFACT_DIR/results.tsv"
    ( CASE_DIR="$base/receipt-case-r3"; mkdir -p "$CASE_DIR"; . "$NICE_DNS_ROOT/tests/live/installers-receipt.sh"; ir_receipt ) >"$base-r3-receipt.log" 2>&1 || { echo "failed:ir_receipt"; exit 0; }
    echo passed
  )"
  assert_eq passed "$out" "the rerun passes ($(tail -n 8 "$base"-r3-*.log 2>/dev/null | tail -n 8))"
  r="$base/root/runs/20260101T000300Z-0000000c"
  assert_file "$r/install-lifecycle/lin1/skip" "linux was skipped"
  assert_file "$r/install-lifecycle/mac1/skip" "macOS was skipped"
  assert_file "$r/install-hardened/lin1/reused.tsv" "the linux hardened entrypoint was reused"
  assert_no_path "$r/install-hardened/lin1/after-hardened.tsv" "and not run again"
  r="$base/root/receipts/installers/20260101T000300Z-0000000c/receipt.tsv"
  assert_eq 4 "$(awk -F '\t' '$1 == "reuse"' "$r" | grep -c .)" "all four cells are reuse rows"
}

# The reuse rule (il_same_product): a cell proven at an earlier commit is
# reused only when nothing it installs changed since. Live 2026-09-28: the
# first single-cell run refused Task 2.3's cell because a docs commit came
# after it; the fakes always ran at HEAD and could not see that.
t_x_reuse_rule_ignores_docs_not_product() {
  local c="$CASE_DIR/clone" base docs prod
  git clone -q --no-hardlinks "$NICE_DNS_ROOT" "$c" || fail "clone"
  git -C "$c" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  base="$(git -C "$c" rev-parse HEAD)"
  printf '\nnote\n' >>"$c/docs/workflows/dns-lifecycle.md"; printf 'note\n' >>"$c/README.md"; printf '# t\n' >>"$c/tests/run.sh"
  git -C "$c" -c user.name=t -c user.email=t@t commit -qam docs
  docs="$(git -C "$c" rev-parse HEAD)"
  ( NICE_DNS_ROOT="$c"; il_same_product "$base" linux && il_same_product "$base" macos )
  assert_rc 0 "$?" "a docs, Markdown and tests change keeps the product the same"
  printf '# t\n' >>"$c/mac/start-container-root.sh"
  git -C "$c" -c user.name=t -c user.email=t@t commit -qam mac
  ( NICE_DNS_ROOT="$c"; il_same_product "$docs" linux )
  assert_rc 0 "$?" "a mac/ change keeps the Linux product the same"
  ( NICE_DNS_ROOT="$c"; il_same_product "$docs" macos )
  assert_rc 1 "$?" "but not the macOS one"
  printf '# t\n' >>"$c/lib/install.sh"
  git -C "$c" -c user.name=t -c user.email=t@t commit -qam product
  prod="$(git -C "$c" rev-parse HEAD)"
  ( NICE_DNS_ROOT="$c"; il_same_product "$docs" linux )
  assert_rc 1 "$?" "a change to lib/install.sh is a different product"
  ( NICE_DNS_ROOT="$c"; il_same_product "$prod" macos )
  assert_rc 0 "$?" "HEAD is the same product as itself"
}

# live/install-hardened on its own run (live 2026-09-28: it took no snapshot,
# and target.sh refuses a change without one in the same run).
t_x_hardened_group_runs_alone() {
  local out
  out="$(
    IL_FAKE_DIR="$CASE_DIR/fake"; export IL_FAKE_DIR; mkdir -p "$IL_FAKE_DIR"
    ARTIFACT_DIR="$CASE_DIR/r1" RUN_ID=20260101T000100Z-0000000a; export ARTIFACT_DIR RUN_ID; mkdir -p "$ARTIFACT_DIR"
    for s in il_before il_upgrade; do ( il_each "$s" ) >"$CASE_DIR/r1-$s.log" 2>&1 || { echo "setup-failed:$s"; exit 0; }; done
    ARTIFACT_DIR="$CASE_DIR/r2" RUN_ID=20260101T000200Z-0000000b; export ARTIFACT_DIR RUN_ID; mkdir -p "$ARTIFACT_DIR"
    ( . "$NICE_DNS_ROOT/tests/live/install-hardened.sh"; il_each il_hardened ) >"$CASE_DIR/r2-hardened.log" 2>&1 || { echo failed; exit 0; }
    echo passed
  )"
  assert_eq passed "$out" "the hardened group passes on a run of its own ($(tail -n 6 "$CASE_DIR/r2-hardened.log" 2>/dev/null))"
}
