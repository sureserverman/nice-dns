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

NICE_DNS_TARGET_ADAPTER="$NICE_DNS_ROOT/tests/fixtures/lifecycle-adapter.sh"
NICE_DNS_IL_DRY_RUN=1
NICE_DNS_OPT_TARGETS=fake-targets.env
NICE_DNS_OPT_VARIANTS=representative
NICE_DNS_OPT_PLATFORMS=all
export NICE_DNS_TARGET_ADAPTER NICE_DNS_IL_DRY_RUN NICE_DNS_OPT_TARGETS NICE_DNS_OPT_VARIANTS NICE_DNS_OPT_PLATFORMS

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
