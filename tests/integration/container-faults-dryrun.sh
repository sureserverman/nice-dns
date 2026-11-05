# shellcheck shell=bash
# Group integration/container-faults-dryrun (restart-policy plan, Task 3.1).
# The dry run the live-gates rule asks for before live/container-faults
# touches a target: the live group's own steps run against
# tests/fixtures/command-recovery-adapter.sh and pass on a well-behaved fake;
# each defect the live checks exist for is then seeded and the step meant to
# catch it must fail. Nothing touches a host.

CF_DRY_RUN_DIR="$ARTIFACT_DIR"
ARTIFACT_DIR="$CF_DRY_RUN_DIR/dryrun"
mkdir -p "$ARTIFACT_DIR"
NICE_DNS_TARGET_ADAPTER="$NICE_DNS_ROOT/tests/fixtures/command-recovery-adapter.sh"
NICE_DNS_IL_DRY_RUN=1
NICE_DNS_OPT_TARGETS=fake-targets.env
NICE_DNS_OPT_VARIANTS=representative
NICE_DNS_OPT_PLATFORMS=all
NICE_DNS_OPT_MATRIX=""
unset NICE_DNS_CELL_REUSE_RUNS
CR_POLL=0 CR_RECOVER_MAX=1 CR_SETTLE_MAX=1 CR_QUIET=0
CF_RECOVER_MAX=1 CF_PAUSE_MAX=1 CF_CRASH_OBSERVE=0
export CR_POLL CR_RECOVER_MAX CR_SETTLE_MAX CR_QUIET CF_RECOVER_MAX CF_PAUSE_MAX CF_CRASH_OBSERVE ARTIFACT_DIR NICE_DNS_OPT_MATRIX NICE_DNS_TARGET_ADAPTER NICE_DNS_IL_DRY_RUN NICE_DNS_OPT_TARGETS NICE_DNS_OPT_VARIANTS NICE_DNS_OPT_PLATFORMS

# shellcheck source=tests/live/container-faults.sh
. "$NICE_DNS_ROOT/tests/live/container-faults.sh"
unset -f t_01_before t_02_install t_03_pihole t_04_pause t_05_crash t_06_stop t_07_after t_08_privacy t_09_receipt

# cfd_world <dir>: a fresh fake and run directory, for the current subshell.
cfd_world() {
  ARTIFACT_DIR="$1/runs/20260101T000100Z-0000000a" RUN_ID=20260101T000100Z-0000000a IL_FAKE_DIR="$1/fake"
  export ARTIFACT_DIR RUN_ID IL_FAKE_DIR
  mkdir -p "$ARTIFACT_DIR" "$IL_FAKE_DIR"
}

# cfd_catches <defect> <step...>: with <defect> seeded the steps run in order
# and exactly the last one fails.
cfd_catches() {
  local brk="$1" s out
  shift
  out="$(
    cfd_world "$CASE_DIR/$brk"
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
  out="$(env -i PATH="$PATH" bash "$NICE_DNS_ROOT/tests/live/container-faults.sh" --dry-run)"
  assert_rc 0 "$?" "the dry run exits 0"
  steps="$(printf '%s\n' "$out" | awk '/^cf_/ { print $1 }' | tr '\n' ' ')"
  assert_eq "$CF_STEPS cf_privacy cf_receipt " "$steps" "it prints the steps the group runs, in order"
  assert_eq "$CF_STEPS " \
    "$(sed -n 's/^t_0[0-9]_[a-z_]*() { il_selection; il_each \(cf_[a-z_]*\); }$/\1/p' "$NICE_DNS_ROOT/tests/live/container-faults.sh" | tr '\n' ' ')" \
    "and the group's cases run those steps in that order"
  assert_nonzero "$(bash "$NICE_DNS_ROOT/tests/live/container-faults.sh" 2>/dev/null; echo $?)" "without --dry-run the file refuses to run alone"
}

t_a_well_behaved_target_passes_and_its_receipt_verifies() {
  local s out r
  out="$(
    cfd_world "$CASE_DIR/good"
    for s in $CF_STEPS; do
      ( il_each "$s" ) >"$CASE_DIR/good-$s.log" 2>&1 || { echo "failed:$s"; cat "$CASE_DIR/good-$s.log"; exit 0; }
    done
    ( cf_receipt ) >"$CASE_DIR/good-receipt.log" 2>&1 || { echo failed:receipt; cat "$CASE_DIR/good-receipt.log"; exit 0; }
    echo passed
  )"
  assert_eq passed "$out" "every step and the receipt pass on a well-behaved fake"
  r="$(for r in "$CASE_DIR"/good/receipts/container-faults/*/receipt.tsv; do printf '%s\n' "$r"; done | tail -1)"
  assert_file "$r" "the receipt exists"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" >/dev/null 2>&1
  assert_rc 0 "$?" "the receipt verifies on its own"
  assert_eq "CF-CRASH CF-PAUSE CF-PIHOLE " "$(awk -F '\t' '$1 == "scenario" && $3 ~ /^linux\// { print $2 }' "$r" | sort | tr '\n' ' ')" "Linux carries the pause and crash scenarios"
  assert_eq "CF-PIHOLE CF-STOP " "$(awk -F '\t' '$1 == "scenario" && $3 ~ /^macos\// { print $2 }' "$r" | sort | tr '\n' ' ')" "macOS carries the stop scenario"
}

t_each_seeded_defect_is_caught() {
  local before='cf_before cf_install'
  # shellcheck disable=SC2086 # one word per step
  {
    cfd_catches no-ready $before cf_pihole
    cfd_catches no-ack $before cf_pihole
    cfd_catches not-felt $before cf_pihole
    cfd_catches gen-unchanged $before cf_pihole
    cfd_catches servfail $before cf_pihole
    cfd_catches pause-wrong $before cf_pihole cf_pause
    cfd_catches crash-twice $before cf_pihole cf_pause cf_crash
    cfd_catches crash-restart $before cf_pihole cf_pause cf_crash
    cfd_catches no-backoff $before cf_pihole cf_pause cf_crash
  }
}

# The receipt refuses evidence that says the job was not done, and a
# platform's scenario recorded on the other platform's cell.
t_the_receipt_checks_the_evidence_not_the_verdict() {
  local d r f row t h s
  (
    cfd_world "$CASE_DIR/forged"
    for s in $CF_STEPS; do ( il_each "$s" ) >/dev/null 2>&1 || exit 1; done
    ( cf_receipt ) >"$CASE_DIR/forged.log" 2>&1 || exit 1
  ) || fail "setup: $(tail -n 5 "$CASE_DIR/forged.log" 2>/dev/null)"
  r="$(for r in "$CASE_DIR"/forged/receipts/container-faults/*/receipt.tsv; do printf '%s\n' "$r"; done | tail -1)"
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
fault-crash.tsv|s/^crash_escalations\t1$/crash_escalations\t2/
fault-crash.tsv|s/^controller_proxy_restarts\t0$/controller_proxy_restarts\t1/
fault-crash.tsv|s/^backoff_growing\tyes$/backoff_growing\tno/
fault-crash.tsv|s/^nrestarts_rise\t.*/nrestarts_rise\t2/
fault-pause.tsv|s/^running_after\tyes$/running_after\tno/
fault-pause.tsv|s/containers-paused/containers-missing/
fault-pihole.tsv|s/^generation_changed\tyes$/generation_changed\tno/
fault-stop.tsv|s/^fresh_during_fault\t.*/fresh_during_fault\tNOERROR/
EOF
  # A Linux-only scenario on the macOS cell, and one dropped from Linux.
  cp -R "$d" "$d.m"
  awk -F '\t' -v OFS='\t' '$1 == "scenario" && $2 == "CF-PAUSE" { print; $3 = m; print; next } $1 == "cell" && $2 == "macos" { m = $2 "/" $3 "/" $4 } { print }' "$d.m/receipt.tsv" >"$d.m/r" && mv "$d.m/r" "$d.m/receipt.tsv"
  assert_match 'CF-PAUSE is linux-only' "$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$d.m/receipt.tsv" 2>&1)" "a Linux-only scenario on a macOS cell is refused"
  rm -rf "$d.m"; cp -R "$d" "$d.m"
  awk -F '\t' '!($1 == "scenario" && $2 == "CF-CRASH")' "$d.m/receipt.tsv" >"$d.m/r" && mv "$d.m/r" "$d.m/receipt.tsv"
  assert_match 'missing scenario CF-CRASH for cell linux/' "$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$d.m/receipt.tsv" 2>&1)" "a Linux cell without the crash scenario is refused"
  rm -rf "$d.m"
}

# A failed platform runs no more fault steps, but still ends settled.
t_a_failed_step_stops_the_platform_and_the_after_step_still_runs() {
  local out
  out="$(
    cfd_world "$CASE_DIR/stop"
    printf 'no-ready\n' >"$IL_FAKE_DIR/break"
    for s in cf_before cf_install cf_pihole; do ( il_each "$s" ) >/dev/null 2>&1; done
    ( il_each cf_pause ) >"$CASE_DIR/stop.log" 2>&1 && { echo pause-ran; exit 0; }
    ( il_each cf_after ) >"$CASE_DIR/after.log" 2>&1 || { echo after-failed; cat "$CASE_DIR/after.log"; exit 0; }
    echo stopped
  )"
  assert_eq stopped "$out" "the later fault did not run and the after step did ($(tail -n 3 "$CASE_DIR/stop.log" 2>/dev/null))"
}

# A rerun of one platform carries the other's passed cell into the receipt.
t_a_passed_cell_is_reused_on_a_rerun() {
  local out r first
  out="$(
    cfd_world "$CASE_DIR/reuse"
    for s in $CF_STEPS; do ( il_each "$s" ) >/dev/null 2>&1 || { echo "first-run-failed:$s"; exit 0; }; done
    first="$ARTIFACT_DIR"
    ARTIFACT_DIR="$CASE_DIR/reuse/runs/20260101T000200Z-0000000b" RUN_ID=20260101T000200Z-0000000b
    NICE_DNS_OPT_PLATFORMS=macos NICE_DNS_CELL_REUSE_RUNS="$first"
    export ARTIFACT_DIR RUN_ID NICE_DNS_OPT_PLATFORMS NICE_DNS_CELL_REUSE_RUNS
    mkdir -p "$ARTIFACT_DIR"
    for s in $CF_STEPS; do ( il_each "$s" ) >/dev/null 2>&1 || { echo "second-run-failed:$s"; exit 0; }; done
    ( cf_receipt ) >"$CASE_DIR/reuse.log" 2>&1 || { echo receipt-failed; cat "$CASE_DIR/reuse.log"; exit 0; }
    echo passed
  )"
  assert_eq passed "$out" "the rerun's receipt verifies"
  r="$CASE_DIR/reuse/receipts/container-faults/20260101T000200Z-0000000b/receipt.tsv"
  assert_match '^reuse	linux/' "$(grep '^reuse' "$r")" "and names the reused Linux cell"
}

# The real adapter's new operations: refused before anything is sent.
t_target_guards_cover_the_new_operations() {
  local tg="$NICE_DNS_ROOT/tests/live/target.sh" f="$CASE_DIR/targets.env" out
  printf 'lin1\tlinux\tnd-no-such-host.invalid\tSHA256:%s\tdisposable\t2026-01-01\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA >"$f"
  chmod 600 "$f"
  out="$(bash "$tg" freeze-service lin1 --targets "$f" --component tor-haproxy 2>&1)"
  assert_rc 2 "$?" "only Pi-hole or Unbound can be frozen: $out"
  out="$(bash "$tg" pause-container lin1 --targets "$f" --component sshd 2>&1)"
  assert_rc 2 "$?" "only a stack container can be paused: $out"
  out="$(bash "$tg" crash-container lin1 --targets "$f" --component unbound --times 4 --every 20 2>&1)"
  assert_rc 2 "$?" "only the proxy can be crashed: $out"
  out="$(bash "$tg" crash-container lin1 --targets "$f" --component tor-haproxy 2>&1)"
  assert_rc 2 "$?" "a crash sequence needs --times and --every: $out"
  out="$(bash "$tg" crash-container lin1 --targets "$f" --component tor-haproxy --times 4 --every 5 2>&1)"
  assert_rc 2 "$?" "crashes closer than 20 s are refused: $out"
  out="$(bash "$tg" stop-container lin1 --targets "$f" --component pi-hole --times 4 2>&1)"
  assert_rc 2 "$?" "--times is for crash-container only: $out"
  out="$(ARTIFACT_DIR="$CASE_DIR/guards" bash "$tg" crash-container lin1 --targets "$f" --component tor-haproxy --times 4 --every 20 2>&1)"
  assert_rc 2 "$?" "a crash sequence needs the run's snapshot: $out"
  assert_match 'no restore snapshot' "$out" "and says so"
}
