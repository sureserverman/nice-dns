# shellcheck shell=bash
# Group integration/command-recovery-dryrun (Task 3.1). The dry run the
# live-gates rule asks for before live/command-recovery touches a target: the
# live group's own steps run against tests/fixtures/command-recovery-adapter.sh
# and pass on a well-behaved fake; each defect the live checks exist for is
# then seeded and the step meant to catch it must fail. Nothing touches a host.

CR_DRY_RUN_DIR="$ARTIFACT_DIR"
ARTIFACT_DIR="$CR_DRY_RUN_DIR/dryrun"
mkdir -p "$ARTIFACT_DIR"
NICE_DNS_TARGET_ADAPTER="$NICE_DNS_ROOT/tests/fixtures/command-recovery-adapter.sh"
NICE_DNS_IL_DRY_RUN=1
NICE_DNS_OPT_TARGETS=fake-targets.env
NICE_DNS_OPT_VARIANTS=representative
NICE_DNS_OPT_PLATFORMS=all
NICE_DNS_OPT_MATRIX=""
unset NICE_DNS_CELL_REUSE_RUNS
CR_POLL=0 CR_RECOVER_MAX=1 CR_SETTLE_MAX=1 CR_QUIET=0
export CR_POLL CR_RECOVER_MAX CR_SETTLE_MAX CR_QUIET ARTIFACT_DIR NICE_DNS_OPT_MATRIX NICE_DNS_TARGET_ADAPTER NICE_DNS_IL_DRY_RUN NICE_DNS_OPT_TARGETS NICE_DNS_OPT_VARIANTS NICE_DNS_OPT_PLATFORMS

# shellcheck source=tests/live/command-recovery.sh
. "$NICE_DNS_ROOT/tests/live/command-recovery.sh"
unset -f t_01_before t_02_install t_03_fault_unbound t_04_fault_proxy t_05_restart t_06_reinstall t_07_uninstall t_08_final t_09_privacy t_10_receipt

# crd_world <dir>: a fresh fake and run directory, for the current subshell.
crd_world() {
  ARTIFACT_DIR="$1/runs/20260101T000100Z-0000000a" RUN_ID=20260101T000100Z-0000000a IL_FAKE_DIR="$1/fake"
  export ARTIFACT_DIR RUN_ID IL_FAKE_DIR
  mkdir -p "$ARTIFACT_DIR" "$IL_FAKE_DIR"
}

# crd_catches <defect> <step...>: with <defect> seeded the steps run in order
# and exactly the last one fails.
crd_catches() {
  local brk="$1" s out
  shift
  out="$(
    crd_world "$CASE_DIR/$brk"
    printf '%s\n' "$brk" >"$IL_FAKE_DIR/break"
    for s in "$@"; do
      ( il_each "$s" ) >"$CASE_DIR/$brk-$s.log" 2>&1 || { echo "caught-by:$s"; exit 0; }
    done
    echo not-caught
  )"
  assert_eq "caught-by:${!#}" "$out" "the seeded defect '$brk' fails the step meant to catch it"
}

t_dry_run_prints_every_step_in_order_and_touches_nothing() {
  local out steps
  out="$(env -i PATH="$PATH" bash "$NICE_DNS_ROOT/tests/live/command-recovery.sh" --dry-run)"
  assert_rc 0 "$?" "the dry run exits 0"
  steps="$(printf '%s\n' "$out" | awk '/^cr_/ { print $1 }' | tr '\n' ' ')"
  assert_eq "$CR_STEPS cr_privacy cr_receipt " "$steps" "it prints the steps the group runs, in order"
  assert_eq "cr_before cr_install cr_fault_unbound cr_fault_proxy cr_restart cr_reinstall cr_uninstall cr_final " \
    "$(sed -n 's/^t_0[0-9]_[a-z_]*() { il_selection; il_each \(cr_[a-z_]*\); }$/\1/p' "$NICE_DNS_ROOT/tests/live/command-recovery.sh" | tr '\n' ' ')" \
    "and the group's cases run those steps in that order"
  assert_nonzero "$(bash "$NICE_DNS_ROOT/tests/live/command-recovery.sh" 2>/dev/null; echo $?)" "without --dry-run the file refuses to run alone"
}

t_a_well_behaved_target_passes_and_its_receipt_verifies() {
  local s out r
  out="$(
    crd_world "$CASE_DIR/good"
    for s in $CR_STEPS; do
      ( il_each "$s" ) >"$CASE_DIR/good-$s.log" 2>&1 || { echo "failed:$s"; cat "$CASE_DIR/good-$s.log"; exit 0; }
    done
    ( cr_receipt ) >"$CASE_DIR/good-receipt.log" 2>&1 || { echo failed:receipt; cat "$CASE_DIR/good-receipt.log"; exit 0; }
    echo passed
  )"
  assert_eq passed "$out" "every step and the receipt pass on a well-behaved fake"
  r="$(for r in "$CASE_DIR"/good/receipts/command-recovery/*/receipt.tsv; do printf '%s\n' "$r"; done | tail -1)"
  assert_file "$r" "the receipt exists"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" >/dev/null 2>&1
  assert_rc 0 "$?" "the receipt verifies on its own"
  assert_match '^limit	mac-gui-context	-	scope=BL-052	' "$(grep -m1 'GUI context' "$r")" "the receipt says how the Mac commands ran"
  assert_match 'limits=3' "$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" 2>&1)" "and the verifier counts its limits"
}

t_each_seeded_defect_is_caught() {
  local before_faults='cr_before cr_install'
  # shellcheck disable=SC2086 # one word per step
  {
    crd_catches no-ready $before_faults cr_fault_unbound
    crd_catches no-ack $before_faults cr_fault_unbound
    crd_catches not-felt $before_faults cr_fault_unbound
    crd_catches probe-broken $before_faults cr_fault_unbound
    crd_catches gen-unchanged $before_faults cr_fault_unbound
    crd_catches servfail $before_faults cr_fault_unbound
    crd_catches restart-partial $before_faults cr_fault_unbound cr_fault_proxy cr_restart
    crd_catches secret-changed $before_faults cr_fault_unbound cr_fault_proxy cr_restart cr_reinstall
    crd_catches monitor-left $before_faults cr_fault_unbound cr_fault_proxy cr_restart cr_reinstall cr_uninstall
    crd_catches command-left $before_faults cr_fault_unbound cr_fault_proxy cr_restart cr_reinstall cr_uninstall
    crd_catches source-left $before_faults cr_fault_unbound cr_fault_proxy cr_restart cr_reinstall cr_uninstall
    crd_catches image-left $before_faults cr_fault_unbound cr_fault_proxy cr_restart cr_reinstall cr_uninstall
    crd_catches images-empty $before_faults cr_fault_unbound cr_fault_proxy cr_restart cr_reinstall cr_uninstall
    crd_catches sbin-left $before_faults cr_fault_unbound cr_fault_proxy cr_restart cr_reinstall cr_uninstall
    crd_catches digest-left $before_faults cr_fault_unbound cr_fault_proxy cr_restart cr_reinstall cr_uninstall
    crd_catches quadlet-left $before_faults cr_fault_unbound cr_fault_proxy cr_restart cr_reinstall cr_uninstall
    crd_catches unit-left $before_faults cr_fault_unbound cr_fault_proxy cr_restart cr_reinstall cr_uninstall
  }
}

# Past the plan's ten minutes a recovery does not count, however it ended.
t_a_slow_recovery_fails() {
  local out
  out="$(
    crd_world "$CASE_DIR/slow"
    CR_ELAPSED_MAX=-1; export CR_ELAPSED_MAX
    for s in cr_before cr_install; do ( il_each "$s" ) >/dev/null 2>&1 || { echo "setup-failed:$s"; exit 0; }; done
    ( il_each cr_fault_unbound ) >"$CASE_DIR/slow.log" 2>&1 && { echo passed; exit 0; }
    echo caught
  )"
  assert_eq caught "$out" "a recovery past the limit fails"
}

# The receipt itself refuses evidence that says the job was not done, whatever
# the step printed last.
t_the_receipt_checks_the_evidence_not_the_verdict() {
  local d r f row t h s
  (
    crd_world "$CASE_DIR/forged"
    for s in $CR_STEPS; do ( il_each "$s" ) >/dev/null 2>&1 || exit 1; done
    ( cr_receipt ) >"$CASE_DIR/forged.log" 2>&1 || exit 1
  ) || fail "setup: $(tail -n 5 "$CASE_DIR/forged.log" 2>/dev/null)"
  r="$(for r in "$CASE_DIR"/forged/receipts/command-recovery/*/receipt.tsv; do printf '%s\n' "$r"; done | tail -1)"
  d="$(dirname "$r")"
  # file<TAB>sed: one edit each; the sha256 is fixed up, so only content can fail.
  while IFS='|' read -r f row; do
    cp -R "$d" "$d.m"
    for t in "$d.m"/cells/*/"$f"; do
      sed -i "$row" "$t"
      h="$(sha256sum "$t" | cut -d' ' -f1)"
      awk -F '\t' -v OFS='\t' -v f="${t#"$d.m"/}" -v h="$h" '$1 == "scenario" && $5 == f { $6 = h } { print }' "$d.m/receipt.tsv" >"$d.m/r" && mv "$d.m/r" "$d.m/receipt.tsv"
    done
    bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$d.m/receipt.tsv" >/dev/null 2>&1
    assert_nonzero "$?" "$f with [$row] does not verify"
    rm -rf "$d.m"
  done <<'EOF'
cmd-uninstall.tsv|s/^command\tabsent$/command\tpresent/
cmd-uninstall.tsv|s/^images_left\t0$/images_left\t1/
cmd-uninstall.tsv|s/^sbin_left\t0$/sbin_left\t1/
cmd-uninstall.tsv|s/^stack_images_before\t.*/stack_images_before\t0/
cmd-uninstall.tsv|s/^listing\timages\t0$/listing\timages\t1/
cmd-reinstall.tsv|s/^admin_secret\tkept$/admin_secret\tlost/
cmd-restart.tsv|s/^all_new_start\tyes$/all_new_start\tno/
cmd-install.tsv|s/^over_running_stack\tyes$/over_running_stack\tno/
fault-unbound.tsv|s/^elapsed_s\t.*/elapsed_s\t900/
fault-proxy.tsv|s/^fresh_during_fault\t.*/fresh_during_fault\tNOERROR/
EOF
}

# What the tuning harness leaves on a target is not a defect of the uninstall.
t_harness_images_do_not_fail_the_uninstall() {
  local s out
  out="$(
    crd_world "$CASE_DIR/harness"
    printf 'harness-tags\n' >"$IL_FAKE_DIR/break"
    for s in $CR_STEPS; do ( il_each "$s" ) >"$CASE_DIR/harness-$s.log" 2>&1 || { echo "failed:$s"; exit 0; }; done
    echo passed
  )"
  assert_eq passed "$out" "a versioned proxy tag left behind passes"
}

# A failed platform runs no more of the scenario, but still ends on a stack.
t_a_failed_step_stops_the_platform_and_the_final_install_still_runs() {
  local out
  out="$(
    crd_world "$CASE_DIR/stop"
    printf 'no-ready\n' >"$IL_FAKE_DIR/break"
    for s in cr_before cr_install cr_fault_unbound; do ( il_each "$s" ) >/dev/null 2>&1; done
    ( il_each cr_fault_proxy ) >"$CASE_DIR/stop.log" 2>&1 && { echo proxy-fault-ran; exit 0; }
    ( il_each cr_final ) >"$CASE_DIR/final.log" 2>&1 || { echo final-failed; exit 0; }
    echo stopped
  )"
  assert_eq stopped "$out" "the later fault did not run and the final install did ($(tail -n 3 "$CASE_DIR/stop.log" 2>/dev/null))"
}

# A rerun of one platform carries the other's passed cell into the receipt.
t_a_passed_cell_is_reused_on_a_rerun() {
  local out r first
  out="$(
    crd_world "$CASE_DIR/reuse"
    for s in $CR_STEPS; do ( il_each "$s" ) >/dev/null 2>&1 || { echo "first-run-failed:$s"; exit 0; }; done
    first="$ARTIFACT_DIR"
    ARTIFACT_DIR="$CASE_DIR/reuse/runs/20260101T000200Z-0000000b" RUN_ID=20260101T000200Z-0000000b
    NICE_DNS_OPT_PLATFORMS=macos NICE_DNS_CELL_REUSE_RUNS="$first"
    export ARTIFACT_DIR RUN_ID NICE_DNS_OPT_PLATFORMS NICE_DNS_CELL_REUSE_RUNS
    mkdir -p "$ARTIFACT_DIR"
    for s in $CR_STEPS; do ( il_each "$s" ) >/dev/null 2>&1 || { echo "second-run-failed:$s"; exit 0; }; done
    ( cr_receipt ) >"$CASE_DIR/reuse.log" 2>&1 || { echo receipt-failed; cat "$CASE_DIR/reuse.log"; exit 0; }
    echo passed
  )"
  assert_eq passed "$out" "the rerun's receipt verifies"
  r="$CASE_DIR/reuse/receipts/command-recovery/20260101T000200Z-0000000b/receipt.tsv"
  assert_match '^reuse	linux/' "$(grep '^reuse' "$r")" "and names the reused Linux cell"
}

# The real adapter's new operations: refused before anything is sent.
t_target_guards_cover_the_new_operations() {
  local tg="$NICE_DNS_ROOT/tests/live/target.sh" f="$CASE_DIR/targets.env" out
  printf 'lin1\tlinux\tnd-no-such-host.invalid\tSHA256:%s\tdisposable\t2026-01-01\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA >"$f"
  chmod 600 "$f"
  out="$(bash "$tg" command lin1 --targets "$f" --mode nonsense 2>&1)"
  assert_rc 2 "$?" "a bad mode is refused: $out"
  out="$(bash "$tg" command lin1 --targets "$f" --mode install 2>&1)"
  assert_rc 2 "$?" "install without its cell and commit is refused: $out"
  out="$(bash "$tg" command lin1 --targets "$f" --mode restart --cell haproxy/standard 2>&1)"
  assert_rc 2 "$?" "a cell on restart is refused: $out"
  out="$(bash "$tg" stop-proxy lin1 --targets "$f" --component unbound 2>&1)"
  assert_rc 2 "$?" "only a proxy can be stopped: $out"
  out="$(ARTIFACT_DIR="$CASE_DIR/guards" bash "$tg" freeze-unbound lin1 --targets "$f" 2>&1)"
  assert_rc 2 "$?" "a freeze needs the run's snapshot: $out"
  assert_match 'no restore snapshot' "$out" "and says so"
}
