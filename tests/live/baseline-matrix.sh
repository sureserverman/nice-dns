# shellcheck shell=bash
# Group live/baseline-matrix (sub-plan 01, Task 2.3 final-gate collection;
# ARCH-09). Run by `tests/run.sh plan baseline ... --matrix all`.
#
# Installs each of the eight runtime cells on the target of its platform
# with the product's own installer at one pinned nice-dns commit, waits for
# the first answered uncached query, characterizes it (tests/live/baseline.sh)
# and finally leaves each target on the cell it ran before the run, freshly
# installed. Then it assembles the baseline receipt, including the frozen
# per-platform targets (BL-TARGETS), into <artifact root>/receipts/baseline/
# RUN_ID/ and verifies it with --require-matrix all. A cell that cannot be
# installed or observed fails its case: skipped cells are never green.
#
# Cases run in name order: the two platforms' cells run concurrently inside
# t_1_cells (different hosts), then t_2_receipt.

BM_BASELINE="$NICE_DNS_ROOT/tests/live/baseline.sh"

bm_selection() {
  assert_eq all "${NICE_DNS_OPT_MATRIX:-}" "--matrix all"
  assert_eq 1 "${NICE_DNS_OPT_INCLUDE_SLOW:-}" "--include-slow (installs and bootstraps are slow)"
  assert_eq 1 "${NICE_DNS_OPT_FRESH_FIXTURES:-}" "--fresh-fixtures (a new artifact namespace)"
  assert_eq "" "${NICE_DNS_TARGET_ADAPTER:-}" "live runs use the real guarded adapter"
}

bm_alias() {
  local rows
  rows="$(bash "$NICE_DNS_ROOT/tests/live/target.sh" validate --targets "$NICE_DNS_OPT_TARGETS" | awk -F '\t' -v p="$1" '$2 == p { print $1 }')"
  assert_eq 1 "$(printf '%s' "$rows" | grep -c .)" "exactly one $1 target in $NICE_DNS_OPT_TARGETS"
  BM_ALIAS="$rows"
}

t_1_cells() {
  local lin mac pl pm rl rm sha
  bm_selection
  sha="$(git -C "$NICE_DNS_ROOT" rev-parse origin/main)"
  assert_match '^[0-9a-f]{40}$' "$sha" "pinned product commit (origin/main)"
  bm_alias linux; lin="$BM_ALIAS"
  bm_alias macos; mac="$BM_ALIAS"
  bash "$BM_BASELINE" matrix "$lin" --targets "$NICE_DNS_OPT_TARGETS" --source-sha "$sha" >"$CASE_DIR/linux.log" 2>&1 &
  pl=$!
  bash "$BM_BASELINE" matrix "$mac" --targets "$NICE_DNS_OPT_TARGETS" --source-sha "$sha" >"$CASE_DIR/macos.log" 2>&1 &
  pm=$!
  wait "$pl"; rl=$?
  wait "$pm"; rm=$?
  tail -n 40 "$CASE_DIR/linux.log" "$CASE_DIR/macos.log"
  assert_rc 0 "$rl" "all four linux cells observed and $lin back on its original cell"
  assert_rc 0 "$rm" "all four macos cells observed and $mac back on its original cell"
}

t_2_receipt() {
  local g="$ARTIFACT_DIR/baseline-global" root r d cells=""
  bm_selection
  for d in "$ARTIFACT_DIR"/baseline/*/cell.tsv; do
    [ -f "$d" ] && cells="$cells $(dirname "$d")"
  done
  assert_eq 8 "$(printf '%s\n' $cells | grep -c .)" "eight characterized cells in this run"
  mkdir -p "$g"
  bash "$NICE_DNS_RUNNER" stage baseline >"$g/stage.log" 2>&1
  assert_rc 0 $? "stage baseline passes at $(git -C "$NICE_DNS_ROOT" rev-parse --short HEAD)"
  {
    printf 'git_head\t%s\n' "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
    grep -E '^(collected|result)=' "$g/stage.log"
  } >"$g/BL-STAGE.txt"
  bash "$NICE_DNS_ROOT/tests/inventory.sh" baseline --out "$g/inventory" >"$g/inventory.log" 2>&1
  assert_rc 0 $? "five-repository inventory"
  cp "$g/inventory/summary.tsv" "$g/BL-INVENTORY.txt"
  root="${NICE_DNS_TEST_ARTIFACTS:-${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns-tests}"
  # shellcheck disable=SC2086
  r="$(NICE_DNS_BASELINE_GLOBAL_DIR="$g" bash "$BM_BASELINE" receipt --out "$root/receipts/baseline/$RUN_ID" $cells)"
  assert_rc 0 $? "receipt assembled"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" --require-matrix all
  assert_rc 0 $? "eight-cell baseline receipt verifies ($r)"
  assert_eq "" "$(grep -rlE 'Bridge obfs4|cert=[A-Za-z0-9+/]{20}|PRIVATE KEY|pwhash' "$(dirname "$r")")" "receipt dir holds no secrets"
}
