# shellcheck shell=bash
# Group live/baseline-characterize (sub-plan 01, Task 2.3; ARCH-09).
#
# Characterizes the cell each designated target currently runs (one Linux,
# one macOS: --platforms all --variants representative), then assembles and
# verifies a representative baseline receipt. Pass means every observation
# is complete and each target is back in its snapshot state; product defects
# are recorded in each cell's findings.tsv, not failed on. The remaining six
# cells belong to the Stage 2 gate (`run.sh plan baseline --matrix all`).
#
# Cases run in name order and share $ARTIFACT_DIR/baseline/ALIAS.

BC_BASELINE="$NICE_DNS_ROOT/tests/live/baseline.sh"

bc_selection() {
  assert_eq all "${NICE_DNS_OPT_PLATFORMS:-}" "--platforms all (a platform left out is BLOCKED, never green)"
  assert_eq representative "${NICE_DNS_OPT_VARIANTS:-}" "--variants representative (the deployed cell; all eight belong to the gate)"
}

bc_alias() {
  # bc_alias PLATFORM: the one alias of that platform in the targets file.
  local rows
  rows="$(bash "$NICE_DNS_ROOT/tests/live/target.sh" validate --targets "$NICE_DNS_OPT_TARGETS" | awk -F '\t' -v p="$1" '$2 == p { print $1 }')"
  assert_eq 1 "$(printf '%s' "$rows" | grep -c .)" "exactly one $1 target in $NICE_DNS_OPT_TARGETS"
  BC_ALIAS="$rows"
}

bc_characterize() {
  local d rc
  bc_selection
  bc_alias "$1"
  assert_eq "" "${NICE_DNS_TARGET_ADAPTER:-}" "live runs use the real guarded adapter"
  bash "$BC_BASELINE" characterize "$BC_ALIAS" --targets "$NICE_DNS_OPT_TARGETS"
  rc=$?
  d="$ARTIFACT_DIR/baseline/$BC_ALIAS"
  printf '%s\n' "--- observations" && cat "$d/observations.tsv"
  printf '%s\n' "--- findings" && cat "$d/findings.tsv"
  assert_rc 0 "$rc" "every scenario observed and $BC_ALIAS restored"
  assert_eq "$1" "$(awk -F '\t' '$1 == "cell" { split($2, c, "/"); print c[1] }' "$d/cell.tsv")" "cell platform"
  for s in BL-CONFIG BL-COLD BL-WARM BL-SEVERED BL-RESTORED; do
    assert_match "^$s	pass	" "$(cat "$d/observations.tsv")" "$s observed"
  done
  assert_eq 0 "$(cat "$d"/samples-*.tsv | grep -Ec 'Bridge |cert=|pwhash')" "no bridge lines or credential hashes in samples"
  assert_eq 0 "$(cat "$d"/config*.tsv | grep -Ec 'Bridge |cert=|pwhash')" "no bridge lines or credential hashes in configs"
}

t_characterize_linux_cell() { bc_characterize linux; }

t_characterize_macos_cell() { bc_characterize macos; }

t_representative_receipt_verifies() {
  local g="$ARTIFACT_DIR/baseline-global" cells="" p r
  bc_selection
  for p in linux macos; do
    bc_alias "$p"
    assert_file "$ARTIFACT_DIR/baseline/$BC_ALIAS/cell.tsv" "$p cell characterized in this run"
    cells="$cells $ARTIFACT_DIR/baseline/$BC_ALIAS"
  done
  mkdir -p "$g"
  # BL-STAGE: the bounded regression scope at this source revision.
  bash "$NICE_DNS_RUNNER" stage baseline >"$g/stage.log" 2>&1
  assert_rc 0 $? "stage baseline passes at $(git -C "$NICE_DNS_ROOT" rev-parse --short HEAD)"
  {
    printf 'git_head\t%s\n' "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
    grep -E '^(collected|result)=' "$g/stage.log"
  } >"$g/BL-STAGE.txt"
  bash "$NICE_DNS_ROOT/tests/inventory.sh" baseline --out "$g/inventory" >"$g/inventory.log" 2>&1
  assert_rc 0 $? "five-repository inventory"
  cp "$g/inventory/summary.tsv" "$g/BL-INVENTORY.txt"
  # shellcheck disable=SC2086
  r="$(NICE_DNS_BASELINE_GLOBAL_DIR="$g" bash "$BC_BASELINE" receipt --out "$ARTIFACT_DIR/receipt-representative" $cells)"
  assert_rc 0 $? "receipt assembled"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" --require-matrix representative
  assert_rc 0 $? "representative baseline receipt verifies ($r)"
  # PRIV-NO-SECRETS: the portable receipt carries no bridge lines, private
  # keys or credential hashes.
  assert_eq "" "$(grep -rlE 'Bridge obfs4|cert=[A-Za-z0-9+/]{20}|PRIVATE KEY|pwhash' "$(dirname "$r")")" "receipt dir holds no secrets"
}
