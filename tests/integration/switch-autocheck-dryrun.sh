# shellcheck shell=bash
# Group integration/switch-autocheck-dryrun (app-switches-autocheck plan, Task
# 3.1). The dry run the live-gates rule asks for before live/switch-autocheck
# touches a target: the live group's own steps run against
# tests/fixtures/switch-autocheck-adapter.sh for both platforms and pass on a
# well-behaved fake; each defect the live checks exist for is then seeded and
# the step meant to catch it must fail; a copy of the group with one step
# emptied must not produce a receipt; and the verifier refuses a receipt that
# lacks any one step's row. Nothing touches a host.

SA_DRY_RUN_DIR="$ARTIFACT_DIR"
ARTIFACT_DIR="$SA_DRY_RUN_DIR/dryrun"
mkdir -p "$ARTIFACT_DIR"
NICE_DNS_TARGET_ADAPTER="$NICE_DNS_ROOT/tests/fixtures/switch-autocheck-adapter.sh"
NICE_DNS_IL_DRY_RUN=1
NICE_DNS_OPT_TARGETS=fake-targets.env
NICE_DNS_OPT_VARIANTS=representative
NICE_DNS_OPT_PLATFORMS=all
NICE_DNS_OPT_MATRIX=""
unset NICE_DNS_CELL_REUSE_RUNS
SA_DNS_MAX=1 SA_POLL=0
export SA_DNS_MAX SA_POLL ARTIFACT_DIR NICE_DNS_OPT_MATRIX NICE_DNS_TARGET_ADAPTER NICE_DNS_IL_DRY_RUN NICE_DNS_OPT_TARGETS NICE_DNS_OPT_VARIANTS NICE_DNS_OPT_PLATFORMS

SAD_LIVE="$NICE_DNS_ROOT/tests/live/switch-autocheck.sh"
# shellcheck source=tests/live/switch-autocheck.sh
. "$SAD_LIVE"
unset -f t_01_before t_02_install t_03_proxy t_04_hardened t_05_update t_06_restore t_07_privacy t_08_receipt

# sad_world <dir>: a fresh fake and run directory, for the current subshell.
sad_world() {
  ARTIFACT_DIR="$1/runs/20260101T000100Z-0000000a" RUN_ID=20260101T000100Z-0000000a IL_FAKE_DIR="$1/fake"
  export ARTIFACT_DIR RUN_ID IL_FAKE_DIR
  mkdir -p "$ARTIFACT_DIR" "$IL_FAKE_DIR"
  sa_budget_start
}

# sad_catches <defect> <step...>: with <defect> seeded the steps run in order
# and exactly the last one fails.
sad_catches() {
  local brk="$1" s out
  shift
  out="$(
    sad_world "$CASE_DIR/$brk"
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
  for t in ssh scp podman container launchctl systemctl; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/touched"\nexit 1\n' "$t" "$CASE_DIR" >"$bin/$t"
    chmod 755 "$bin/$t"
  done
  out="$(env -i PATH="$bin:$PATH" HOME="$CASE_DIR" bash "$SAD_LIVE" --dry-run)"
  assert_rc 0 "$?" "the dry run exits 0"
  assert_no_path "$CASE_DIR/touched" "it runs no ssh, podman, container, launchctl or systemctl"
  assert_match '^dry run: no target is touched$' "$out" "it says so"
  for p in linux macos; do
    assert_eq "$SA_STEPS " "$(printf '%s\n' "$out" | awk -v p="$p" '$1 == p { print $2 }' | tr '\n' ' ')" "$p: every step, in order"
  done
  assert_eq "sa_privacy sa_receipt " "$(printf '%s\n' "$out" | awk '$1 == "all" { print $2 }' | tr '\n' ' ')" "then the privacy check and the receipt"
  assert_match '^linux +sa_proxy .*--run-action proxy-<other> --exit with GSK_RENDERER=cairo' "$out" "mint's app runs its own action with cairo (DEC-027)"
  assert_match '^macos +sa_proxy .*gui session \(launchctl asuser\)' "$out" "the mac's app runs in the gui session (DEC-024)"
  assert_match '^linux +sa_before .*polkit-test-rule add' "$out" "Linux puts the polkit test rule in place"
  assert_match '^linux +sa_restore .*polkit-test-rule remove' "$out" "and takes it out"
  assert_not_match '^macos .*polkit' "$out" "macOS needs none"
  for t in 'no pi-hole-hardened checkout' 'switch pihole hardened' 'nice-dns-health-update.service' 'kickstart gui/<uid>/org.nice-dns.health-update' 'checked_at moved' 'reinstall-cell'; do
    assert_match "$t" "$out" "the plan names [$t]"
  done
  assert_eq "$SA_STEPS " \
    "$(sed -n 's/^t_[0-9][0-9]_[a-z_]*() { il_selection; il_each \(sa_[a-z_]*\); }$/\1/p' "$SAD_LIVE" | tr '\n' ' ')" \
    "and the group's cases run those steps in that order"
  assert_nonzero "$(bash "$SAD_LIVE" 2>/dev/null; echo $?)" "without --dry-run the file refuses to run alone"
}

# target.sh carries every operation and mode the group asks it for.
t_target_sh_has_every_operation_and_mode_the_group_uses() {
  local tg="$NICE_DNS_ROOT/tests/live/target.sh" ops o m
  ops="$(sed -n "s/^OPS='\(.*\)'$/\1/p" "$tg")"
  for o in snapshot lifecycle-report command gui-report gui-session switch-report update-schedule polkit-test-rule; do
    case " $ops " in *" $o "*) ;; *) fail "target.sh has no operation $o" ;; esac
  done
  for m in install-git status switch-pihole-hardened reinstall-cell; do
    grep -q "command needs --mode .*$m" "$tg" || fail "target.sh command has no mode $m"
  done
  for m in proxy-haproxy proxy-socat; do
    grep -q "gui-session needs --mode .*$m" "$tg" || fail "target.sh gui-session has no mode $m"
  done
  assert_match 'GSK_RENDERER=cairo' "$(sed -n '/^  gui-session)/,/^  polkit-test-rule)/p' "$tg")" "the Linux gui session sets the cairo renderer"
  grep -qx "live	switch-autocheck	tests/live/switch-autocheck.sh	live" "$NICE_DNS_ROOT/tests/manifests/groups.tsv" || fail "the live group is not registered"
  grep -q "^RECEIPTS=.* switch-autocheck" "$NICE_DNS_ROOT/tests/reports/verify.sh" || fail "verify.sh does not know the receipt"
}

# Every operation target.sh accepts has a route in its local dispatch (the
# case after "operations"): the fake adapter replaces target.sh, so only this
# reads the dispatch. validate exits before it.
t_target_sh_routes_every_operation() {
  local tg="$NICE_DNS_ROOT/tests/live/target.sh" routed o miss=""
  routed="$(sed -n '/^# ─── operations ─/,$p' "$tg" | awk '/^  [a-z|-]+\)$/' | tr -d ' )' | tr '|' '\n' | sort -u)"
  # shellcheck disable=SC2013 # OPS is one line of words
  for o in $(sed -n "s/^OPS='\(.*\)'$/\1/p" "$tg"); do
    [ "$o" = validate ] && continue
    printf '%s\n' "$routed" | grep -qx -- "$o" || miss="$miss $o"
  done
  assert_eq "" "$miss" "every operation is routed in target.sh's dispatch"
  assert_match '^  \*\) die "operation' "$(sed -n '/^# ─── operations ─/,$p' "$tg")" "an unrouted operation is refused, never a silent exit 0"
}

# Without --live --targets the group refuses before it touches anything.
t_the_group_refuses_without_targets() {
  local out
  out="$(
    sad_world "$CASE_DIR/notargets"
    unset NICE_DNS_OPT_TARGETS
    ( il_selection && il_each sa_before ) >"$CASE_DIR/sel.log" 2>&1 && { echo ran; exit 0; }
    echo refused
  )"
  assert_eq refused "$out" "no --targets: refused ($(cat "$CASE_DIR/sel.log" 2>/dev/null))"
  assert_match '--targets FILE' "$(cat "$CASE_DIR/sel.log")" "the refusal names --targets"
  assert_no_path "$CASE_DIR/notargets/fake/lin1" "no fake target was touched"
}

t_a_well_behaved_target_passes_and_its_receipt_verifies() {
  local s out r p
  out="$(
    sad_world "$CASE_DIR/good"
    for s in $SA_STEPS; do
      ( il_each "$s" ) >"$CASE_DIR/good-$s.log" 2>&1 || { echo "failed:$s"; cat "$CASE_DIR/good-$s.log"; exit 0; }
    done
    ( sa_receipt ) >"$CASE_DIR/good-receipt.log" 2>&1 || { echo failed:receipt; cat "$CASE_DIR/good-receipt.log"; exit 0; }
    echo passed
  )"
  assert_eq passed "$out" "every step and the receipt pass on a well-behaved fake"
  r="$(for r in "$CASE_DIR"/good/receipts/switch-autocheck/*/receipt.tsv; do printf '%s\n' "$r"; done | tail -1)"
  assert_file "$r" "the receipt exists"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" >/dev/null 2>&1
  assert_rc 0 "$?" "the receipt verifies on its own"
  for p in linux macos; do
    assert_eq "SA-BEFORE SA-HARDENED SA-INSTALL SA-PROXY SA-RESTORE SA-UPDATE " \
      "$(awk -F '\t' -v p="$p" '$1 == "scenario" && index($3, p "/") == 1 { print $2 }' "$r" | sort | tr '\n' ' ')" "$p carries every step's scenario"
  done
  assert_match '^limit	schedule-by-hand	' "$(cat "$r")" "the receipt says the schedule was started by hand"
  # The fake targets end where they started: lin1 on haproxy, mac1 on socat,
  # standard Pi-hole, no polkit rule.
  assert_eq "haproxy standard absent" "$(cat "$CASE_DIR/good/fake/lin1/proxy") $(cat "$CASE_DIR/good/fake/lin1/pihole") $(cat "$CASE_DIR/good/fake/lin1/polkit")" "lin1 is back on its choices"
  assert_eq "socat standard" "$(cat "$CASE_DIR/good/fake/mac1/proxy") $(cat "$CASE_DIR/good/fake/mac1/pihole")" "mac1 is back on its choices"
  s="$(cat "$CASE_DIR"/good/receipts/switch-autocheck/*/cells/linux-*/sa-proxy.tsv)"
  assert_match '^action	proxy-socat$' "$s" "lin1 switched to the other proxy"
  assert_match '^running_proxy	tor-socat$' "$s" "and only it runs"
  s="$(cat "$CASE_DIR"/good/receipts/switch-autocheck/*/cells/macos-*/sa-hardened.tsv)"
  assert_match '^pihole_running	hardened$' "$s" "the hardened Pi-hole runs on mac1"
  assert_match '^kept_base	present$' "$s" "from the kept base"
}

t_each_seeded_defect_is_caught() {
  local before='sa_before sa_install'
  # shellcheck disable=SC2086 # one word per step
  {
    sad_catches checkout-present sa_before
    sad_catches polkit-fails sa_before
    sad_catches install-fails sa_before sa_install
    sad_catches no-gui sa_before sa_install
    sad_catches auto-stopped sa_before sa_install
    sad_catches gui-fails $before sa_proxy
    sad_catches pane-other $before sa_proxy
    sad_catches proxy-unchanged $before sa_proxy
    sad_catches old-proxy-left $before sa_proxy
    sad_catches commit-changed $before sa_proxy
    sad_catches switch-fails $before sa_proxy sa_hardened
    sad_catches last-line-other $before sa_proxy sa_hardened
    sad_catches hardened-standard $before sa_proxy sa_hardened
    sad_catches base-missing $before sa_proxy sa_hardened
    sad_catches checkout-appears $before sa_proxy sa_hardened
    sad_catches servfail-hardened $before sa_proxy sa_hardened
    sad_catches schedule-fails $before sa_proxy sa_hardened sa_update
    sad_catches schedule-stale $before sa_proxy sa_hardened sa_update
    sad_catches restore-wrong $before sa_proxy sa_hardened sa_update sa_restore
    sad_catches polkit-left $before sa_proxy sa_hardened sa_update sa_restore
    sad_catches polkit-unconfirmed sa_before
    sad_catches schedule-unknown $before sa_proxy sa_hardened sa_update
    sad_catches restore-fails $before sa_proxy sa_hardened sa_update sa_restore
  }
}

# One mutant per step: a copy of the group whose step does nothing must not
# end in a receipt. The live file itself is never edited.
t_a_cell_with_any_step_removed_does_not_verify() {
  local s out m
  for s in $SA_STEPS; do
    m="$CASE_DIR/mutant-$s.sh"
    awk -v f="$s" '
      $0 ~ "^" f "\\(\\) \\{" { print f "() { :; }"; skip = 1; next }
      skip && /^}$/ { skip = 0; next }
      !skip' "$SAD_LIVE" >"$m"
    assert_eq 1 "$(grep -c "^$s() { :; }$" "$m")" "mutant: $s is emptied"
    cmp -s "$m" "$SAD_LIVE" && fail "mutant for $s equals the live file"
    out="$(
      # shellcheck disable=SC1090 # the mutant copy
      . "$m"
      unset -f t_01_before t_02_install t_03_proxy t_04_hardened t_05_update t_06_restore t_07_privacy t_08_receipt
      sad_world "$CASE_DIR/m-$s"
      for x in $SA_STEPS; do ( il_each "$x" ) >"$CASE_DIR/m-$s-$x.log" 2>&1 || { echo "stopped:$x"; exit 0; }; done
      ( sa_receipt ) >"$CASE_DIR/m-$s-receipt.log" 2>&1 && { echo verified; exit 0; }
      echo refused
    )"
    case "$out" in verified|'') fail "with $s emptied the run still verified ($out)" ;; esac
    # The steps before the emptied one passed: the mutant was caught by the
    # run, not broken by the copy.
    for x in $SA_STEPS; do
      [ "$x" = "$s" ] && break
      [ "$out" != "stopped:$x" ] || fail "with $s emptied the run stopped at $x, before it"
    done
  done
  # The live file is the one the run read.
  assert_eq 0 "$(grep -c '() { :; }$' "$SAD_LIVE")" "the live file has no emptied step"
}

# The receipt refuses evidence that says the job was not done, and one that
# lacks any step's row.
t_the_receipt_checks_the_evidence_and_every_step_row() {
  local d r f row t h s id
  (
    sad_world "$CASE_DIR/forged"
    for s in $SA_STEPS; do ( il_each "$s" ) >/dev/null 2>&1 || exit 1; done
    ( sa_receipt ) >"$CASE_DIR/forged.log" 2>&1 || exit 1
  ) || fail "setup: $(tail -n 5 "$CASE_DIR/forged.log" 2>/dev/null)"
  r="$(for r in "$CASE_DIR"/forged/receipts/switch-autocheck/*/receipt.tsv; do printf '%s\n' "$r"; done | tail -1)"
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
sa-before.tsv|s/\tabsent$/\tpresent/
sa-install.tsv|s/^update_auto\tloaded$/update_auto\tstopped/
sa-install.tsv|/^gui\t/d
sa-proxy.tsv|s/^gui_exit\t0$/gui_exit\t1/
sa-proxy.tsv|/^running_proxy\t/d
sa-proxy.tsv|s/^resolves\tyes$/resolves\tno/
sa-hardened.tsv|s/^pihole_running\thardened$/pihole_running\tstandard/
sa-hardened.tsv|s/^kept_base\tpresent$/kept_base\tabsent/
sa-hardened.tsv|/^cli_last\t/d
sa-update.tsv|/^checked_at_after\t/d
sa-update.tsv|s/^schedule_done\tyes$/schedule_done\tno/
sa-update.tsv|s/^result_after\t.*/result_after\tunknown/
sa-restore.tsv|s/^pihole\tstandard$/pihole\thardened/
sa-restore.tsv|s/^resolves\tyes$/resolves\tno/
EOF
  for id in SA-BEFORE SA-INSTALL SA-PROXY SA-HARDENED SA-UPDATE SA-RESTORE; do
    cp -R "$d" "$d.m"
    awk -F '\t' -v i="$id" '!($1 == "scenario" && $2 == i && $3 ~ /^linux\//)' "$d.m/receipt.tsv" >"$d.m/r" && mv "$d.m/r" "$d.m/receipt.tsv"
    assert_match "missing scenario $id for cell linux/" "$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$d.m/receipt.tsv" 2>&1)" "a Linux cell without its $id row is refused"
    rm -rf "$d.m"
  done
}

# A failed platform runs no more switch steps, but still ends on its recorded
# choices.
t_a_failed_step_stops_the_platform_and_the_restore_still_runs() {
  local out
  out="$(
    sad_world "$CASE_DIR/stop"
    printf 'switch-fails\n' >"$IL_FAKE_DIR/break"
    for s in sa_before sa_install sa_proxy sa_hardened; do ( il_each "$s" ) >/dev/null 2>&1; done
    ( il_each sa_update ) >"$CASE_DIR/stop.log" 2>&1 && { echo update-ran; exit 0; }
    ( il_each sa_restore ) >"$CASE_DIR/restore.log" 2>&1 || { echo restore-failed; cat "$CASE_DIR/restore.log"; exit 0; }
    echo stopped
  )"
  assert_eq stopped "$out" "the later steps did not run and the restore did ($(tail -n 3 "$CASE_DIR/stop.log" 2>/dev/null))"
  assert_eq "haproxy standard socat standard" \
    "$(cat "$CASE_DIR/stop/fake/lin1/proxy") $(cat "$CASE_DIR/stop/fake/lin1/pihole") $(cat "$CASE_DIR/stop/fake/mac1/proxy") $(cat "$CASE_DIR/stop/fake/mac1/pihole")" \
    "both targets end on their recorded choices"
  assert_eq absent "$(cat "$CASE_DIR/stop/fake/lin1/polkit")" "and the polkit test rule is gone"
}

# The polkit test rule never outlives the run on Linux: a restore that fails,
# and a sa_before that stops right after adding the rule, still remove it.
t_the_polkit_rule_is_removed_on_every_path() {
  local brk out
  for brk in restore-fails polkit-unconfirmed; do
    out="$(
      sad_world "$CASE_DIR/pk-$brk"
      printf '%s\n' "$brk" >"$IL_FAKE_DIR/break"
      for s in sa_before sa_install sa_proxy sa_hardened sa_update; do ( il_each "$s" ) >/dev/null 2>&1; done
      ( il_each sa_restore ) >"$CASE_DIR/pk-$brk.log" 2>&1 && { echo restore-passed; exit 0; }
      echo restore-failed
    )"
    assert_eq restore-failed "$out" "$brk: the restore step fails"
    assert_eq absent "$(cat "$CASE_DIR/pk-$brk/fake/lin1/polkit")" "$brk: and the polkit test rule is gone from lin1"
  done
  assert_match 'restore|recorded choices' "$(cat "$CASE_DIR/pk-polkit-unconfirmed.log")" "the failure says why"
}

# A failed cell's receipt row names the first step it did not pass.
t_a_failed_cell_names_its_step() {
  local out r v
  out="$(
    sad_world "$CASE_DIR/named"
    printf 'switch-fails\n' >"$IL_FAKE_DIR/break"
    for s in $SA_STEPS; do ( il_each "$s" ) >/dev/null 2>&1; done
    ( sa_receipt ) >"$CASE_DIR/named-receipt.log" 2>&1 && { echo receipt-passed; exit 0; }
    echo receipt-failed
  )"
  assert_eq receipt-failed "$out" "a run with failed cells has no passing receipt"
  r="$(for r in "$CASE_DIR"/named/receipts/switch-autocheck/*/receipt.tsv; do printf '%s\n' "$r"; done | tail -1)"
  assert_file "$r" "the receipt is written all the same"
  assert_match '^cell	linux	haproxy	standard	lin1	.*	failed$' "$(cat "$r")" "the Linux cell is recorded failed"
  assert_match '^scenario	SA-HARDENED	linux/haproxy/standard	fail	' "$(cat "$r")" "and names the step it failed: sa_hardened"
  assert_match '^scenario	SA-HARDENED	macos/socat/standard	fail	' "$(cat "$r")" "so does the macOS cell"
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" 2>&1)"
  assert_match 'scenario SA-HARDENED \(linux/haproxy/standard\) is fail' "$v" "the verifier names the cell and the step"
}

# A target that does not answer is not run, is named, and the owner is asked
# to wake it; the other platform runs.
t_an_offline_target_is_named_and_not_run() {
  local out
  out="$(
    sad_world "$CASE_DIR/off"
    printf 'offline-lin1\n' >"$IL_FAKE_DIR/break"
    ( il_each sa_before ) >"$CASE_DIR/off-before.log" 2>&1 && { echo before-passed; exit 0; }
    for s in sa_install sa_proxy sa_hardened sa_update sa_restore; do ( il_each "$s" ) >/dev/null 2>&1; done
    ( sa_receipt ) >"$CASE_DIR/off-receipt.log" 2>&1 && { echo receipt-passed; exit 0; }
    echo stopped
  )"
  assert_eq stopped "$out" "the run stops on the offline target and has no passing receipt"
  assert_match 'OFFLINE: lin1 does not answer \(.*timed out' "$(cat "$CASE_DIR/off-before.log")" "sa_before says lin1 is offline and why"
  assert_match 'Ask the owner to wake lin1' "$(cat "$CASE_DIR/off-before.log")" "and asks for it to be woken"
  assert_match -- '--platforms linux' "$(cat "$CASE_DIR/off-before.log")" "and says how to rerun only that platform"
  assert_no_path "$CASE_DIR/off/runs/20260101T000100Z-0000000a/switch-autocheck/lin1/cell.tsv" "the offline cell is not run"
  assert_eq "" "$(grep -E '^(command|gui-session|polkit-test-rule)$' "$CASE_DIR/off/fake/lin1/oplog" 2>/dev/null)" "nothing was done to lin1"
  assert_file "$CASE_DIR/off/fake/mac1/commit" "mac1 still ran"
  assert_match 'offline: linux' "$(cat "$CASE_DIR/off-receipt.log")" "the receipt step names the offline platform"
}

# A rerun of one platform carries the other's passed cell into the receipt.
t_a_passed_cell_is_reused_on_a_rerun() {
  local out r
  out="$(
    sad_world "$CASE_DIR/reuse"
    for s in $SA_STEPS; do ( il_each "$s" ) >/dev/null 2>&1 || { echo "first-run-failed:$s"; exit 0; }; done
    first="$ARTIFACT_DIR"
    # shellcheck disable=SC2030 # this subshell's own run
    ARTIFACT_DIR="$CASE_DIR/reuse/runs/20260101T000200Z-0000000b" RUN_ID=20260101T000200Z-0000000b
    NICE_DNS_OPT_PLATFORMS=macos NICE_DNS_CELL_REUSE_RUNS="$first"
    export ARTIFACT_DIR RUN_ID NICE_DNS_OPT_PLATFORMS NICE_DNS_CELL_REUSE_RUNS
    mkdir -p "$ARTIFACT_DIR"
    sa_budget_start
    for s in $SA_STEPS; do ( il_each "$s" ) >/dev/null 2>&1 || { echo "second-run-failed:$s"; exit 0; }; done
    ( sa_receipt ) >"$CASE_DIR/reuse.log" 2>&1 || { echo receipt-failed; cat "$CASE_DIR/reuse.log"; exit 0; }
    echo passed
  )"
  assert_eq passed "$out" "the rerun's receipt verifies"
  r="$CASE_DIR/reuse/receipts/switch-autocheck/20260101T000200Z-0000000b/receipt.tsv"
  assert_match '^reuse	linux/' "$(grep '^reuse' "$r")" "and names the reused Linux cell"
  assert_eq 2 "$(grep -c '^cell	' "$r")" "both cells are in it"
  assert_no_path "$CASE_DIR/reuse/runs/20260101T000200Z-0000000b/switch-autocheck/lin1" "the Linux target was not touched again"
}

# The whole run is bounded: a step past the run's budget does not start.
t_a_step_past_the_run_budget_does_not_start() {
  local out
  out="$(
    sad_world "$CASE_DIR/budget"
    ( il_each sa_before ) >/dev/null 2>&1 || { echo before-failed; exit 0; }
    # shellcheck disable=SC2031 # sad_world set it in this same subshell
    printf '%s\n' "$(( $(date +%s) - SA_RUN_MAX - 1 ))" >"$ARTIFACT_DIR/switch-autocheck/started"
    ( il_each sa_install ) >"$CASE_DIR/budget.log" 2>&1 && { echo install-ran; exit 0; }
    echo refused
  )"
  assert_eq refused "$out" "past SA_RUN_MAX the next step refuses"
  assert_match 'run budget' "$(cat "$CASE_DIR/budget.log")" "and says why"
  assert_no_path "$CASE_DIR/budget/fake/lin1/commit" "nothing was installed"
}
