# shellcheck shell=bash
# Group unit/performance-acceptance (sub-plan 05, Task 1.1; ARCH-09, DEC-001).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, ARTIFACT_DIR,
# CASE_DIR exported). Covers the frozen acceptance manifest
# (tests/manifests/performance-acceptance.tsv) and its generator/comparator
# (tests/reports/perf-acceptance.py) against known vectors: every guard has
# a negative case. Synthetic sample files use the nice-dns-sample/1 schema.
#
# t_committed_manifest_equals_fresh_derivation reads the private frozen
# baseline receipt under the artifact root (the dev host holds it); without
# it the case fails, it is never skipped.

PA_TOOL="$NICE_DNS_ROOT/tests/reports/perf-acceptance.py"
PA_MANIFEST="$NICE_DNS_ROOT/tests/manifests/performance-acceptance.tsv"
PA_ID='20260101T000000Z-synthetic'
PA_COLS='run_id	sample_id	utc_start	elapsed_us	workload	cache_class	target_id	platform	proxy	pihole	source_rev	images	resolver	transport	qname	qtype	outcome	rcode	timeout_ms'

pa_bl_targets() {
  # Synthetic frozen receipt with the real receipt's shape and numbers; sets PA_BL.
  local d="$CASE_DIR/receipts/baseline/$PA_ID"
  mkdir -p "$d"
  PA_BL="$d/BL-TARGETS.txt"
  printf '%b' '# nice-dns baseline targets, synthetic\n' \
    'coverage\t8 cells\n' \
    'rule\tno-timeout-regression: per cell and workload, a candidate timeout_rate must not exceed the baseline timeout_rate\n' \
    'rule\timprove-problem-class: per platform, at least one previously problematic cold/idle/post-wake class improves beyond measured variability (interleaved runs, same workload)\n' \
    'rule\tsecurity-absolute: no latency target is met by weakening TLS, DNSSEC or the no-direct-resolver guarantees\n' \
    'cell\tmacos/haproxy/hardened\tcold\tattempted=30\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=258778\tp95_all_us=363358\tp99_all_us=366114\tp95_support=exploratory\n' \
    'cell\tmacos/haproxy/hardened\twarm\tattempted=1000\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=4355\tp95_all_us=4605\tp99_all_us=4798\tp95_support=supported\n' \
    'cell\tmacos/haproxy/standard\tcold\tattempted=30\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=122634\tp95_all_us=173254\tp99_all_us=193632\tp95_support=exploratory\n' \
    'cell\tmacos/haproxy/standard\twarm\tattempted=1000\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=4277\tp95_all_us=4516\tp99_all_us=4600\tp95_support=supported\n' \
    'cell\tmacos/socat/hardened\tcold\tattempted=30\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=258682\tp95_all_us=437890\tp99_all_us=438046\tp95_support=exploratory\n' \
    'cell\tmacos/socat/hardened\twarm\tattempted=1000\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=4383\tp95_all_us=4733\tp99_all_us=5735\tp95_support=supported\n' \
    'cell\tmacos/socat/standard\tcold\tattempted=30\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=296799\tp95_all_us=635932\tp99_all_us=668795\tp95_support=exploratory\n' \
    'cell\tmacos/socat/standard\twarm\tattempted=1000\ttimeout_rate=0.0000\tfailure_rate=0.0010\tp50_all_us=4368\tp95_all_us=4675\tp99_all_us=4834\tp95_support=supported\n' \
    'cell\tlinux/haproxy/hardened\tcold\tattempted=30\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=651989\tp95_all_us=2006251\tp99_all_us=2190277\tp95_support=exploratory\n' \
    'cell\tlinux/haproxy/hardened\twarm\tattempted=1000\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=28224\tp95_all_us=30752\tp99_all_us=34424\tp95_support=supported\n' \
    'cell\tlinux/haproxy/standard\tcold\tattempted=30\ttimeout_rate=0.2333\tfailure_rate=0.2333\tp50_all_us=2933962\tp95_all_us=inf\tp99_all_us=inf\tp95_support=exploratory\n' \
    'cell\tlinux/haproxy/standard\twarm\tattempted=1000\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=28179\tp95_all_us=30644\tp99_all_us=33681\tp95_support=supported\n' \
    'cell\tlinux/socat/hardened\tcold\tattempted=30\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=1045219\tp95_all_us=1659231\tp99_all_us=3706175\tp95_support=exploratory\n' \
    'cell\tlinux/socat/hardened\twarm\tattempted=1000\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=28165\tp95_all_us=30512\tp99_all_us=33441\tp95_support=supported\n' \
    'cell\tlinux/socat/standard\tcold\tattempted=30\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=1158331\tp95_all_us=1415202\tp99_all_us=3384766\tp95_support=exploratory\n' \
    'cell\tlinux/socat/standard\twarm\tattempted=1000\ttimeout_rate=0.0000\tfailure_rate=0.0000\tp50_all_us=28099\tp95_all_us=30298\tp99_all_us=32321\tp95_support=supported\n' \
    'target\tlinux\tcold\ttimeout_rate_max=0.2333\tp95_all_us_max=inf\n' \
    'target\tlinux\twarm\ttimeout_rate_max=0.0000\tp95_all_us_max=30752\n' \
    'target\tmacos\tcold\ttimeout_rate_max=0.0000\tp95_all_us_max=635932\n' \
    'target\tmacos\twarm\ttimeout_rate_max=0.0000\tp95_all_us_max=4733\n' >"$PA_BL"
}

pa_setup() {
  # pa_setup <cell>: synthetic receipt, its derived manifest, empty arms.
  PA_CELL="$1"
  pa_bl_targets
  PA_M="$CASE_DIR/manifest.tsv"
  python3 "$PA_TOOL" derive "$PA_BL" >"$PA_M" || fail "derive from the synthetic receipt failed"
  PA_B="$CASE_DIR/base.tsv" PA_C="$CASE_DIR/cand.tsv"
  rm -f "${PA_B:?}" "${PA_C:?}"
}

pa_seq() {
  # pa_seq <n> <start> <step>: n integers.
  seq -f '%.0f' "$2" "$3" "$(($2 + ($1 - 1) * $3))"
}

pa_rep() {
  # pa_rep <n> <token>
  local i=0
  while [ "$i" -lt "$1" ]; do printf '%s\n' "$2"; i=$((i + 1)); done
}

pa_append() {
  # pa_append <file> <arm 0|1> <workload> <cache_class> <block> <day> <values>
  # Appends one row per value (newline-separated). Values: <us> answered
  # NOERROR; NX:<us> NXDOMAIN; SF:<us> SERVFAIL; TO timeout. Arms alternate
  # in blocks of <block> samples on day <day> (block >= n: not interleaved).
  local f="$1" arm="$2" w="$3" cls="$4" blk="$5" day="$6" vals="$7" next
  [ -f "$f" ] || printf '# schema\tnice-dns-sample/1\n%s\n' "$PA_COLS" >"$f"
  next=$(( $(grep -vc '^#' "$f") ))
  printf '%s\n' "$vals" | awk -v OFS='\t' -v arm="$arm" -v w="$w" -v cls="$cls" -v blk="$blk" \
    -v day="$day" -v id="$next" -v cell="$PA_CELL" '
    BEGIN { split(cell, c, "/") }
    NF == 0 { next }
    {
      i = n++; slot = (2 * int(i / blk) + arm) * blk + (i % blk)
      ts = sprintf("2026-01-%02dT%02d:%02d:%02d.000000Z", day, int(slot / 3600), int((slot % 3600) / 60), slot % 60)
      v = $1; oc = "ok"; rc = "NOERROR"; e = v
      if (v == "TO") { oc = "timeout"; rc = "-"; e = 5000000 }
      else if (v ~ /^NX:/) { oc = "nxdomain"; rc = "NXDOMAIN"; e = substr(v, 4) }
      else if (v ~ /^SF:/) { oc = "servfail"; rc = "SERVFAIL"; e = substr(v, 4) }
      print (arm ? "run-cand" : "run-base"), id + i, ts, e, w, cls, "t", c[1], c[2], c[3], \
        "rev-" arm, "img-" arm, "127.0.0.1#53", "udp", "q.example.com", "A", oc, rc, 5000
    }' >>"$f"
}

pa_arms() {
  # pa_arms <workload> <cache_class> <day> <block> <base values> <cand values>
  [ -n "$5" ] && pa_append "$PA_B" 0 "$1" "$2" "$4" "$3" "$5"
  [ -n "$6" ] && pa_append "$PA_C" 1 "$1" "$2" "$4" "$3" "$6"
  return 0
}

pa_cell_data() {
  # Both arms, all four workloads, clean and equal, unless PA_{COLD,WARM,IDLE,WAKE}_{B,C}
  # (newline-separated values; the word NONE for no rows) override one.
  local cb cc wb wc ib ic kb kc
  cb="${PA_COLD_B:-$(pa_seq 30 200000 10000)}" cc="${PA_COLD_C:-$(pa_seq 30 200000 10000)}"
  wb="${PA_WARM_B:-$(pa_seq 1000 3000 1)}" wc="${PA_WARM_C:-$(pa_seq 1000 3000 1)}"
  ib="${PA_IDLE_B:-$(pa_seq 30 30000 1000)}" ic="${PA_IDLE_C:-$(pa_seq 30 30000 1000)}"
  kb="${PA_WAKE_B:-$(pa_seq 30 900000 30000)}" kc="${PA_WAKE_C:-$(pa_seq 30 900000 30000)}"
  [ "$cb" = NONE ] && cb=''
  [ "$cc" = NONE ] && cc=''
  [ "$ib" = NONE ] && ib=''
  [ "$ic" = NONE ] && ic=''
  [ "$kb" = NONE ] && kb=''
  [ "$kc" = NONE ] && kc=''
  pa_arms cold miss 1 "${PA_COLD_BLOCK:-5}" "$cb" "$cc"
  pa_arms warm hit 2 100 "$wb" "$wc"
  pa_arms idle hit-after-idle 3 5 "$ib" "$ic"
  pa_arms wake after-wake 4 5 "$kb" "$kc"
}

pa_compare() {
  PA_OUT="$(python3 "$PA_TOOL" compare --manifest "${PA_USE_M:-$PA_M}" --bl-targets "$PA_BL" \
    --cell "$PA_CELL" --baseline "$PA_B" --candidate "$PA_C" 2>&1)"
  PA_RC=$?
}

pa_verdict() {
  # pa_verdict <workload>: that workload row's verdict.
  printf '%s\n' "$PA_OUT" | awk -F '\t' -v w="$1" '$1 == "workload" && $3 == w { print $4 }'
}

pa_field() {
  # pa_field <workload> <key>: key=value from that workload row.
  printf '%s\n' "$PA_OUT" | awk -F '\t' -v w="$1" -v k="$2" '
    $1 == "workload" && $3 == w { for (i = 5; i <= NF; i++) if (index($i, k "=") == 1) print substr($i, length(k) + 2) }'
}

pa_cell_verdict() {
  printf '%s\n' "$PA_OUT" | awk -F '\t' '$1 == "cell" { print $3 }'
}

pa_cell_improved() {
  printf '%s\n' "$PA_OUT" | awk -F '\t' '$1 == "cell" { for (i = 4; i <= NF; i++) if ($i ~ /^improved=/) print substr($i, 10) }'
}

# Cold vectors for the unfavorable linux/haproxy/standard class: 23 answers
# of 2.0-3.1 s and 7 timeouts spread through the run (the frozen 7/30).
pa_cold_unfavorable() {
  local i=0 v
  for v in $(pa_seq 23 2000000 50000); do
    i=$((i + 1))
    printf '%s\n' "$v"
    case "$i" in 3|6|9|12|15|18|21) printf 'TO\n' ;; esac
  done
}

# ─────────────── frozen manifest ───────────────

t_committed_manifest_equals_fresh_derivation() {
  local root id bl sum
  assert_file "$PA_MANIFEST" "committed acceptance manifest"
  assert_file "$PA_TOOL" "generator/comparator"
  id="$(awk -F '\t' '$1 == "provenance" && $2 == "baseline_receipt" { print $3 }' "$PA_MANIFEST")"
  assert_match '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$' "$id" "manifest names its frozen baseline receipt"
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  bl="$root/receipts/baseline/$id/BL-TARGETS.txt"
  assert_file "$bl" "private frozen baseline receipt present on this host"
  sum="$(sha256sum "$bl" | cut -d ' ' -f 1)"
  assert_eq "$sum" "$(awk -F '\t' '$1 == "provenance" && $2 == "bl_targets_sha256" { print $3 }' "$PA_MANIFEST")" \
    "manifest carries the receipt's sha256"
  python3 "$PA_TOOL" derive "$bl" >"$CASE_DIR/fresh.tsv"
  assert_rc 0 $? "fresh derivation"
  assert_eq "" "$(diff "$PA_MANIFEST" "$CASE_DIR/fresh.tsv")" "committed manifest equals a fresh derivation"
  python3 "$PA_TOOL" check-manifest --manifest "$PA_MANIFEST" --bl-targets "$bl" >/dev/null 2>&1
  assert_rc 0 $? "check-manifest accepts the committed manifest"
  assert_eq 32 "$(grep -c '^limit	' "$PA_MANIFEST")" "one limit row per cell and workload (8 x 4)"
  assert_match '^limit	linux/haproxy/standard	cold	source=frozen	budget=30	timeouts=7/30	failures=7/30	.*p95_all_us=inf' \
    "$(cat "$PA_MANIFEST")" "the unfavorable cold class stays recorded with its 7/30 timeouts and p95 inf"
}

t_hand_loosened_manifest_is_refused() {
  local out
  pa_setup linux/socat/standard
  python3 "$PA_TOOL" check-manifest --manifest "$PA_M" --bl-targets "$PA_BL" >/dev/null 2>&1
  assert_rc 0 $? "an untouched derivation is accepted"
  sed 's/^\(limit	linux\/socat\/standard	cold	.*\)timeouts=0\/30/\1timeouts=1\/30/' "$PA_M" >"$CASE_DIR/loose.tsv"
  assert_ne "$(cat "$PA_M")" "$(cat "$CASE_DIR/loose.tsv")" "the loosening edit applied"
  out="$(python3 "$PA_TOOL" check-manifest --manifest "$CASE_DIR/loose.tsv" --bl-targets "$PA_BL" 2>&1)"
  assert_nonzero $? "a hand-loosened timeout limit is refused"
  assert_match 'differs from a fresh derivation' "$out" "refusal names the cause"
  sed 's/^\(limit	linux\/socat\/standard	cold	source=frozen	\)budget=30/\1budget=20/' "$PA_M" >"$CASE_DIR/loose.tsv"
  out="$(python3 "$PA_TOOL" check-manifest --manifest "$CASE_DIR/loose.tsv" --bl-targets "$PA_BL" 2>&1)"
  assert_nonzero $? "a lowered sample budget is refused"
  pa_cell_data
  PA_USE_M="$CASE_DIR/loose.tsv" pa_compare
  assert_eq 2 "$PA_RC" "compare refuses a loosened manifest: $PA_OUT"
  printf '# edited\n' >>"$PA_BL"
  out="$(python3 "$PA_TOOL" check-manifest --manifest "$PA_M" --bl-targets "$PA_BL" 2>&1)"
  assert_nonzero $? "a changed baseline receipt no longer matches the manifest's provenance"
  assert_match "does not match the manifest's bl_targets_sha256" "$out" "refusal names the digest"
}

t_derive_refuses_incomplete_receipt() {
  local out
  pa_setup linux/socat/standard
  cp "$PA_BL" "$CASE_DIR/orig.txt"
  grep -v '^rule	security-absolute' "$CASE_DIR/orig.txt" >"$PA_BL"
  out="$(python3 "$PA_TOOL" derive "$PA_BL" 2>&1)"
  assert_rc 2 $? "a receipt without a frozen rule is refused"
  assert_match 'security-absolute' "$out" "refusal names the rule"
  sed 's/^coverage	8 cells/coverage	7 cells/' "$CASE_DIR/orig.txt" >"$PA_BL"
  out="$(python3 "$PA_TOOL" derive "$PA_BL" 2>&1)"
  assert_rc 2 $? "a coverage line that disagrees with the matrix is refused"
  assert_match 'coverage' "$out" "refusal names the coverage"
  grep -v '^target	macos	cold' "$CASE_DIR/orig.txt" >"$PA_BL"
  out="$(python3 "$PA_TOOL" derive "$PA_BL" 2>&1)"
  assert_rc 2 $? "a receipt without a platform target is refused"
  assert_match 'macos has no cold target' "$out" "refusal names the target"
}

t_derive_keeps_unfavorable_baseline_class() {
  local out
  pa_setup linux/haproxy/standard
  assert_match '^limit	linux/haproxy/standard	cold	source=frozen	budget=30	timeouts=7/30	failures=7/30	p50_all_us=2933962	p95_all_us=inf	p99_all_us=inf	p95_support=exploratory$' \
    "$(cat "$PA_M")" "unfavorable class recorded, not dropped"
  assert_match '^target	linux	cold	timeout_rate_max=0.2333	p95_all_us_max=inf$' "$(cat "$PA_M")" "platform target carried"
  assert_match '^limit	linux/socat/standard	cold	source=frozen	budget=30	timeouts=0/30	' "$(cat "$PA_M")" "a zero-timeout cell allows zero timeouts"
  assert_match '^limit	linux/haproxy/standard	idle	source=same-session	budget=30	timeouts=arm	failures=arm$' "$(cat "$PA_M")" "idle compared against the same-session arm"
  grep -v '^cell	linux/haproxy/standard	cold	' "$PA_BL" >"$PA_BL.cut"
  mv "$PA_BL.cut" "$PA_BL"
  out="$(python3 "$PA_TOOL" derive "$PA_BL" 2>&1)"
  assert_rc 2 $? "a receipt missing the unfavorable class is refused, not derived without it"
  assert_match 'linux/haproxy/standard' "$out" "refusal names the cell"
}

t_derive_refuses_rate_that_is_not_a_count() {
  local out
  pa_setup linux/socat/standard
  sed 's/^\(cell	linux\/socat\/standard	cold	attempted=30	\)timeout_rate=0.0000/\1timeout_rate=0.0100/' "$PA_BL" >"$PA_BL.x"
  mv "$PA_BL.x" "$PA_BL"
  out="$(python3 "$PA_TOOL" derive "$PA_BL" 2>&1)"
  assert_rc 2 $? "0.0100 of 30 attempts is no whole count"
  assert_match 'count' "$out" "refusal names the cause"
}

# ─────────────── guards ───────────────

t_extra_timeout_on_zero_timeout_cell_fails() {
  pa_setup linux/socat/standard
  PA_COLD_C="$(pa_seq 29 200000 10000; printf 'TO\n')" pa_cell_data
  pa_compare
  assert_eq 1 "$PA_RC" "a failing comparison exits 1: $PA_OUT"
  assert_eq fail "$(pa_verdict cold)" "cold verdict"
  assert_eq fail "$(pa_field cold timeout)" "timeout check"
  assert_eq "1/30" "$(pa_field cold timeouts_cand)" "the timeout is counted"
  assert_eq "0/30" "$(pa_field cold timeout_limit)" "frozen zero limit"
  assert_eq fail "$(pa_cell_verdict)" "cell verdict"
  pa_setup linux/socat/standard
  pa_cell_data
  pa_compare
  assert_rc 0 "$PA_RC" "the same cell without the timeout passes: $PA_OUT"
  assert_eq pass "$(pa_field cold timeout)" "timeout check passes at 0/30"
}

t_unfavorable_cell_allows_its_frozen_count_only() {
  pa_setup linux/haproxy/standard
  PA_COLD_B="$(pa_cold_unfavorable)" PA_COLD_C="$(pa_cold_unfavorable)" pa_cell_data
  pa_compare
  assert_eq pass "$(pa_field cold timeout)" "7/30 against the frozen 7/30: $PA_OUT"
  assert_eq "7/30" "$(pa_field cold timeout_limit)" "limit is the frozen count"
  pa_setup linux/haproxy/standard
  PA_COLD_B="$(pa_cold_unfavorable)" PA_COLD_C="$(pa_cold_unfavorable | sed '1s/.*/TO/')" pa_cell_data
  pa_compare
  assert_eq "8/30" "$(pa_field cold timeouts_cand)" "one more timeout: $PA_OUT"
  assert_eq fail "$(pa_field cold timeout)" "8/30 exceeds the frozen 7/30"
  assert_eq fail "$(pa_verdict cold)" "cold verdict"
}

t_frozen_limit_not_loosened_by_worse_baseline_arm() {
  # A same-session baseline arm with 10 timeouts must not lift the frozen 7/30.
  pa_setup linux/haproxy/standard
  PA_COLD_B="$(pa_seq 20 2000000 50000; pa_rep 10 TO)" \
    PA_COLD_C="$(pa_seq 22 2000000 50000; pa_rep 8 TO)" PA_COLD_BLOCK=5 pa_cell_data
  pa_compare
  assert_eq "10/30" "$(pa_field cold timeouts_base)" "degraded baseline arm: $PA_OUT"
  assert_eq "7/30" "$(pa_field cold timeout_limit)" "warm/cold limits stay frozen"
  assert_eq fail "$(pa_field cold timeout)" "8/30 fails the frozen 7/30 although the arm had 10/30"
}

t_too_few_samples_are_insufficient() {
  pa_setup linux/socat/standard
  PA_COLD_B="$(pa_seq 29 200000 10000)" PA_COLD_C="$(pa_seq 29 200000 10000)" \
    PA_WARM_C="$(pa_seq 999 3000 1)" pa_cell_data
  pa_compare
  assert_eq 1 "$PA_RC" "insufficient is never green: $PA_OUT"
  assert_eq insufficient "$(pa_verdict cold)" "29 cold trials per arm"
  assert_eq insufficient "$(pa_verdict warm)" "999 warm samples in the candidate arm"
  assert_eq pass "$(pa_verdict idle)" "idle at budget"
  assert_eq insufficient "$(pa_cell_verdict)" "cell verdict"
}

t_idle_without_baseline_arm_is_blocked() {
  pa_setup linux/socat/standard
  PA_IDLE_B=NONE pa_cell_data
  pa_compare
  assert_eq 1 "$PA_RC" "blocked is never green: $PA_OUT"
  assert_eq blocked "$(pa_verdict idle)" "idle without a same-session baseline arm"
  assert_match 'baseline arm' "$(pa_field idle reason)" "reason names the missing arm"
  assert_eq blocked "$(pa_cell_verdict)" "cell verdict"
  pa_setup linux/socat/standard
  PA_WAKE_C=NONE pa_cell_data
  pa_compare
  assert_eq blocked "$(pa_verdict wake)" "a candidate without wake rows is blocked: $PA_OUT"
  assert_eq blocked "$(pa_cell_verdict)" "missing rows are never green"
}

t_non_interleaved_arms_are_refused() {
  pa_setup linux/socat/standard
  PA_COLD_BLOCK=30 pa_cell_data
  pa_compare
  assert_eq 2 "$PA_RC" "sequential arms are refused: $PA_OUT"
  assert_match 'interleav' "$PA_OUT" "refusal names interleaving"
  pa_setup linux/socat/standard
  PA_COLD_BLOCK=6 pa_cell_data
  pa_compare
  assert_rc 0 "$PA_RC" "blocks of ceil(30/5)=6 alternate enough: $PA_OUT"
  pa_setup linux/socat/standard
  PA_COLD_BLOCK=7 pa_cell_data
  pa_compare
  assert_eq 2 "$PA_RC" "a block of 7 exceeds the bound: $PA_OUT"
  pa_setup linux/socat/standard
  PA_COLD_B="$(pa_seq 16 200000 10000)" PA_COLD_C="$(pa_seq 16 200000 10000)" PA_COLD_BLOCK=4 pa_cell_data
  pa_compare
  assert_eq 2 "$PA_RC" "16 samples in 4 runs of 4 per arm: fewer than 5 runs: $PA_OUT"
  assert_match 'fewer than 5' "$PA_OUT" "refusal names the run count"
}

t_clock_step_is_refused() {
  pa_setup linux/socat/standard
  pa_cell_data
  awk -F '\t' -v OFS='\t' '$2 == "3" { $3 = "2026-01-01T00:00:00.000000Z" } { print }' "$PA_C" >"$PA_C.x"
  mv "$PA_C.x" "$PA_C"
  pa_compare
  assert_eq 2 "$PA_RC" "utc_start going backwards inside an arm is refused: $PA_OUT"
  assert_match 'backwards' "$PA_OUT" "refusal names the clock step"
}

t_deleted_sample_row_is_refused() {
  pa_setup linux/socat/standard
  PA_COLD_C="$(pa_seq 29 200000 10000; printf 'TO\n')" pa_cell_data
  awk -F '\t' '$2 != "30"' "$PA_C" >"$PA_C.cut"
  mv "$PA_C.cut" "$PA_C"
  pa_compare
  assert_eq 2 "$PA_RC" "a file with a deleted row is refused: $PA_OUT"
  assert_match 'missing' "$PA_OUT" "refusal names the gap (stats.sh rule)"
}

t_cache_classes_are_never_pooled() {
  pa_setup linux/socat/standard
  pa_cell_data
  awk -F '\t' -v OFS='\t' '$2 == "5" { $6 = "hit" } { print }' "$PA_C" >"$PA_C.mix"
  mv "$PA_C.mix" "$PA_C"
  pa_compare
  assert_eq 2 "$PA_RC" "a cold row labelled hit is refused: $PA_OUT"
  assert_match 'cache_class' "$PA_OUT" "refusal names the class"
}

t_arms_must_share_controls() {
  pa_setup linux/socat/standard
  pa_cell_data
  awk -F '\t' -v OFS='\t' 'NR > 2 && $5 == "cold" { $19 = 3000 } { print }' "$PA_C" >"$PA_C.x"
  mv "$PA_C.x" "$PA_C"
  pa_compare
  assert_eq 2 "$PA_RC" "arms with different timeout budgets are not the same workload: $PA_OUT"
  assert_match 'timeout_ms' "$PA_OUT" "refusal names the control"
  pa_setup linux/socat/standard
  pa_cell_data
  PA_C="$PA_B" pa_compare
  assert_eq 2 "$PA_RC" "one run as both arms is refused: $PA_OUT"
  pa_setup linux/socat/standard
  pa_cell_data
  PA_CELL=linux/socat/hardened pa_compare
  assert_eq 2 "$PA_RC" "samples of another cell are refused: $PA_OUT"
}

# ─────────────── improvement ───────────────

t_clear_improvement_passes() {
  pa_setup linux/haproxy/standard
  PA_COLD_B="$(pa_cold_unfavorable)" PA_COLD_C="$(pa_seq 30 400000 10000)" pa_cell_data
  pa_compare
  assert_rc 0 "$PA_RC" "clear improvement with no regression: $PA_OUT"
  assert_eq yes "$(pa_field cold improvement)" "cold improved beyond variability"
  assert_eq pass "$(pa_verdict cold)" "cold verdict"
  assert_eq cold "$(pa_cell_improved)" "cell lists the improved class"
  assert_match '^[1-9][0-9]*$' "$(pa_field cold gain_lo_us)" "lower bound of the gain is positive"
  assert_eq "inf" "$(pa_field cold p95_base)" "baseline arm keeps its timeouts as worst case"
}

t_noise_difference_is_not_improvement() {
  pa_setup linux/socat/standard
  PA_COLD_C="$(pa_seq 30 198000 9900)" pa_cell_data
  pa_compare
  assert_rc 0 "$PA_RC" "noise-level candidate still passes its limits: $PA_OUT"
  assert_eq no "$(pa_field cold improvement)" "a 1% shift is inside measured variability"
  assert_eq none "$(pa_cell_improved)" "nothing improved"
  pa_setup linux/socat/standard
  pa_cell_data
  pa_compare
  assert_eq no "$(pa_field cold improvement)" "identical arms never improve"
  assert_eq no "$(pa_field wake improvement)" "identical arms never improve (wake)"
}

t_improvement_needs_family_corrected_evidence() {
  # An 80 ms shift of 30 evenly spread trials has P(gain <= 0) = 0.023: it
  # would pass at 0.05 alone, not at 0.05/12 (every cell x problem class of a
  # platform). A 130 ms shift has P = 0.0003 and counts.
  pa_setup linux/socat/standard
  PA_COLD_C="$(pa_seq 30 120000 10000)" pa_cell_data
  pa_compare
  assert_eq 0.004167 "$(pa_field cold alpha)" "per-comparison alpha: $PA_OUT"
  assert_eq no "$(pa_field cold improvement)" "evidence at 0.023 is not enough after correction"
  pa_setup linux/socat/standard
  PA_COLD_C="$(pa_seq 30 70000 10000)" pa_cell_data
  pa_compare
  assert_eq yes "$(pa_field cold improvement)" "evidence at 0.0003 counts: $PA_OUT"
}

t_problem_class_slowdown_fails() {
  pa_setup linux/socat/standard
  PA_WAKE_C="$(pa_seq 30 3000000 30000)" pa_cell_data
  pa_compare
  assert_eq slower "$(pa_field wake latency)" "wake slower beyond variability: $PA_OUT"
  assert_eq fail "$(pa_verdict wake)" "a slower problem class fails"
}

t_steady_warm_is_not_a_problem_class() {
  pa_setup linux/socat/standard
  PA_WARM_C="$(pa_seq 1000 1500 1)" pa_cell_data
  pa_compare
  assert_eq n/a "$(pa_field warm improvement)" "warm never counts as the improved class: $PA_OUT"
  assert_eq none "$(pa_cell_improved)" "no problem class improved"
}

t_platform_needs_an_improved_problem_class() {
  local c out n=0
  for c in linux/haproxy/hardened linux/socat/standard linux/socat/hardened; do
    n=$((n + 1))
    pa_setup "$c"
    pa_cell_data
    pa_compare
    printf '%s\n' "$PA_OUT" >"$CASE_DIR/r$n.tsv"
  done
  pa_setup linux/haproxy/standard
  PA_COLD_B="$(pa_cold_unfavorable)" PA_COLD_C="$(pa_cold_unfavorable)" pa_cell_data
  pa_compare
  printf '%s\n' "$PA_OUT" >"$CASE_DIR/r-flat.tsv"
  pa_setup linux/haproxy/standard
  PA_COLD_B="$(pa_cold_unfavorable)" PA_COLD_C="$(pa_seq 30 400000 10000)" pa_cell_data
  pa_compare
  printf '%s\n' "$PA_OUT" >"$CASE_DIR/r-better.tsv"
  out="$(python3 "$PA_TOOL" summarize --manifest "$PA_M" --bl-targets "$PA_BL" --platform linux \
    "$CASE_DIR"/r1.tsv "$CASE_DIR"/r2.tsv "$CASE_DIR"/r3.tsv "$CASE_DIR"/r-flat.tsv 2>&1)"
  assert_eq 1 $? "no improved problem class: $out"
  assert_match '^platform	linux	fail	' "$out" "platform fails without an improvement"
  out="$(python3 "$PA_TOOL" summarize --manifest "$PA_M" --bl-targets "$PA_BL" --platform linux \
    "$CASE_DIR"/r1.tsv "$CASE_DIR"/r2.tsv "$CASE_DIR"/r3.tsv "$CASE_DIR"/r-better.tsv 2>&1)"
  assert_eq 0 $? "one improved class on the platform: $out"
  assert_match '^platform	linux	pass	.*improved=linux/haproxy/standard:cold' "$out" "platform passes"
  out="$(python3 "$PA_TOOL" summarize --manifest "$PA_M" --bl-targets "$PA_BL" --platform linux \
    "$CASE_DIR"/r1.tsv "$CASE_DIR"/r2.tsv "$CASE_DIR"/r-better.tsv 2>&1)"
  assert_eq 1 $? "a missing cell is never green: $out"
  assert_match '^platform	linux	blocked	' "$out" "missing cell blocks the platform"
  out="$(python3 "$PA_TOOL" summarize --manifest "$PA_M" --bl-targets "$PA_BL" --platform macos \
    "$CASE_DIR"/r1.tsv 2>&1)"
  assert_match '^platform	macos	blocked	' "$out" "a platform with no results is blocked"
  sed 's/manifest_sha256=[0-9a-f]*/manifest_sha256=0000/' "$CASE_DIR/r-better.tsv" >"$CASE_DIR/r-other.tsv"
  out="$(python3 "$PA_TOOL" summarize --manifest "$PA_M" --bl-targets "$PA_BL" --platform linux \
    "$CASE_DIR"/r1.tsv "$CASE_DIR"/r2.tsv "$CASE_DIR"/r3.tsv "$CASE_DIR"/r-other.tsv 2>&1)"
  assert_eq 2 $? "a result compared against another manifest is refused: $out"
  assert_match 'another manifest' "$out" "refusal names the manifest"
}

# ─────────────── classes, denominators, support ───────────────

t_negative_answers_counted_and_reported() {
  pa_setup linux/socat/standard
  PA_COLD_C="$(pa_seq 30 200000 10000 | sed 's/^/NX:/')" pa_cell_data
  pa_compare
  assert_rc 0 "$PA_RC" "NXDOMAIN answers are answered queries: $PA_OUT"
  assert_eq "30/30" "$(pa_field cold nx_cand)" "negative share reported separately"
  assert_eq "0/30" "$(pa_field cold nx_base)" "baseline negative share"
  assert_eq "0/30" "$(pa_field cold failures_cand)" "not failures"
}

t_failures_stay_in_denominators() {
  pa_setup linux/socat/standard
  PA_WARM_C="$(pa_seq 999 3000 1; printf 'SF:9000\n')" pa_cell_data
  pa_compare
  assert_eq 1 "$PA_RC" "a fast SERVFAIL on a zero-failure cell fails: $PA_OUT"
  assert_eq "1/1000" "$(pa_field warm failures_cand)" "failure counted over all attempts"
  assert_eq "0/1000" "$(pa_field warm timeouts_cand)" "no timeout"
  assert_eq pass "$(pa_field warm timeout)" "timeout check alone passes"
  assert_eq fail "$(pa_field warm failure)" "failure check catches the traded failure"
  assert_match '^0\.0002-0\.0056$' "$(pa_field warm failure_ci95_cand)" "Wilson interval on 1/1000"
  # Slow answers turned into fast SERVFAILs rank worst, never as a speed-up.
  pa_setup linux/socat/standard
  PA_WAKE_C="$(pa_rep 14 SF:1000; pa_seq 16 900000 30000)" pa_cell_data
  pa_compare
  assert_eq "14/30" "$(pa_field wake failures_cand)" "fast failures counted: $PA_OUT"
  assert_eq no "$(pa_field wake improvement)" "fast failures are not an improvement"
  assert_eq fail "$(pa_verdict wake)" "and the failure count fails the same-session limit"
}

t_idle_timeouts_compared_with_same_session_arm() {
  pa_setup linux/socat/standard
  PA_IDLE_B="$(pa_seq 28 30000 1000; printf 'TO\nTO\n')" PA_IDLE_C="$(pa_seq 28 30000 1000; printf 'TO\nTO\n')" pa_cell_data
  pa_compare
  assert_eq same-session "$(pa_field idle source)" "idle source: $PA_OUT"
  assert_eq "2/30" "$(pa_field idle timeout_limit)" "limit is the same-session arm's count"
  assert_eq pass "$(pa_field idle timeout)" "2/30 against 2/30"
  pa_setup linux/socat/standard
  PA_IDLE_B="$(pa_seq 28 30000 1000; printf 'TO\nTO\n')" PA_IDLE_C="$(pa_seq 27 30000 1000; printf 'TO\nTO\nTO\n')" pa_cell_data
  pa_compare
  assert_eq fail "$(pa_field idle timeout)" "3/30 against 2/30: $PA_OUT"
  assert_eq fail "$(pa_verdict idle)" "idle verdict"
}

t_frozen_platform_latency_target() {
  pa_setup macos/haproxy/standard
  PA_COLD_B="$(pa_seq 30 100000 3000)" PA_COLD_C="$(pa_seq 28 100000 3000; printf '700000\n710000\n')" pa_cell_data
  pa_compare
  assert_eq 635932 "$(pa_field cold p95_target)" "macos cold p95 target: $PA_OUT"
  assert_eq 700000 "$(pa_field cold p95_cand)" "candidate p95 (nearest rank 29 of 30)"
  assert_eq fail "$(pa_field cold target)" "p95 above the frozen platform target"
  assert_eq fail "$(pa_verdict cold)" "cold verdict"
}

t_tail_percentiles_labelled_by_support() {
  pa_setup linux/socat/standard
  pa_cell_data
  pa_compare
  assert_eq exploratory "$(pa_field cold p95_support_cand)" "p95 of 30 trials is exploratory: $PA_OUT"
  assert_eq exploratory "$(pa_field cold p99_support_cand)" "p99 of 30 trials is exploratory"
  assert_eq supported "$(pa_field warm p95_support_cand)" "p95 of 1000 samples is supported"
  assert_eq supported "$(pa_field warm p99_support_cand)" "p99 of 1000 samples is supported"
}

t_stale_answers_are_reported_unmeasured() {
  pa_setup linux/socat/standard
  assert_match '^unmeasured	stale	' "$(cat "$PA_M")" "manifest records the stale class as unmeasured"
  pa_cell_data
  pa_compare
  assert_match '^unmeasured	stale	' "$PA_OUT" "comparison repeats it; stale is never silently green"
}
