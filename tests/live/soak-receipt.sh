# shellcheck shell=bash
# Group live/soak-receipt (sub-plan 05 Task 2.3; ARCH-09). A row of plan
# qualification, run with --reuse-verified-soak: writes
# <artifact root>/receipts/soak/<SOAK RUN ID>/ from a verified 24 h soak run
# (live/soak --platforms all --hours 24), at that run's own identity (its
# run id, nice-dns commit, targets and image generation labels), and
# verifies it. It observes nothing on a target. The soak stands for its
# platform (user decisions 2026-10-06 "Representative soak", "Per platform";
# tests/manifests/soak.tsv); the qualification receipt links it.
#
#   QU-SOAK     per cell: the run passed, the window was 24 h, steady cold
#               and warm passed the soak rule, no manual repair, every event
#               recovered, no controller tick gap
#   QU-LATENCY  per cell: the cell's steady samples, copied as taken
#
# The soak run is NICE_DNS_SOAK_RUN (an absolute run directory) or the
# newest run whose command was that soak and whose cases all passed. The
# authority to reuse it is plan qualification's --reuse-verified-soak; the
# test is DEC-009's rule for reuse (il_same_product): nice-dns changed since
# its commit outside tests/, docs/ and *.md alone, the proxy candidates it
# built are still the sibling HEADs, and the siblings it did not record
# (hardened-unbound, pi-hole-hardened) have no commit after its start.
# Every check runs on every call, also when the receipt already exists
# (Stage 2 gate review: an existing receipt once skipped them).
#   QU-SOAK also carries idle_reconnect: the first uncached query of each
#   block, after the 5 min idle, judged by the soak rule (at most 1 in 100
#   timeouts): FQ-IDLE-RECONNECT's live proof.
# Writes $ARTIFACT_DIR/soak-receipt.tsv naming the receipt it verified, so
# live/qualification-receipt links exactly that one.

# shellcheck source=tests/live/install-lifecycle.sh
. "$NICE_DNS_ROOT/tests/live/install-lifecycle.sh"
unset -f t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private
SR_SIBS="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}"
SR_HOURS=24

sr_get() { awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$2"; }

# sr_need <expected> <actual> <what>: a precondition, checked before anything
# is written (assert_* ends the case too; this names the expectation).
sr_need() { _nd_tick; [ "$1" = "$2" ] || fail "$3: expected [$1] got [$2]"; }

# sr_find: the newest passing 24 h soak run directory.
sr_find() {
  local root r
  root="$(dirname "$ARTIFACT_DIR")"
  for r in $(find "$root" -mindepth 1 -maxdepth 1 -type d -name '2*' | LC_ALL=C sort -r); do
    grep -qxF "command	tests/run.sh live soak --live --targets tests/live/targets.env --platforms all --hours $SR_HOURS" "$r/receipt.tsv" 2>/dev/null || continue
    awk -F '\t' '$1 == "status" && $2 == "pass" { f = 1 } END { exit !f }' "$r/result.tsv" 2>/dev/null || continue
    printf '%s\n' "$r"; return 0
  done
  return 1
}

t_1_soak_receipt() {
  local run rid out r d key plat proxy pih alias sha psha ws gen tgt n sib sum f v idle
  [ "${NICE_DNS_OPT_REUSE_VERIFIED_SOAK:-}" = 1 ] || fail "plan qualification reuses a verified soak: pass --reuse-verified-soak"
  run="${NICE_DNS_SOAK_RUN:-$(sr_find)}" || fail "no passing $SR_HOURS h soak run to reuse"
  case "$run" in /*) ;; *) fail "NICE_DNS_SOAK_RUN: $run is not an absolute run directory" ;; esac
  rid="$(basename "$run")"
  sr_need "$rid" "$(sr_get run_id "$run/receipt.tsv")" "the soak run records its own id"
  sr_need "command	tests/run.sh live soak --live --targets tests/live/targets.env --platforms all --hours $SR_HOURS" \
    "$(grep '^command	' "$run/receipt.tsv")" "the run was the $SR_HOURS h soak on every platform"
  sr_need pass "$(sr_get status "$run/result.tsv")" "the soak run passed"
  sr_need 2 "$(awk -F '\t' '$1 == "live/soak" && $4 == "pass"' "$run/results.tsv" | grep -c .)" "both soak cases passed"

  out="$(dirname "$(dirname "$ARTIFACT_DIR")")/receipts/soak/$rid"; r="$out/receipt.tsv"

  # Every check first; nothing is written until all pass.
  sha=""
  : >"$CASE_DIR/cells.tsv"
  for d in "$run"/soak/*/; do
    d="${d%/}"; alias="$(basename "$d")"
    [ -f "$d/cell.tsv" ] || fail "$alias: no cell.tsv in the soak run"
    key="$(sr_get cell "$d/cell.tsv")"
    plat="${key%%/*}" proxy="$(printf '%s' "$key" | cut -d/ -f2)" pih="${key##*/}"
    sr_need standard "$pih" "$alias: the soak cell runs standard Pi-hole"
    ws="$(sr_get window_s "$d/cell.tsv")"
    sr_need $((SR_HOURS * 3600)) "$ws" "$alias: a $SR_HOURS h window"
    if [ -z "$sha" ]; then sha="$(sr_get source_sha "$d/cell.tsv")"; fi
    sr_need "$sha" "$(sr_get source_sha "$d/cell.tsv")" "$alias: one nice-dns commit across the soak"
    il_same_product "$sha" "$plat" || fail "$alias: nice-dns changed outside tests/, docs/ and *.md since the soak's $sha: a new soak is owed"
    psha="$(sr_get proxy_sha "$d/cell.tsv")"
    sr_need "$psha" "$(git -C "$SR_SIBS/tor-$proxy" rev-parse HEAD)" "$alias: tor-$proxy is still the candidate the soak built"
    for sib in hardened-unbound pi-hole-hardened; do
      [ "$(git -C "$SR_SIBS/$sib" log -1 --format=%ct HEAD)" -le "$(sr_get start "$d/cell.tsv")" ] \
        || fail "$alias: $sib has a commit after the soak started: its source row would not be what the soak ran"
    done
    sum="$d/summary.tsv"
    [ -f "$sum" ] || fail "$alias: no soak summary"
    sr_need pass "$(sr_get steady_cold "$sum")" "$alias: steady cold under the soak rule"
    sr_need pass "$(sr_get steady_warm "$sum")" "$alias: steady warm under the soak rule"
    sr_need none "$(sr_get manual_repair "$sum")" "$alias: no manual repair"
    sr_need 0 "$(sr_get tick_gaps_over_180s "$sum")" "$alias: no controller tick gap"
    sr_need 4 "$(awk -F '\t' '$1 == "event" && $4 ~ /^recovered_after_s=[0-9]+$/' "$sum" | grep -c .)" "$alias: all four events recovered"
    # Completeness: no failed collection, every block's 8 samples.
    sr_need 0 "$(awk -F '\t' '$1 == "tick" && $4 == "collect-failed"' "$d/cell.tsv" | grep -c .)" "$alias: no failed collection"
    sr_need $((ws * 8 / $(sr_get tick_s "$d/cell.tsv"))) "$(awk 'NR > 2 && !/^#/' "$d/samples.tsv" | grep -c .)" "$alias: 8 samples per block, every block"
    # One identity across the cell's samples, taken as recorded.
    gen="$(awk -F '\t' 'NR > 2 && !/^#/ { print $12 }' "$d/steady.tsv" | LC_ALL=C sort -u)"
    tgt="$(awk -F '\t' 'NR > 2 && !/^#/ { print $7 }' "$d/steady.tsv" | LC_ALL=C sort -u)"
    sr_need 1 "$(printf '%s\n' "$gen" | grep -c .)" "$alias: one image generation in its samples"
    sr_need "$alias" "$tgt" "$alias: its samples name this target"
    # Idle reconnect: the first cold sample of each block (5 min after the
    # last), at most 1 in 100 timed out.
    idle="$(awk -F '\t' 'NR > 2 && !/^#/ { if ($5 == "cold") { if (!incold) { n++; if ($17 == "timeout") t++ } incold = 1 } else incold = 0 }
      END { printf "%d %d", t + 0, n + 0 }' "$d/steady.tsv")"
    [ "${idle#* }" -ge 30 ] && [ $(( ${idle% *} * 100 )) -le "${idle#* }" ] \
      || fail "$alias: idle reconnect: ${idle% *} of ${idle#* } first queries after the idle timed out (at most 1 in 100)"
    _nd_tick
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$plat" "$proxy" "$pih" "$tgt" "$gen" "$key" "$d" "$ws" "$idle" >>"$CASE_DIR/cells.tsv"
  done
  sr_need 2 "$(grep -c . "$CASE_DIR/cells.tsv")" "one soak cell per platform"

  if [ -f "$r" ]; then
    # Already written: it must still verify and be of this very run.
    v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" 2>&1)"
    assert_rc 0 $? "the existing soak receipt still verifies: $v"
    sr_need "$sha" "$(awk -F '\t' '$1 == "product" && $2 == "nice-dns" { print $3; exit }' "$r")" "the existing soak receipt is of the soak's commit"
    sr_need "$(cut -f1-5 "$CASE_DIR/cells.tsv" | LC_ALL=C sort)" \
      "$(awk -F '\t' -v OFS='\t' '$1 == "cell" { print $2, $3, $4, $5, $6 }' "$r" | LC_ALL=C sort)" "the existing soak receipt holds this run's cells"
    printf '%s\n' "$r" >"$ARTIFACT_DIR/soak-receipt.tsv"
    printf 'soak_receipt\t%s\treused\n' "$r" >>"$CASE_DIR/receipt.tsv"
    return 0
  fi

  mkdir -p "$out/cells" || fail "cannot create $out"
  while IFS="$(printf '\t')" read -r plat proxy pih tgt gen key d ws idle; do
    sum="$d/summary.tsv"
    n="$(awk 'NR > 2 && !/^#/' "$d/steady.tsv" | grep -c .)"
    mkdir -p "$out/cells/${key//\//-}"
    cp "$d/steady.tsv" "$out/cells/${key//\//-}/steady.tsv"
    {
      printf '# QU-SOAK %s from soak run %s (%s samples)\n' "$key" "$rid" "$n"
      # Copied from the run's own records, never asserted here: the soak
      # manifest's content rules judge them again when the receipt verifies.
      printf 'result=%s\nsteady_cold=%s\nsteady_warm=%s\nmanual_repair=%s\nhours=%s\n' \
        "$(sr_get status "$run/result.tsv")" "$(sr_get steady_cold "$sum")" "$(sr_get steady_warm "$sum")" \
        "$(sr_get manual_repair "$sum")" "$((ws / 3600))"
      printf 'idle_reconnect=pass\nidle_first_queries=%s\nidle_timeouts=%s\n' "${idle#* }" "${idle% *}"
      printf '# summary.tsv of the run, as written\n'
      cat "$sum"
    } >"$out/cells/${key//\//-}/QU-SOAK.txt"
  done <"$CASE_DIR/cells.tsv"

  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\tsoak\nrun_id\t%s\ncreated_utc\t%s\n' "$rid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source\tnice-dns\t%s\tclean\n' "$sha"
    for sib in tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      printf 'source\t%s\t%s\t%s\n' "$sib" "$(git -C "$SR_SIBS/$sib" rev-parse HEAD)" \
        "$(if GIT_OPTIONAL_LOCKS=0 git -C "$SR_SIBS/$sib" status --porcelain | grep -qv '^?? bridge-eval/bridge-eval$'; then echo dirty; else echo clean; fi)"
    done
    for sib in tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      printf 'arch\t%s\t%s\t%s\n' "$sib" "$(git -C "$SR_SIBS/$sib" rev-parse HEAD)" \
        "$(git -C "$SR_SIBS/$sib" show HEAD:.github/workflows/main.yml |
          awk '/^ *platform: *$/ { on = 1; next } on && /^ *- *linux\// { sub(/^ *- */, ""); print; next } on { on = 0 }' |
          sort | paste -sd, -)"
    done
    printf 'product\tnice-dns\t%s\n' "$sha"
    while IFS="$(printf '\t')" read -r plat proxy pih tgt gen key _; do
      printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "$plat" "$proxy" "$pih" "$tgt" "$gen"
    done <"$CASE_DIR/cells.tsv"
    while IFS="$(printf '\t')" read -r plat proxy pih tgt gen key _; do
      for f in QU-SOAK.txt steady.tsv; do
        printf 'scenario\t%s\t%s\tpass\tcells/%s/%s\t%s\t%s\n' "$([ "$f" = steady.tsv ] && echo QU-LATENCY || echo QU-SOAK)" "$key" \
          "${key//\//-}" "$f" "$(sha256sum "$out/cells/${key//\//-}/$f" | cut -d' ' -f1)" "$gen"
      done
    done <"$CASE_DIR/cells.tsv"
  } >"$r"
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" 2>&1)"
  assert_rc 0 $? "the soak receipt verifies: $v"
  printf '%s\n' "$r" >"$ARTIFACT_DIR/soak-receipt.tsv"
  printf 'soak_receipt\t%s\twritten\n' "$r" >>"$CASE_DIR/receipt.tsv"
}
