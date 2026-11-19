# shellcheck shell=bash
# Group integration/transport-live-dryrun (Sub-plan 4 Task 2.3, BL-042). The
# fixture twin of live/transport-live: the live group's own steps run against
# tests/fixtures/transport-live-adapter.sh and pass on a well-behaved fake;
# each defect a scenario exists for is then seeded and the step meant to
# catch it must fail. Nothing touches a host.

TLD_DRY_RUN_DIR="$ARTIFACT_DIR"
ARTIFACT_DIR="$TLD_DRY_RUN_DIR/dryrun"
mkdir -p "$ARTIFACT_DIR"
NICE_DNS_TARGET_ADAPTER="$NICE_DNS_ROOT/tests/fixtures/transport-live-adapter.sh"
NICE_DNS_IL_DRY_RUN=1
NICE_DNS_OPT_TARGETS=fake-targets.env
NICE_DNS_OPT_VARIANTS=representative
NICE_DNS_OPT_PLATFORMS=all
NICE_DNS_OPT_MATRIX=""
unset NICE_DNS_CELL_REUSE_RUNS
CR_POLL=0 CR_SETTLE_MAX=1 TL_HEAL_MAX=1
export CR_POLL CR_SETTLE_MAX TL_HEAL_MAX ARTIFACT_DIR NICE_DNS_OPT_MATRIX NICE_DNS_TARGET_ADAPTER NICE_DNS_IL_DRY_RUN NICE_DNS_OPT_TARGETS NICE_DNS_OPT_VARIANTS NICE_DNS_OPT_PLATFORMS

# shellcheck source=tests/live/transport-live.sh
. "$NICE_DNS_ROOT/tests/live/transport-live.sh"
unset -f t_1_before t_2_dnssec t_3_control t_4_tls_negative t_5_after t_6_privacy t_7_receipt

TLD_LIVE="$NICE_DNS_ROOT/tests/live/transport-live.sh"

# tld_world <dir> [run id]: a fresh fake and run directory, for the current subshell.
tld_world() {
  RUN_ID="${2:-20260101T000100Z-0000000b}"
  ARTIFACT_DIR="$1/runs/$RUN_ID" IL_FAKE_DIR="$1/fake"
  export ARTIFACT_DIR RUN_ID IL_FAKE_DIR
  mkdir -p "$ARTIFACT_DIR" "$IL_FAKE_DIR"
}

# tld_catches <defect> <step...>: with <defect> seeded the steps run in order
# and exactly the last one fails.
tld_catches() {
  local brk="$1" s out
  shift
  out="$(
    tld_world "$CASE_DIR/$brk"
    printf '%s\n' "$brk" >"$IL_FAKE_DIR/break"
    for s in "$@"; do
      ( il_each "$s" ) >"$CASE_DIR/$brk-$s.log" 2>&1 || { echo "caught-by:$s"; exit 0; }
    done
    echo not-caught
  )"
  assert_eq "caught-by:${!#}" "$out" "BL-042: the seeded defect '$brk' fails the step meant to catch it"
}

# tld_good <dir>: every step and the receipt on a well-behaved fake; prints
# passed, or the step that failed and its log.
tld_good() {
  local s
  tld_world "$1"
  for s in $TL_STEPS; do
    ( il_each "$s" ) >"$1-$s.log" 2>&1 || { echo "failed:$s"; cat "$1-$s.log"; return 0; }
  done
  ( tl_receipt ) >"$1-receipt.log" 2>&1 || { echo failed:receipt; cat "$1-receipt.log"; return 0; }
  echo passed
}

t_dry_run_prints_every_step_and_touches_nothing_bl042() {
  local out p t bin="$CASE_DIR/bin"
  mkdir -p "$bin"
  for t in ssh scp podman container launchctl dig; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/touched"\nexit 1\n' "$t" "$CASE_DIR" >"$bin/$t"
    chmod 755 "$bin/$t"
  done
  out="$(env -i PATH="$bin:$PATH" HOME="$CASE_DIR" bash "$TLD_LIVE" --dry-run)"
  assert_rc 0 "$?" "the dry run exits 0"
  assert_no_path "$CASE_DIR/touched" "it runs no ssh, podman, container, launchctl or dig"
  assert_match '^dry run: no target is touched$' "$out" "it says so"
  for p in linux macos; do
    assert_eq "$TL_STEPS " "$(printf '%s\n' "$out" | awk -v p="$p" '$1 == p { print $2 }' | tr '\n' ' ')" "$p: every step, in order"
  done
  assert_eq "tl_privacy tl_receipt " "$(printf '%s\n' "$out" | awk '$1 == "all" { print $2 }' | tr '\n' ' ')" "then the privacy check and the receipt"
  for t in 'TL-DNSSEC' 'dnssec-failed\.org' 'SERVFAIL' "\`ad\`" 'TL-CONTROL' '8953' 'Unix socket' 'TL-TLS-NEGATIVE' 'fault-route .*--mode tls-name' 'heal-route' 'gui session'; do
    assert_match "$t" "$out" "the plan names [$t]"
  done
  assert_eq "$TL_STEPS " \
    "$(sed -n 's/^t_[0-9]_[a-z_]*() { il_selection; il_each \(tl_[a-z_]*\); }$/\1/p' "$TLD_LIVE" | tr '\n' ' ')" \
    "and the group's cases run those steps in that order"
  assert_nonzero "$(bash "$TLD_LIVE" 2>/dev/null; echo $?)" "without --dry-run the file refuses to run alone"
}

t_the_group_and_its_twin_are_registered_bl042() {
  local g="$NICE_DNS_ROOT/tests/manifests/groups.tsv"
  assert_match '^live	transport-live	tests/live/transport-live\.sh	live$' "$(cat "$g")" "BL-042: the live group is registered"
  assert_match '^integration	transport-live-dryrun	tests/integration/transport-live-dryrun\.sh	local$' "$(cat "$g")" "BL-042: and its fixture twin"
  assert_match '(^| )transport-live( |$)' "$(sed -n "s/^RECEIPTS='\(.*\)'$/\1/p" "$NICE_DNS_ROOT/tests/reports/verify.sh")" "BL-042: verify.sh knows the receipt"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" manifests >"$CASE_DIR/manifests.log" 2>&1
  assert_rc 0 "$?" "every receipt manifest, the new one included, is well formed: $(cat "$CASE_DIR/manifests.log")"
}

t_a_well_behaved_target_passes_and_its_receipt_verifies_bl042() {
  local out r s
  out="$(tld_good "$CASE_DIR/good")"
  assert_eq passed "$out" "BL-042: every step and the receipt pass on a well-behaved fake"
  r="$(for r in "$CASE_DIR"/good/receipts/transport-live/*/receipt.tsv; do printf '%s\n' "$r"; done | tail -1)"
  assert_file "$r" "the receipt exists"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" >"$CASE_DIR/verify.log" 2>&1
  assert_rc 0 "$?" "BL-042: the receipt verifies on its own: $(cat "$CASE_DIR/verify.log")"
  assert_match '^receipt	transport-live$' "$(cat "$r")" "BL-042: named transport-live"
  for p in linux macos; do
    assert_eq "TL-CONTROL TL-DNSSEC TL-TLS-NEGATIVE " \
      "$(awk -F '\t' -v p="$p/" '$1 == "scenario" && index($3, p) == 1 { print $2 }' "$r" | sort | tr '\n' ' ')" "BL-042: $p carries the three scenarios"
  done
  s="$(cat "$CASE_DIR"/good/receipts/transport-live/*/cells/linux-*/dnssec.tsv)"
  assert_match '^dnssec	client	bogus	dnssec-failed\.org	SERVFAIL	' "$s" "the bogus name is refused through the client resolver"
  assert_match '^dnssec	unbound	signed	[^	]+	NOERROR	ad$' "$s" "the signed name validates at Unbound"
  s="$(cat "$CASE_DIR"/good/receipts/transport-live/*/cells/macos-*/tls-negative.tsv)"
  assert_match '^forwarder	[^	]+#nd-wrong-name\.invalid$' "$s" "the faulted forwarder carries the wrong name"
  assert_match '^faulted	[^	]+	SERVFAIL$' "$s" "a fresh name failed under it"
  assert_match '^healed	[^	]+	(NOERROR|NXDOMAIN)$' "$s" "and answered once healed"
}

t_each_scenario_fails_on_the_target_it_exists_for_bl042() {
  # BL-042: no validation, a TCP control port, an answer under a wrong name.
  tld_catches dnssec-noerror tl_before tl_dnssec
  tld_catches no-ad tl_before tl_dnssec
  tld_catches unsigned-ad tl_before tl_dnssec
  tld_catches tcp-8953 tl_before tl_dnssec tl_control
  tld_catches control-tcp tl_before tl_dnssec tl_control
  tld_catches tls-answers tl_before tl_dnssec tl_control tl_tls_negative
  tld_catches heal-fails tl_before tl_dnssec tl_control tl_tls_negative
  tld_catches fault-fails tl_before tl_dnssec tl_control tl_tls_negative
}

t_a_fault_is_always_healed_bl042() {
  local out d
  # The step heals before it fails.
  out="$(
    tld_world "$CASE_DIR/fail"
    printf '%s\n' tls-answers >"$IL_FAKE_DIR/break"
    for s in tl_before tl_dnssec tl_control tl_tls_negative; do ( il_each "$s" ) >/dev/null 2>&1; done
    grep -c '^heal-route$' "$IL_FAKE_DIR/lin1/oplog"
  )"
  assert_eq 1 "$out" "BL-042: a failed TLS step heals the route before it fails"
  # A step cut off with its fault in place leaves a marker; the after step heals it.
  out="$(
    tld_world "$CASE_DIR/left"
    ( il_each tl_before ) >/dev/null 2>&1 || { echo before-failed; exit 0; }
    d="$(il_dir lin1)"
    printf 'cloudflare-onion\n' >"$d/fault-left"; : >"$IL_FAKE_DIR/lin1/faulted"
    ( il_each tl_after ) >"$CASE_DIR/after.log" 2>&1 || { echo after-failed; cat "$CASE_DIR/after.log"; exit 0; }
    [ ! -f "$d/fault-left" ] || { echo marker-left; exit 0; }
    grep -c '^heal-route$' "$IL_FAKE_DIR/lin1/oplog"
  )"
  assert_eq 1 "$out" "BL-042: the after step heals a fault left in place, and drops the marker"
}

# BL-042: a receipt whose cell has no scenario row is refused.
t_a_cell_with_no_scenario_row_fails_verify_bl042() {
  local d r
  [ "$(tld_good "$CASE_DIR/v")" = passed ] || fail "the good run did not pass"
  r="$(for r in "$CASE_DIR"/v/receipts/transport-live/*/receipt.tsv; do printf '%s\n' "$r"; done | tail -1)"
  d="$CASE_DIR/v.m"; cp -R "$(dirname "$r")" "$d"
  awk -F '\t' '!($1 == "scenario" && $2 == "TL-CONTROL" && $3 ~ /^macos\//)' "$d/receipt.tsv" >"$d/r" && mv "$d/r" "$d/receipt.tsv"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$d/receipt.tsv" >"$CASE_DIR/v.log" 2>&1
  assert_rc 1 "$?" "BL-042: verify.sh refuses the receipt"
  assert_match 'missing scenario TL-CONTROL for cell macos/' "$(cat "$CASE_DIR/v.log")" "and names the missing scenario"
}

# DEC-009: a rerun of one platform carries the other's passed cell.
t_a_rerun_of_one_platform_reuses_the_other_cell_bl042() {
  local r out
  [ "$(tld_good "$CASE_DIR/first")" = passed ] || fail "the first run did not pass"
  out="$(
    tld_world "$CASE_DIR/second" 20260101T000200Z-0000000c
    NICE_DNS_OPT_PLATFORMS=linux NICE_DNS_CELL_REUSE_RUNS="$CASE_DIR/first/runs/20260101T000100Z-0000000b"
    export NICE_DNS_OPT_PLATFORMS NICE_DNS_CELL_REUSE_RUNS
    for s in $TL_STEPS; do ( il_each "$s" ) >/dev/null 2>&1 || { echo "failed:$s"; exit 0; }; done
    ( tl_receipt ) >"$CASE_DIR/second-receipt.log" 2>&1 || { echo failed:receipt; cat "$CASE_DIR/second-receipt.log"; exit 0; }
    echo passed
  )"
  assert_eq passed "$out" "the linux-only rerun passes"
  r="$(for r in "$CASE_DIR"/second/receipts/transport-live/*/receipt.tsv; do printf '%s\n' "$r"; done | tail -1)"
  assert_match '^reuse	macos/' "$(cat "$r")" "the macOS cell is carried from the first run (DEC-009)"
  assert_eq 0 "$(cat "$CASE_DIR/second/fake/mac1/oplog" 2>/dev/null | grep -c .)" "and the mac is not touched again"
}
