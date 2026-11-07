# shellcheck shell=bash
# Group integration/bridges-toggle-dryrun (bridges-toggle plan, Task 2.1). The
# dry run the live-gates rule asks for before live/bridges-toggle touches a
# target: the live group's own steps run against
# tests/fixtures/bridges-toggle-adapter.sh and pass on a well-behaved fake;
# each defect the live checks exist for is then seeded and the step meant to
# catch it must fail. Nothing touches a host.

BT_DRY_RUN_DIR="$ARTIFACT_DIR"
ARTIFACT_DIR="$BT_DRY_RUN_DIR/dryrun"
mkdir -p "$ARTIFACT_DIR"
NICE_DNS_TARGET_ADAPTER="$NICE_DNS_ROOT/tests/fixtures/bridges-toggle-adapter.sh"
NICE_DNS_IL_DRY_RUN=1
NICE_DNS_OPT_TARGETS=fake-targets.env
NICE_DNS_OPT_VARIANTS=representative
NICE_DNS_OPT_PLATFORMS=all
NICE_DNS_OPT_MATRIX=""
unset NICE_DNS_CELL_REUSE_RUNS
CR_POLL=0 CR_RECOVER_MAX=1 CR_SETTLE_MAX=1 CR_QUIET=0
BT_FRESH_MAX=1 BT_LINE_MAX=0
export CR_POLL CR_RECOVER_MAX CR_SETTLE_MAX CR_QUIET BT_FRESH_MAX BT_LINE_MAX ARTIFACT_DIR NICE_DNS_OPT_MATRIX NICE_DNS_TARGET_ADAPTER NICE_DNS_IL_DRY_RUN NICE_DNS_OPT_TARGETS NICE_DNS_OPT_VARIANTS NICE_DNS_OPT_PLATFORMS

# shellcheck source=tests/live/bridges-toggle.sh
. "$NICE_DNS_ROOT/tests/live/bridges-toggle.sh"
unset -f t_01_before t_02_install t_03_off t_04_refresh t_05_status_off t_06_on t_07_status_on t_08_after t_09_privacy t_10_receipt

BTD_LIVE="$NICE_DNS_ROOT/tests/live/bridges-toggle.sh"

# btd_world <dir>: a fresh fake and run directory, for the current subshell.
btd_world() {
  ARTIFACT_DIR="$1/runs/20260101T000100Z-0000000a" RUN_ID=20260101T000100Z-0000000a IL_FAKE_DIR="$1/fake"
  export ARTIFACT_DIR RUN_ID IL_FAKE_DIR
  mkdir -p "$ARTIFACT_DIR" "$IL_FAKE_DIR"
  bt_budget_start
}

# btd_catches <defect> <step...>: with <defect> seeded the steps run in order
# and exactly the last one fails.
btd_catches() {
  local brk="$1" s out
  shift
  out="$(
    btd_world "$CASE_DIR/$brk"
    printf '%s\n' "$brk" >"$IL_FAKE_DIR/break"
    for s in "$@"; do
      ( il_each "$s" ) >"$CASE_DIR/$brk-$s.log" 2>&1 || { echo "caught-by:$s"; exit 0; }
    done
    echo not-caught
  )"
  assert_eq "caught-by:${!#}" "$out" "the seeded defect '$brk' fails the step meant to catch it"
}

t_dry_run_prints_every_step_for_both_platforms_and_touches_nothing() {
  local out p t bin="$CASE_DIR/bin"
  mkdir -p "$bin"
  # Anything that could reach a target records itself and fails.
  for t in ssh scp podman container launchctl; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/touched"\nexit 1\n' "$t" "$CASE_DIR" >"$bin/$t"
    chmod 755 "$bin/$t"
  done
  out="$(env -i PATH="$bin:$PATH" HOME="$CASE_DIR" bash "$BTD_LIVE" --dry-run)"
  assert_rc 0 "$?" "the dry run exits 0"
  assert_no_path "$CASE_DIR/touched" "it runs no ssh, podman, container or launchctl"
  assert_match '^dry run: no target is touched$' "$out" "it says so"
  for p in linux macos; do
    assert_eq "$BT_STEPS " "$(printf '%s\n' "$out" | awk -v p="$p" '$1 == p { print $2 }' | tr '\n' ' ')" "$p: every step, in order"
  done
  assert_eq "bt_privacy bt_receipt " "$(printf '%s\n' "$out" | awk '$1 == "all" { print $2 }' | tr '\n' ' ')" "then the privacy check and the receipt"
  assert_match '^macos +bt_install .*quiesce-agents.*install-cell.*gui session.*resume-agents.*never moved \(OD-8\)' "$out" \
    "the mac install runs in the gui session, always resumes the agents and never moves the runtime (OD-8)"
  assert_not_match '^macos .*mac-runtime' "$out" "no runtime move on the mac"
  assert_not_match '^linux .*mac-runtime' "$out" "Linux does not"
  for t in 'bridges off' 'direct \(no bridges\)' 'bridges-refresh' 'bridges	mode	off|bridges<TAB>mode<TAB>off' 'bridges on' 'with N bridge\(s\)' '600 s'; do
    assert_match "$t" "$out" "the plan names [$t]"
  done
  assert_eq "$BT_STEPS " \
    "$(sed -n 's/^t_[0-9][0-9]_[a-z_]*() { il_selection; il_each \(bt_[a-z_]*\); }$/\1/p' "$BTD_LIVE" | tr '\n' ' ')" \
    "and the group's cases run those steps in that order"
  assert_nonzero "$(bash "$BTD_LIVE" 2>/dev/null; echo $?)" "without --dry-run the file refuses to run alone"
}

# Without --live --targets the group refuses before it touches anything.
t_the_group_refuses_without_targets() {
  local out
  out="$(
    btd_world "$CASE_DIR/notargets"
    unset NICE_DNS_OPT_TARGETS
    ( il_selection && il_each bt_before ) >"$CASE_DIR/sel.log" 2>&1 && { echo ran; exit 0; }
    echo refused
  )"
  assert_eq refused "$out" "no --targets: refused ($(cat "$CASE_DIR/sel.log" 2>/dev/null))"
  assert_match '--targets FILE' "$(cat "$CASE_DIR/sel.log")" "the refusal names --targets"
  assert_no_path "$CASE_DIR/notargets/fake/lin1" "no fake target was touched"
}

t_a_well_behaved_target_passes_and_its_receipt_verifies() {
  local s out r
  out="$(
    btd_world "$CASE_DIR/good"
    for s in $BT_STEPS; do
      ( il_each "$s" ) >"$CASE_DIR/good-$s.log" 2>&1 || { echo "failed:$s"; cat "$CASE_DIR/good-$s.log"; exit 0; }
    done
    ( bt_receipt ) >"$CASE_DIR/good-receipt.log" 2>&1 || { echo failed:receipt; cat "$CASE_DIR/good-receipt.log"; exit 0; }
    echo passed
  )"
  assert_eq passed "$out" "every step and the receipt pass on a well-behaved fake"
  r="$(for r in "$CASE_DIR"/good/receipts/bridges-toggle/*/receipt.tsv; do printf '%s\n' "$r"; done | tail -1)"
  assert_file "$r" "the receipt exists"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" >/dev/null 2>&1
  assert_rc 0 "$?" "the receipt verifies on its own"
  for s in linux macos; do
    assert_eq "BT-OFF BT-ON BT-REFRESH BT-STATUS-OFF BT-STATUS-ON " \
      "$(awk -F '\t' -v p="$s" '$1 == "scenario" && index($3, p "/") == 1 { print $2 }' "$r" | sort | tr '\n' ' ')" "$s carries every scenario"
  done
  assert_match '^limit	mac-runtime-domain	.*gui session' "$(cat "$r")" "the receipt names the gui-session install as a limit (BL-052)"
  # The evidence: both switches with exit, last line and one request id
  # carrying mode-change and acknowledged; both supervisor lines; both names.
  s="$(cat "$CASE_DIR"/good/receipts/bridges-toggle/*/cells/macos-*/switch-off.tsv)"
  assert_match '^cli_exit	0$' "$s" "the off switch exited 0"
  assert_match '^cli_last	Bridges are off; the proxy restarted and DNS is answering\.$' "$s" "and its last line"
  assert_match '^supervisor	tor-[a-z]+	tor-supervisor: spawned tor pid=[0-9]+ generation=[0-9]+ direct \(no bridges\)$' "$s" "the direct launch"
  assert_match '^elapsed_s	[0-9]+$' "$s" "the elapsed seconds"
  s="$(cat "$CASE_DIR"/good/receipts/bridges-toggle/*/cells/linux-*/switch-on.tsv)"
  assert_match '^supervisor	tor-[a-z]+	tor-supervisor: spawned tor pid=[0-9]+ generation=[0-9]+ with [0-9]+ bridge\(s\)$' "$s" "the launch with bridges"
}

t_the_mac_install_never_moves_the_runtime_and_always_resumes() {
  local out
  out="$(
    btd_world "$CASE_DIR/order"
    for s in bt_before bt_install; do ( il_each "$s" ) >"$CASE_DIR/order-$s.log" 2>&1 || { echo "failed:$s"; cat "$CASE_DIR/order-$s.log"; exit 0; }; done
    echo passed
  )"
  assert_eq passed "$out" "the install passes on both platforms"
  assert_eq "quiesce-agents install-cell resume-agents " \
    "$(grep -E '^(quiesce-agents|mac-runtime-ssh|install-cell|mac-runtime-gui|resume-agents)$' "$CASE_DIR/order/fake/mac1/oplog" | tr '\n' ' ')" \
    "macOS: quiesce, install, resume; the runtime is never moved"
  assert_eq "install-cell " "$(grep -E '^(quiesce-agents|mac-runtime-ssh|install-cell|mac-runtime-gui|resume-agents)$' "$CASE_DIR/order/fake/lin1/oplog" | tr '\n' ' ')" \
    "Linux: the install alone"
  # A failed install still resumes the agents.
  out="$(
    btd_world "$CASE_DIR/failed-install"
    printf 'install-fails\n' >"$IL_FAKE_DIR/break"
    ( il_each bt_before ) >/dev/null 2>&1 || { echo before-failed; exit 0; }
    ( il_each bt_install ) >"$CASE_DIR/failed-install.log" 2>&1 && { echo install-passed; exit 0; }
    echo failed
  )"
  assert_eq failed "$out" "a failed install fails the step"
  assert_eq "quiesce-agents install-cell resume-agents " \
    "$(grep -E '^(quiesce-agents|mac-runtime-ssh|install-cell|mac-runtime-gui|resume-agents)$' "$CASE_DIR/failed-install/fake/mac1/oplog" | tr '\n' ' ')" \
    "and the agents are resumed after it"
  assert_no_path "$CASE_DIR/failed-install/fake/mac1/domain" "the mac's runtime was never moved"
}

t_each_seeded_defect_is_caught() {
  local before='bt_before bt_install'
  # shellcheck disable=SC2086 # one word per step
  {
    btd_catches resume-fails bt_before bt_install
    btd_catches cli-fails $before bt_off
    btd_catches no-mode-change $before bt_off
    btd_catches no-ack $before bt_off
    btd_catches ack-other-id $before bt_off
    btd_catches still-bridges $before bt_off
    btd_catches leak $before bt_off
    btd_catches servfail $before bt_off
    btd_catches refresh-runs $before bt_off bt_refresh
    btd_catches refresh-fails $before bt_off bt_refresh
    btd_catches status-stale $before bt_off bt_refresh bt_status_off
    btd_catches still-direct $before bt_off bt_refresh bt_status_off bt_on
    btd_catches status-stuck-off $before bt_off bt_refresh bt_status_off bt_on bt_status_on
  }
}

# The receipt refuses evidence that says the job was not done.
t_the_receipt_checks_the_evidence_not_the_verdict() {
  local d r f row t h s
  (
    btd_world "$CASE_DIR/forged"
    for s in $BT_STEPS; do ( il_each "$s" ) >/dev/null 2>&1 || exit 1; done
    ( bt_receipt ) >"$CASE_DIR/forged.log" 2>&1 || exit 1
  ) || fail "setup: $(tail -n 5 "$CASE_DIR/forged.log" 2>/dev/null)"
  r="$(for r in "$CASE_DIR"/forged/receipts/bridges-toggle/*/receipt.tsv; do printf '%s\n' "$r"; done | tail -1)"
  d="$(dirname "$r")"
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
switch-off.tsv|s/^cli_exit\t0$/cli_exit\t1/
switch-off.tsv|/^cli_last\t/d
switch-off.tsv|/\tmode-change\t/d
switch-off.tsv|/\tservice\tacknowledged\t/d
switch-off.tsv|s/^\(journal\t[0-9]*\t\)bridges-off-\([0-9]*\)\(\tservice\tacknowledged\)/\1bridges-off-9\2\3/
switch-off.tsv|s/direct (no bridges)$/with 3 bridge(s)/
switch-off.tsv|/^fresh_name\t/d
switch-off.tsv|s/^elapsed_s\t.*/elapsed_s\t601/
switch-on.tsv|s/with [0-9]* bridge(s)$/direct (no bridges)/
switch-on.tsv|s/\(fresh_name\t[^\t]*\t\).*/\1SERVFAIL/
switch-on.tsv|s/^request_id\t.*/request_id\t-/
refresh-off.tsv|s/^refresh_exit\t0$/refresh_exit\t1/
refresh-off.tsv|s/\tskipped\tbridges off$/\tunchanged\tthe evaluated set equals the running one/
status-off.tsv|s/\tmode\toff$/\tmode\ton/
status-on.tsv|/\tmode\ton$/d
EOF
  # A cell without one of the switches.
  cp -R "$d" "$d.m"
  awk -F '\t' '!($1 == "scenario" && $2 == "BT-ON" && $3 ~ /^macos\//)' "$d.m/receipt.tsv" >"$d.m/r" && mv "$d.m/r" "$d.m/receipt.tsv"
  assert_match 'missing scenario BT-ON for cell macos/' "$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$d.m/receipt.tsv" 2>&1)" "a macOS cell without the on switch is refused"
  rm -rf "$d.m"
}

# A failed platform runs no more switch steps, but still ends with bridges on.
t_a_failed_step_stops_the_platform_and_the_after_step_still_runs() {
  local out
  out="$(
    btd_world "$CASE_DIR/stop"
    printf 'servfail-once\n' >"$IL_FAKE_DIR/break"
    for s in bt_before bt_install bt_off; do ( il_each "$s" ) >/dev/null 2>&1; done
    ( il_each bt_refresh ) >"$CASE_DIR/stop.log" 2>&1 && { echo refresh-ran; exit 0; }
    ( il_each bt_after ) >"$CASE_DIR/after.log" 2>&1 || { echo after-failed; cat "$CASE_DIR/after.log"; exit 0; }
    echo stopped
  )"
  assert_eq stopped "$out" "the later steps did not run and the after step did ($(tail -n 3 "$CASE_DIR/stop.log" 2>/dev/null))"
  assert_eq "on on" "$(cat "$CASE_DIR/stop/fake/lin1/mode") $(cat "$CASE_DIR/stop/fake/mac1/mode")" "both targets end with bridges on"
}

# A rerun of one platform carries the other's passed cell into the receipt.
t_a_passed_cell_is_reused_on_a_rerun() {
  local out r
  out="$(
    btd_world "$CASE_DIR/reuse"
    for s in $BT_STEPS; do ( il_each "$s" ) >/dev/null 2>&1 || { echo "first-run-failed:$s"; exit 0; }; done
    first="$ARTIFACT_DIR"
    ARTIFACT_DIR="$CASE_DIR/reuse/runs/20260101T000200Z-0000000b" RUN_ID=20260101T000200Z-0000000b
    NICE_DNS_OPT_PLATFORMS=macos NICE_DNS_CELL_REUSE_RUNS="$first"
    export ARTIFACT_DIR RUN_ID NICE_DNS_OPT_PLATFORMS NICE_DNS_CELL_REUSE_RUNS
    mkdir -p "$ARTIFACT_DIR"
    bt_budget_start
    for s in $BT_STEPS; do ( il_each "$s" ) >/dev/null 2>&1 || { echo "second-run-failed:$s"; exit 0; }; done
    ( bt_receipt ) >"$CASE_DIR/reuse.log" 2>&1 || { echo receipt-failed; cat "$CASE_DIR/reuse.log"; exit 0; }
    echo passed
  )"
  assert_eq passed "$out" "the rerun's receipt verifies"
  r="$CASE_DIR/reuse/receipts/bridges-toggle/20260101T000200Z-0000000b/receipt.tsv"
  assert_match '^reuse	linux/' "$(grep '^reuse' "$r")" "and names the reused Linux cell"
  assert_eq 2 "$(grep -c '^cell	' "$r")" "both cells are in it"
  assert_no_path "$CASE_DIR/reuse/runs/20260101T000200Z-0000000b/bridges-toggle/lin1" "the Linux target was not touched again"
}

# The whole run is bounded: a step past the run's budget does not start.
t_a_step_past_the_run_budget_does_not_start() {
  local out
  out="$(
    btd_world "$CASE_DIR/budget"
    ( il_each bt_before ) >/dev/null 2>&1 || { echo before-failed; exit 0; }
    # shellcheck disable=SC2031 # btd_world set it in this same subshell
    printf '%s\n' "$(( $(date +%s) - BT_RUN_MAX - 1 ))" >"$ARTIFACT_DIR/bridges-toggle/started"
    ( il_each bt_install ) >"$CASE_DIR/budget.log" 2>&1 && { echo install-ran; exit 0; }
    echo refused
  )"
  assert_eq refused "$out" "past BT_RUN_MAX the next step refuses"
  assert_match 'run budget' "$(cat "$CASE_DIR/budget.log")" "and says why"
  assert_eq "" "$(grep -x install-cell "$CASE_DIR/budget/fake/lin1/oplog" 2>/dev/null)" "nothing was installed"
}
