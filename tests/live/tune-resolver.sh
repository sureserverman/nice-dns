# shellcheck shell=bash
# Group live/tune-resolver (Sub-plan 5, Task 1.3; ARCH-04, ARCH-09; DEC-012).
# Run with `tests/run.sh live tune-resolver --live --targets FILE
# --platforms all --comparison baseline`.
#
# One representative cell per platform, the platform's previously
# problematic class (BL-TARGETS): linux/haproxy/standard (cold timed out
# 7/30) and macos/socat/standard (the slowest macOS cold class). Each
# target is switched to that proxy by this checkout's installer, the
# controller's schedules are quiesced for both arms, and the two arms
# alternate 5 times (DEC-012 scope: cold and warm only):
#
#   baseline   nice-dns b85bc9b built on the target with the nearest
#              published proxy tag (tor-haproxy v2.13, tor-socat v2.9): a
#              reconstructed baseline, run under today's deployment
#              (target.sh arm-prepare / arm-set, the image swap)
#   candidate  the images this checkout's installer deployed
#
# Per block and arm: 6 cold names (fresh) and 200 warm (cached) queries
# through Pi-hole, 5000 ms timeout as in the baseline. The block files are
# kept; each arm's rows are appended into one sample file per arm, ids
# continuing, under the arm's own run id. tests/reports/perf-acceptance.py
# compare --workloads cold,warm judges them (scope=cold,warm: never a full
# cell result). The target ends on the candidate arm with its schedules
# started again (a reinstall of the candidate).
#
# Evidence: $ARTIFACT_DIR/tune-resolver/<alias>/ (private; the *.tsv hold no
# bridge material, t_2).

# shellcheck source=tests/live/install-lifecycle.sh
. "$NICE_DNS_ROOT/tests/live/install-lifecycle.sh"
unset -f t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private

il_dir() { printf '%s\n' "$ARTIFACT_DIR/tune-resolver/$1"; }
IL_FIRST_STEPS=tr_cell
TR_BASE_SHA=b85bc9b7786efc7d3bf0572875e95e214dfa1d6c
TR_BLOCKS="${NICE_DNS_TR_BLOCKS:-5}"
TR_COLD="${NICE_DNS_TR_COLD:-6}"
TR_WARM="${NICE_DNS_TR_WARM:-200}"
TR_PA="$NICE_DNS_ROOT/tests/reports/perf-acceptance.py"

tr_proxy() { if [ "$1" = linux ]; then echo haproxy; else echo socat; fi; }
tr_tag() { if [ "$1" = haproxy ]; then echo v2.13; else echo v2.9; fi; }

# tr_append <block file> <arm file>: the block's rows onto the arm's file,
# sample ids continuing (as collect.sh does when it appends).
tr_append() {
  if [ ! -f "$2" ]; then head -n 2 "$1" >"$2"; fi
  awk -F '\t' -v OFS='\t' -v n="$(grep -vc '^#' "$2")" 'NR > 2 { $2 = n++; print }' "$1" >>"$2"
}

# tr_collect <alias> <arm> <workload> <count> <block> [pause ms]
tr_collect() {
  local a="$1" arm="$2" w="$3" d f rc
  d="$(il_dir "$a")"
  f="$d/blocks/$arm-$w-$5.tsv"
  RUN_ID="$RUN_ID-$arm" il_t "$a" collect --workload "$w" --count "$4" --identity "$d/identity-$arm.tsv" \
    --timeout-ms 5000 --pause-ms "${6:-0}" >"$f" 2>>"$d/ops.log"
  rc=$?
  case "$rc" in 0|3) ;; *) fail "$a: collect $w ($arm, block $5) failed (exit $rc)" ;; esac
  assert_eq "$(($4 + 1))" "$(grep -vc '^#' "$f")" "$a: $4 $w samples ($arm, block $5)"
  tr_append "$f" "$d/samples-$arm.tsv"
}

tr_cell() {
  local plat="$1" a="$2" d proxy tag arm k first
  d="$(il_dir "$a")"
  mkdir -p "$d/blocks"
  proxy="$(tr_proxy "$plat")" tag="$(tr_tag "$proxy")"
  if [ "${NICE_DNS_IL_DRY_RUN:-0}" != 1 ]; then
    assert_eq "" "$(GIT_OPTIONAL_LOCKS=0 git -C "$NICE_DNS_ROOT" status --porcelain --untracked-files=no)" "the checkout is committed (the archive is of HEAD)"
  fi
  il_t "$a" snapshot >>"$d/ops.log" 2>&1 || fail "snapshot $a"
  printf 'cell\t%s/%s/standard\nproxy\t%s\nsource_sha\t%s\nbaseline_sha\t%s\nbaseline_proxy_tag\t%s\n' \
    "$plat" "$proxy" "$proxy" "$(il_sha)" "$TR_BASE_SHA" "$tag" >"$d/cell.tsv"
  il_install "$a" candidate install || fail "the candidate install failed: $(tail -n 20 "$d/install-candidate.log")"
  il_watch_pinned "$plat" "$d/watch-candidate.tsv" all
  il_t "$a" quiesce-agents >"$d/quiesce.tsv" 2>>"$d/ops.log" || fail "$a: quiesce-agents: $(cat "$d/quiesce.tsv")"
  il_report "$a" after-install || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-install.tsv" "$proxy"

  il_t "$a" arm-prepare --component "tor-$proxy" --proxy-tag "$tag" --source-sha "$TR_BASE_SHA" >"$d/arms.tsv" 2>>"$d/ops.log" \
    || fail "$a: arm-prepare: $(tail -n 20 "$d/ops.log")"
  for arm in baseline candidate; do
    assert_eq 3 "$(awk -F '\t' -v a="$arm" '$1 == "arm" && $2 == a && $4 ~ /^(sha256:)?[0-9a-f]+$/ && length($4) >= 64' "$d/arms.tsv" | grep -c .)" "$a: three $arm images"
  done
  assert_eq "" "$(awk -F '\t' '$1 == "arm" { id[$2 "/" $3] = $4 } END { for (x in id) { split(x, p, "/"); if (p[1] == "baseline" && id[x] == id["candidate/" p[2]]) print p[2] } }' "$d/arms.tsv")" \
    "$a: no baseline image is a candidate image"
  printf 'target_id\t%s\nplatform\t%s\nproxy\t%s\npihole\tstandard\nsource_rev\t%s\nimages\treconstructed-baseline-%s-%s\n' \
    "$a" "$plat" "$proxy" "$TR_BASE_SHA" "${TR_BASE_SHA:0:7}" "$tag" >"$d/identity-baseline.tsv"
  printf 'target_id\t%s\nplatform\t%s\nproxy\t%s\npihole\tstandard\nsource_rev\t%s\nimages\tgeneration-of-%s\n' \
    "$a" "$plat" "$proxy" "$(il_sha)" "$(il_sha)" >"$d/identity-candidate.tsv"

  # Strict alternation: the comparator refuses a run of one arm longer than
  # one block (ceil(n/5)).
  k=1
  while [ "$k" -le "$TR_BLOCKS" ]; do
    for arm in baseline candidate; do
      il_t "$a" arm-set --component "tor-$proxy" --mode "$arm" >"$d/blocks/set-$arm-$k.tsv" 2>>"$d/ops.log" \
        || fail "$a: arm-set $arm (block $k): $(tail -n 5 "$d/ops.log")"
      # A primed cached name, then the block: cold names first (fresh), then warm.
      il_t "$a" collect --workload warm --count 1 --identity "$d/identity-$arm.tsv" >/dev/null 2>>"$d/ops.log" || true
      tr_collect "$a" "$arm" cold "$TR_COLD" "$k"
      tr_collect "$a" "$arm" warm "$TR_WARM" "$k"
    done
    k=$((k + 1))
  done
  first="$(awk -F '\t' 'NR > 2 { print $3; exit }' "$d/samples-baseline.tsv")"
  printf 'first_sample_utc\t%s\n' "$first" >>"$d/cell.tsv"

  python3 "$TR_PA" compare --cell "$plat/$proxy/standard" --baseline "$d/samples-baseline.tsv" \
    --candidate "$d/samples-candidate.tsv" --workloads cold,warm >"$d/compare.tsv" 2>"$d/compare.err"
  printf 'compare_exit\t%s\n' "$?" >>"$d/cell.tsv"
  [ -s "$d/compare.tsv" ] || fail "$a: the comparison was refused: $(cat "$d/compare.err")"

  # The target ends on the candidate with its schedules running again.
  il_t "$a" arm-set --component "tor-$proxy" --mode candidate >"$d/set-final.tsv" 2>>"$d/ops.log" || fail "$a: back to the candidate arm"
  il_install "$a" reinstall install || fail "the reinstall failed: $(tail -n 20 "$d/install-reinstall.log")"
  il_watch_pinned "$plat" "$d/watch-reinstall.tsv" all
  il_report "$a" after-reinstall || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-reinstall.tsv" "$proxy"
  printf 'tune-resolver\t%s\tmeasured\n' "$plat/$proxy/standard" >"$d/measured.tsv"
}

t_1_interleaved_comparison() {
  [ "${NICE_DNS_OPT_COMPARISON:-}" = baseline ] || fail "--comparison baseline is the only comparison this group runs"
  il_selection
  il_each tr_cell
}

t_2_evidence_is_private() {
  il_selection
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$ARTIFACT_DIR/tune-resolver" --include='*.tsv' 2>/dev/null)" \
    "no report, sample or step record holds bridge material, a session or a hash"
}

# Promote only a candidate satisfying the frozen limits (Task 1.3): each
# measured platform's scoped comparison passes (cold and warm within their
# frozen timeout and failure limits and the platform p95 target, no problem
# class significantly slower). Whether cold improved is reported here and
# judged by the Stage 1 gate's platform summary.
t_3_candidate_meets_the_frozen_limits() {
  local p a d v
  il_selection
  for p in $(il_platforms); do
    il_alias "$p"; a="$IL_ALIAS"; d="$(il_dir "$a")"
    [ -f "$d/compare.tsv" ] || fail "$a: no comparison (t_1 did not finish)"
    v="$(awk -F '\t' '$1 == "cell" { print $3 "\t" $4 }' "$d/compare.tsv")"
    printf '%s\t%s\n' "$a" "$v"
    assert_match '^pass	' "$v" "$a: the candidate meets the frozen limits: $(awk -F '\t' '$1 == "workload" && $4 != "pass" && $4 != "deferred" { print $3 ": " $4 " " $NF }' "$d/compare.tsv")"
  done
}
