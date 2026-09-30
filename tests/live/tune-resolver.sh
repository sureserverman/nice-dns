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
# alternate 10 times (DEC-012 scope: cold and warm; DEC-014 adds restart):
#
#   baseline   nice-dns b85bc9b built on the target with the nearest
#              published proxy tag (tor-haproxy v2.13, tor-socat v2.9): a
#              reconstructed baseline, run under today's deployment
#              (target.sh arm-prepare / arm-set, the image swap)
#   candidate  the images this checkout's installer deployed
#
# Per block and arm: one restart sample (DEC-014: arm-set's time from the
# stack restart to the first answer), 9 cold names (fresh) and 100 warm
# (cached) queries through Pi-hole, 5000 ms timeout as in the baseline: per
# arm 10 restarts, 90 cold (DEC-013) and 1000 warm, each class's budget. The
# block files are kept; each arm's rows are appended into one sample file per
# arm, ids continuing, under the arm's own run id. tests/reports/
# perf-acceptance.py compare --workloads cold,warm,restart judges them (a
# scoped comparison: never a full cell result). The target ends on the
# candidate arm with its schedules started again (a reinstall of the
# candidate).
#
# Evidence: $ARTIFACT_DIR/tune-resolver/<alias>/ (private; the *.tsv hold no
# bridge material, t_2).

# shellcheck source=tests/live/install-lifecycle.sh
. "$NICE_DNS_ROOT/tests/live/install-lifecycle.sh"
unset -f t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private

# TR_GROUP: the evidence directory's name; live/tune-transport reuses this
# cell under its own (Sub-plan 5 Task 1.4).
TR_GROUP="${TR_GROUP:-tune-resolver}"
il_dir() { printf '%s\n' "$ARTIFACT_DIR/$TR_GROUP/$1"; }
IL_FIRST_STEPS=tr_cell
TR_BASE_SHA=b85bc9b7786efc7d3bf0572875e95e214dfa1d6c
TR_BLOCKS="${NICE_DNS_TR_BLOCKS:-10}"  # 10 restarts per arm (DEC-014)
TR_COLD="${NICE_DNS_TR_COLD:-9}"   # 90 cold per arm over 10 blocks (DEC-013)
TR_WARM="${NICE_DNS_TR_WARM:-100}"
TR_PA="$NICE_DNS_ROOT/tests/reports/perf-acceptance.py"
# NICE_DNS_TR_ROUTE: an identity route the candidate is pinned to for the
# measurement (applied after the quiesce, so the controller cannot move it);
# unset, the candidate runs whatever route the deployment holds.
TR_ROUTE="${NICE_DNS_TR_ROUTE:-}"

tr_proxy() { if [ "$1" = linux ]; then echo haproxy; else echo socat; fi; }
tr_tag() { if [ "$1" = haproxy ]; then echo v2.13; else echo v2.9; fi; }

# tr_append <block file> <arm file>: the block's rows onto the arm's file,
# sample ids continuing (as collect.sh does when it appends).
tr_append() {
  if [ ! -f "$2" ]; then head -n 2 "$1" >"$2"; fi
  awk -F '\t' -v OFS='\t' -v n="$(grep -vc '^#' "$2")" 'NR > 2 { $2 = n++; print }' "$1" >>"$2"
}

# tr_collect <alias> <arm> <workload> <count> <block> [pause ms] [sleep s]
# With <sleep s> the target suspends that long first (target.sh collect
# --after-sleep).
tr_collect() {
  local a="$1" arm="$2" w="$3" d f rc sl=()
  d="$(il_dir "$a")"
  f="$d/blocks/$arm-$w-$5.tsv"
  [ -z "${7:-}" ] || sl=(--after-sleep "$7")
  RUN_ID="$RUN_ID-$arm" il_t "$a" collect --workload "$w" --count "$4" --identity "$d/identity-$arm.tsv" \
    --timeout-ms 5000 --pause-ms "${6:-0}" ${sl[@]+"${sl[@]}"} >"$f" 2>>"$d/ops.log"
  rc=$?
  case "$rc" in 0|3) ;; *) fail "$a: collect $w ($arm, block $5) failed (exit $rc)" ;; esac
  assert_eq "$(($4 + 1))" "$(grep -vc '^#' "$f")" "$a: $4 $w samples ($arm, block $5)"
  tr_append "$f" "$d/samples-$arm.tsv"
}

# tr_restart <alias> <arm> <block>: arm-set's first_answer line as one
# nice-dns-sample/1 row of workload restart (DEC-014), labelled from the arm's
# identity like collect.sh's rows, onto the arm's file.
tr_restart() {
  local a="$1" arm="$2" k="$3" d s f
  d="$(il_dir "$a")"
  s="$d/blocks/set-$arm-$k.tsv" f="$d/blocks/$arm-restart-$k.tsv"
  assert_eq 1 "$(awk -F '\t' '$1 == "first_answer"' "$s" | grep -c .)" "$a: one first answer ($arm, block $k)"
  awk -F '\t' -v OFS='\t' -v run="$RUN_ID-$arm" '
    FILENAME == ARGV[1] { id[$1] = $2; next }
    $1 == "resolver" { res = $2 }
    $1 == "first_answer" { t0 = $2; us = $3; oc = $4; rc = $5; q = $6; cap = $7 }
    END {
      print "# schema", "nice-dns-sample/1"
      print "run_id", "sample_id", "utc_start", "elapsed_us", "workload", "cache_class", "target_id", "platform", "proxy", "pihole", "source_rev", "images", "resolver", "transport", "qname", "qtype", "outcome", "rcode", "timeout_ms"
      print run, 1, t0, us, "restart", "after-restart", id["target_id"], id["platform"], id["proxy"], id["pihole"], id["source_rev"], id["images"], res, "udp", q, "A", oc, rc, cap
    }' "$d/identity-$arm.tsv" "$s" >"$f"
  tr_append "$f" "$d/samples-$arm.tsv"
}

# tr_dns_settled <alias>: the host resolver answers 3 checks in a row (5 s
# apart, up to 3 min). arm-set returns on the first answered name, and the
# macOS installer's preparation (brew update) right after it could not
# resolve github.com (live 2026-09-29, mac: the reinstall refused, 11 s after
# the restart).
tr_dns_settled() {
  local a="$1" d ok=0 i=0
  d="$(il_dir "$a")"
  while [ "$i" -lt 36 ]; do
    i=$((i + 1))
    if il_t "$a" lifecycle-report 2>>"$d/ops.log" | grep -q "^resolves	yes$"; then ok=$((ok + 1)); else ok=0; fi
    [ "$ok" -ge 3 ] && return 0
    sleep 5
  done
  return 1
}

# Hooks for a group that reuses this cell (live/tune-transport): after the
# candidate install and before the arms are prepared; before and after each
# swap to the candidate arm. No-ops here.
tr_hook_after_install() { :; }     # <platform> <alias> <proxy>
tr_hook_before_baseline() { :; }   # <alias> <block>
tr_hook_before_candidate() { :; }  # <alias> <block>
tr_hook_after_candidate() { :; }   # <alias> <block>
# TR_WORKLOADS: the classes the comparison judges. tr_block <alias> <arm>
# <block>: one block's samples of one arm, after the swap and its restart
# sample: cold names first (fresh), then warm.
TR_WORKLOADS=cold,warm,restart
tr_block() {
  tr_collect "$1" "$2" cold "$TR_COLD" "$3"
  tr_collect "$1" "$2" warm "$TR_WARM" "$3"
}
# tr_candidate_images <alias>: the candidate arm's images label.
tr_candidate_images() { printf 'generation-of-%s\n' "$(il_sha)"; }

# tr_cleanup <alias> <proxy>: a cell that stops early never leaves the target
# on the baseline arm with its schedules stopped (Stage 1 gate, S4): back to
# the candidate arm (refused at once when the arms were never prepared), then
# the schedules start again. Best effort; what it did is in cell.tsv.
tr_cleanup() {
  local a="$1" d rc
  d="$(il_dir "$a")"
  il_t "$a" arm-set --component "tor-$2" --mode candidate >"$d/cleanup-arm.tsv" 2>>"$d/ops.log"; rc=$?
  printf 'cleanup_arm_set_exit\t%s\n' "$rc" >>"$d/cell.tsv"
  il_t "$a" resume-agents >"$d/cleanup-resume.tsv" 2>>"$d/ops.log"; rc=$?
  printf 'cleanup_resume_exit\t%s\n' "$rc" >>"$d/cell.tsv"
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
  # From here the cell changes what the target runs: undone on any early end.
  trap 'tr_cleanup "$a" "$proxy"' EXIT
  il_t "$a" quiesce-agents >"$d/quiesce.tsv" 2>>"$d/ops.log" || fail "$a: quiesce-agents: $(cat "$d/quiesce.tsv")"
  il_report "$a" after-install || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-install.tsv" "$proxy"

  if [ -n "$TR_ROUTE" ]; then
    il_t "$a" route-apply --route "$TR_ROUTE" >"$d/route-pin.tsv" 2>>"$d/ops.log" || fail "$a: route-apply $TR_ROUTE: $(cat "$d/route-pin.tsv")"
    assert_match '^(applied|unchanged)$' "$(awk -F '\t' '$1 == "result" { print $2 }' "$d/route-pin.tsv")" "$a: the candidate is pinned to $TR_ROUTE"
  fi
  printf 'candidate_route_pin\t%s\n' "${TR_ROUTE:-none}" >>"$d/cell.tsv"
  tr_hook_after_install "$plat" "$a" "$proxy"
  il_t "$a" arm-prepare --component "tor-$proxy" --proxy-tag "$tag" --source-sha "$TR_BASE_SHA" >"$d/arms.tsv" 2>>"$d/ops.log" \
    || fail "$a: arm-prepare: $(tail -n 20 "$d/ops.log")"
  for arm in baseline candidate; do
    assert_eq 3 "$(awk -F '\t' -v a="$arm" '$1 == "arm" && $2 == a && $4 ~ /^(sha256:)?[0-9a-f]+$/ && length($4) >= 64' "$d/arms.tsv" | grep -c .)" "$a: three $arm images"
  done
  assert_eq "" "$(awk -F '\t' '$1 == "arm" { id[$2 "/" $3] = $4 } END { for (x in id) { split(x, p, "/"); if (p[1] == "baseline" && id[x] == id["candidate/" p[2]]) print p[2] } }' "$d/arms.tsv")" \
    "$a: no baseline image is a candidate image"
  printf 'target_id\t%s\nplatform\t%s\nproxy\t%s\npihole\tstandard\nsource_rev\t%s\nimages\treconstructed-baseline-%s-%s\n' \
    "$a" "$plat" "$proxy" "$TR_BASE_SHA" "${TR_BASE_SHA:0:7}" "$tag" >"$d/identity-baseline.tsv"
  printf 'target_id\t%s\nplatform\t%s\nproxy\t%s\npihole\tstandard\nsource_rev\t%s\nimages\t%s\n' \
    "$a" "$plat" "$proxy" "$(il_sha)" "$(tr_candidate_images "$a")" >"$d/identity-candidate.tsv"

  # Strict alternation: the comparator refuses a run of one arm longer than
  # one block (ceil(n/5)).
  k=1
  while [ "$k" -le "$TR_BLOCKS" ]; do
    for arm in baseline candidate; do
      if [ "$arm" = candidate ]; then tr_hook_before_candidate "$a" "$k"; else tr_hook_before_baseline "$a" "$k"; fi
      il_t "$a" arm-set --component "tor-$proxy" --mode "$arm" >"$d/blocks/set-$arm-$k.tsv" 2>>"$d/ops.log" \
        || fail "$a: arm-set $arm (block $k): $(tail -n 5 "$d/ops.log")"
      tr_restart "$a" "$arm" "$k"
      # A primed cached name, then the block.
      il_t "$a" collect --workload warm --count 1 --identity "$d/identity-$arm.tsv" >/dev/null 2>>"$d/ops.log" || true
      if [ "$arm" = candidate ]; then
        il_t "$a" route-report >"$d/blocks/route-$k.tsv" 2>>"$d/ops.log" || true
        printf 'block\t%s\t%s\n' "$k" "$(awk -F '\t' '$1 == "readback" { print $2 }' "$d/blocks/route-$k.tsv")" >>"$d/candidate-routes.tsv"
        [ -z "$TR_ROUTE" ] || assert_match "^$TR_ROUTE " "$(awk -F '\t' '$1 == "readback" { print $2 }' "$d/blocks/route-$k.tsv")" "$a: block $k runs the pinned route"
        tr_hook_after_candidate "$a" "$k"
      fi
      tr_block "$a" "$arm" "$k"
    done
    k=$((k + 1))
  done
  first="$(awk -F '\t' 'NR > 2 { print $3; exit }' "$d/samples-baseline.tsv")"
  printf 'first_sample_utc\t%s\n' "$first" >>"$d/cell.tsv"

  python3 "$TR_PA" compare --cell "$plat/$proxy/standard" --baseline "$d/samples-baseline.tsv" \
    --candidate "$d/samples-candidate.tsv" --workloads "$TR_WORKLOADS" >"$d/compare.tsv" 2>"$d/compare.err"
  printf 'compare_exit\t%s\n' "$?" >>"$d/cell.tsv"
  [ -s "$d/compare.tsv" ] || fail "$a: the comparison was refused: $(cat "$d/compare.err")"

  # The target ends on the candidate with its schedules running again.
  il_t "$a" arm-set --component "tor-$proxy" --mode candidate >"$d/set-final.tsv" 2>>"$d/ops.log" || fail "$a: back to the candidate arm"
  tr_dns_settled "$a" || fail "$a: the host resolver did not settle after the last arm swap"
  il_install "$a" reinstall install || fail "the reinstall failed: $(tail -n 20 "$d/install-reinstall.log")"
  il_watch_pinned "$plat" "$d/watch-reinstall.tsv" all
  il_report "$a" after-reinstall || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-reinstall.tsv" "$proxy"
  trap - EXIT
  printf '%s\t%s\tmeasured\n' "$TR_GROUP" "$plat/$proxy/standard" >"$d/measured.tsv"
}

t_1_interleaved_comparison() {
  [ "${NICE_DNS_OPT_COMPARISON:-}" = baseline ] || fail "--comparison baseline is the only comparison this group runs"
  il_selection
  il_each tr_cell
}

t_2_evidence_is_private() {
  il_selection
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$ARTIFACT_DIR/$TR_GROUP" --include='*.tsv' 2>/dev/null)" \
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
