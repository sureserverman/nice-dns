# shellcheck shell=bash
# Group unit/report-integrity (sub-plan 05 Task 2.3; ARCH-08, ARCH-09).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR). The
# qualification report (tests/reports/qualification-report.py) from
# synthetic receipt chains built by unit/receipt-verifier's rv_build: it
# reports only a chain that verifies with --require-matrix all, covers every
# cell and every mandatory fault, recomputes its numbers from the pinned
# samples, and labels each proof by kind (actual host only from a passing
# receipt scenario; a missing one says so).

# shellcheck source=tests/unit/receipt-verifier-tests.sh
. "$NICE_DNS_ROOT/tests/unit/receipt-verifier-tests.sh"
for _f in $(declare -F | awk '$3 ~ /^t_/ { print $3 }'); do unset -f "$_f"; done
unset _f

RI="$NICE_DNS_ROOT/tests/reports/qualification-report.py"
ri() { RI_OUT="$(python3 "$RI" "$1" 2>"$CASE_DIR/ri.err")"; RI_RC=$?; RI_ERR="$(cat "$CASE_DIR/ri.err")"; }

# ri_relink <dir>: re-pin every requires row of <dir>/receipt.tsv after a
# linked receipt changed.
ri_relink() {
  awk -F '\t' -v OFS='\t' '$1 == "requires" { cmd = "sha256sum \"" $3 "\""; cmd | getline l; close(cmd); split(l, a, " "); $4 = a[1] } { print }' \
    "$1/receipt.tsv" >"$1/r.new" && mv "$1/r.new" "$1/receipt.tsv"
}

t_report_covers_every_cell_and_fault() {
  local key f inv
  rv_build qualification "$CASE_DIR/q"
  ri "$CASE_DIR/q/receipt.tsv"
  assert_rc 0 "$RI_RC" "a verified chain is reported: $RI_ERR"
  # The inventory section alone: other tables also start rows with a cell.
  inv="$(printf '%s\n' "$RI_OUT" | awk '/^## / { on = ($0 == "## Eight-cell inventory") } on')"
  assert_eq 8 "$(printf '%s\n' "$inv" | grep -c '^| [a-z]*/[a-z]*/[a-z]* | ')" "eight cell rows in the inventory"
  while IFS='	' read -r p x h; do
    case "$p" in ''|'#'*) continue ;; esac
    key="$p/$x/$h"
    assert_match "^\\| $key \\| " "$inv" "the inventory names $key"
  done <"$NICE_DNS_ROOT/tests/manifests/matrix.tsv"
  for f in $(awk -F '\t' '!/^#/ && NF { print $1 }' "$NICE_DNS_ROOT/tests/manifests/faults.tsv"); do
    assert_match "^\\| $f \\| " "$RI_OUT" "the proof table names $f"
  done
  assert_match '^\| FQ-NETWORK-LOSS \| live \| - \| qualification:QU-NETWORK-LOSS, 8 cell\(s\), receipt `run-test-qualification` \|$' "$RI_OUT" \
    "a live-only fault: its actual-host proof, counted"
  assert_match '^\| FQ-WAKE \| fixture\+live \| [^|]*integration/[^|]* \| soak:QU-SOAK, [0-9]+ cell\(s\)' "$RI_OUT" \
    "fixture and actual host side by side, the soak receipt named"
  assert_match 'adopted on 2026-10-04, after the first 24 h soak failed the frozen limits' "$RI_OUT" "the soak rule's history is stated"
  assert_match 'QU-LATENCY means the latency was recorded .* it is not a latency pass' "$RI_OUT" "QU-LATENCY is not read as a latency pass"
  assert_match "Two different comparisons, not to be merged: Stage 1's interleaved" "$RI_OUT" "the two latency comparisons are told apart (DEC-016)"
}

t_unverified_chain_is_never_reported() {
  rv_build qualification "$CASE_DIR/q"
  printf 'tampered\n' >>"$CASE_DIR/q/dep-soak/art/QU-SOAK-linux-haproxy-standard.txt"
  ri "$CASE_DIR/q/receipt.tsv"
  assert_eq 2 "$RI_RC" "a tampered artifact in a linked receipt"
  assert_eq "" "$RI_OUT" "no report at all"
  assert_match 'does not verify' "$RI_ERR" "and says why"
  ri "$CASE_DIR/q/dep-soak/receipt.tsv"
  assert_eq 2 "$RI_RC" "a receipt that is not a qualification receipt"
}

t_numbers_are_recomputed_from_the_samples() {
  local s
  rv_build qualification "$CASE_DIR/q"
  s="$CASE_DIR/q/dep-soak/art/QU-LATENCY-linux-haproxy-standard.txt"
  # 2000 cold samples, elapsed i ms, the first 20 timed out: p50 1000 ms,
  # p95 1900 ms, 20/2000 timeouts, Wilson 95% 0.65%-1.54% (computed by hand).
  awk -F '\t' -v OFS='\t' 'NR <= 2 { print; next } { i++; $4 = i * 1000; if (i <= 20) { $17 = "timeout"; $18 = "-" } print }' "$s" >"$s.new" && mv "$s.new" "$s"
  awk -F '\t' -v OFS='\t' -v f="art/QU-LATENCY-linux-haproxy-standard.txt" '$1 == "scenario" && $5 == f { cmd = "sha256sum \"" ENVIRON["CASE_DIR"] "/q/dep-soak/" f "\""; cmd | getline l; close(cmd); split(l, a, " "); $6 = a[1] } { print }' \
    "$CASE_DIR/q/dep-soak/receipt.tsv" >"$CASE_DIR/q/dep-soak/r.new" && mv "$CASE_DIR/q/dep-soak/r.new" "$CASE_DIR/q/dep-soak/receipt.tsv"
  ri_relink "$CASE_DIR/q"
  ri "$CASE_DIR/q/receipt.tsv"
  assert_rc 0 "$RI_RC" "the re-pinned chain is reported: $RI_ERR"
  assert_match '^\| linux/haproxy/standard \| cold \| [0-9]+ \| [^|]+ \| [^|]+ \| [^|]+ \| 2000 \| 1000 ms \| 1900 ms \| 20/2000 \(0\.65%-1\.54%\) \|$' "$RI_OUT" \
    "after: n, p50, p95, timeouts and their interval, recomputed"
}

t_a_missing_live_proof_is_named_missing() {
  local m="$CASE_DIR/man"
  cp -R "$NICE_DNS_ROOT/tests/manifests" "$m"
  awk -F '\t' -v OFS='\t' '$1 == "FQ-NETWORK-LOSS" { $3 = "qualification:QU-NOT-RECORDED" } { print }' "$m/faults.tsv" >"$m/f.new" && mv "$m/f.new" "$m/faults.tsv"
  rv_build qualification "$CASE_DIR/q"
  RI_OUT="$(NICE_DNS_TEST_MANIFESTS="$m" python3 "$RI" "$CASE_DIR/q/receipt.tsv" 2>/dev/null)"
  assert_match '^\| FQ-NETWORK-LOSS \| live \| - \| \*\*missing\*\* \(qualification:QU-NOT-RECORDED not pass\) \|$' "$RI_OUT" \
    "a live proof the receipt lacks is missing, never assumed"
}

t_a_fixture_only_fault_is_labelled_fixture() {
  local f
  rv_build qualification "$CASE_DIR/q"
  ri "$CASE_DIR/q/receipt.tsv"
  for f in $(awk -F '\t' '!/^#/ && NF && $2 == "fixture" { print $1 }' "$NICE_DNS_ROOT/tests/manifests/faults.tsv"); do
    assert_match "^\\| $f \\| fixture \\| [^|-][^|]* \\| - \\|\$" "$RI_OUT" "$f: fixture proofs listed, no actual-host claim"
  done
}
