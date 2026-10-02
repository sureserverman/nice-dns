# shellcheck shell=bash
# Group live/soak (Sub-plan 5, Task 2.2; ARCH-07, ARCH-09; qualification
# scenario QU-SOAK; closes BL-002 only after it passes). Run with
#   tests/run.sh live soak --live --targets FILE --platforms all --hours 24
# The case runs for the whole window: start the runner detached (setsid
# nohup ... &) and read its log. NICE_DNS_SOAK_SECS (600 or more) replaces
# --hours for a short dry run; a dry run records its judgements but needs no
# daily bridge refresh and no sample budget.
#
# Both platforms side by side, each on its representative cell (DEC-012:
# linux/haproxy/standard, macos/socat/standard):
#   install   this checkout's HEAD by its own installer (target.sh
#             install-cell), then the proxy built on the target from the
#             sibling checkout's HEAD (build-proxy, recreate-proxy): the
#             frozen candidate. The running images are recorded at the start
#             and must be the same at the end (a changed identity would need
#             a new window, never relabelled samples).
#   samples   every NICE_DNS_SOAK_TICK seconds (300): 3 cold (fresh) and 5
#             warm names through Pi-hole, 5000 ms timeout, onto samples.tsv
#   reports   every hour and at the end: controller-report
#   events    at 1/6, 2/6, 4/6 and 5/6 of the window: a 60 s host sleep
#             (collect --after-sleep 60; user decision 2026-10-02 "2 sleeps
#             + 2 net losses"), a network loss (fault-lib ndf_loss), a sleep,
#             a loss. Each must recover without any repair: a fresh answer
#             within 300 s of a wake, within NDF_RETURN_S of the network's
#             return.
#   no repair the harness never restarts, reinstalls or repairs anything
#             after the install; the controller's schedules run throughout.
# Judged at the end, per platform:
#   - the samples outside every event (from its start to its recovery) meet
#     the cell's frozen limits for cold and warm (perf-acceptance.py check;
#     idle, wake and restart are not collected here and are not judged);
#   - the controller ran a pass at least every 180 s, except across a sleep
#     (no stale controller); its recovery requests and the proxy's restarts
#     are counted into summary.tsv;
#   - in a window of 24 h or more the daily bridge refresh ran (a bridges
#     row in the controller's journal after the start);
#   - the images running at the end are those of the start.
# Evidence: $ARTIFACT_DIR/soak/<alias>/ (private; summary.tsv and the *.tsv
# hold no bridge lines, t_2).

# shellcheck source=tests/live/install-lifecycle.sh
. "$NICE_DNS_ROOT/tests/live/install-lifecycle.sh"
unset -f t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private
# shellcheck source=tests/live/controller-lib.sh
. "$NICE_DNS_ROOT/tests/live/controller-lib.sh"
# shellcheck source=tests/live/fault-lib.sh
. "$NICE_DNS_ROOT/tests/live/fault-lib.sh"

il_dir() { printf '%s\n' "$ARTIFACT_DIR/soak/$1"; }
cs_dir() { il_dir "$1"; }
IL_FIRST_STEPS=sk_cell
SK_TICK="${NICE_DNS_SOAK_TICK:-300}"
SK_WAKE_S=300
SK_GAP_S=180
SK_PA="$NICE_DNS_ROOT/tests/reports/perf-acceptance.py"

sk_proxy() { if [ "$1" = linux ]; then echo haproxy; else echo socat; fi; }

# sk_secs: the window in seconds (NICE_DNS_SOAK_SECS, else --hours).
sk_secs() {
  if [ -n "${NICE_DNS_SOAK_SECS:-}" ]; then
    case "$NICE_DNS_SOAK_SECS" in ''|*[!0-9]*) return 1 ;; esac
    [ "$NICE_DNS_SOAK_SECS" -ge 600 ] || return 1
    printf '%s\n' "$NICE_DNS_SOAK_SECS"; return 0
  fi
  case "${NICE_DNS_OPT_HOURS:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$NICE_DNS_OPT_HOURS" -ge 1 ] || return 1
  printf '%s\n' "$((NICE_DNS_OPT_HOURS * 3600))"
}

# sk_proxy_sha <proxy>: the sibling checkout's committed HEAD.
sk_proxy_sha() {
  local r="$NICE_DNS_ROOT/../tor-$1"
  assert_eq "" "$(GIT_OPTIONAL_LOCKS=0 git -C "$r" status --porcelain --untracked-files=no)" "tor-$1 is committed (the archive is of its HEAD)"
  git -C "$r" rev-parse HEAD
}

# sk_append <block file> <samples file>: the block's rows, ids continuing.
sk_append() {
  if [ ! -f "$2" ]; then head -n 2 "$1" >"$2"; fi
  awk -F '\t' -v OFS='\t' -v n="$(grep -vc '^#' "$2")" 'NR > 2 { $2 = n++; print }' "$1" >>"$2"
}

# sk_collect <alias> <workload> <count> <file> [sleep s]: rc 0 (all
# answered) or 3 (some failed) is a sample; anything else fails.
sk_collect() {
  local a="$1" d rc sl=()
  d="$(il_dir "$a")"
  [ -z "${5:-}" ] || sl=(--after-sleep "$5")
  il_t "$a" collect --workload "$2" --count "$3" --identity "$d/identity.tsv" --timeout-ms 5000 \
    ${sl[@]+"${sl[@]}"} >"$4" 2>>"$d/ops.log"
  rc=$?
  case "$rc" in 0|3) return 0 ;; esac
  return "$rc"
}

sk_answered_rows() { awk -F '\t' 'NR > 2 && ($17 == "ok" || $17 == "nxdomain")' "$1" | grep -c .; }

# sk_sleep <alias> <k>: a 60 s host sleep and the wake sample, then a fresh
# name every 15 s until one is answered (at most SK_WAKE_S). Prints the
# seconds from the wake to that answer.
sk_sleep() {
  local a="$1" k="$2" d t0 i=0
  d="$(il_dir "$a")/events"
  sk_collect "$a" wake 1 "$d/wake-$k.tsv" 60 || fail "$a: sleep $k: the wake sample failed (see ops.log)"
  t0="$(date +%s)"
  while [ $(( $(date +%s) - t0 )) -lt "$SK_WAKE_S" ]; do
    i=$((i + 1))
    sk_collect "$a" cold 1 "$d/after-wake-$k-$i.tsv" || true
    if [ -f "$d/after-wake-$k-$i.tsv" ] && [ "$(sk_answered_rows "$d/after-wake-$k-$i.tsv")" -ge 1 ]; then
      printf '%s\n' "$(( $(date +%s) - t0 ))"; return 0
    fi
    sleep 15
  done
  fail "$a: sleep $k: no fresh answer within $SK_WAKE_S s of the wake"
}

sk_cell() {
  local plat="$1" a="$2" d proxy sha win start now next_rep ev k=0 e kind t0 rec r c n steady bad
  local -a at
  d="$(il_dir "$a")"
  mkdir -p "$d/blocks" "$d/events" "$d/reports"
  win="$(sk_secs)" || fail "the window: --hours N (N >= 1) or NICE_DNS_SOAK_SECS >= 600"
  proxy="$(sk_proxy "$plat")"
  assert_eq "" "$(GIT_OPTIONAL_LOCKS=0 git -C "$NICE_DNS_ROOT" status --porcelain --untracked-files=no)" "the checkout is committed (the archive is of HEAD)"
  il_t "$a" snapshot >>"$d/ops.log" 2>&1 || fail "snapshot $a"
  printf 'cell\t%s/%s/standard\nproxy\t%s\nsource_sha\t%s\nwindow_s\t%s\ntick_s\t%s\n' \
    "$plat" "$proxy" "$proxy" "$(il_sha)" "$win" "$SK_TICK" >"$d/cell.tsv"

  # The frozen candidate.
  il_install "$a" candidate install || fail "the candidate install failed: $(tail -n 20 "$d/install-candidate.log")"
  il_watch_pinned "$plat" "$d/watch-candidate.tsv" all
  sha="$(sk_proxy_sha "$proxy")"
  printf 'proxy_sha\t%s\n' "$sha" >>"$d/cell.tsv"
  il_t "$a" build-proxy --component "tor-$proxy" --source-sha "$sha" >"$d/build-proxy.tsv" 2>>"$d/ops.log" \
    || fail "$a: build-proxy: $(tail -n 10 "$d/ops.log")"
  il_t "$a" recreate-proxy --component "tor-$proxy" >"$d/recreate-proxy.tsv" 2>>"$d/ops.log" \
    || fail "$a: recreate-proxy: $(tail -n 10 "$d/ops.log")"
  # The recreated proxy needs its Tor bootstrap first (dry run 2026-10-02,
  # mint: SERVFAIL right after recreate-proxy): a fresh name every 15 s, up
  # to NDF_RETURN_S.
  t0="$(date +%s)"; k=0
  while :; do
    k=$((k + 1))
    r="$(ndf_fresh "$a" "$d/route-start-$k.tsv")"
    ndf_answered "$r" && break
    [ $(( $(date +%s) - t0 )) -lt "$NDF_RETURN_S" ] || fail "$a: the candidate answers no fresh name within $NDF_RETURN_S s ($r)"
    sleep 15
  done
  printf 'candidate_first_answer_s\t%s\n' "$(( $(date +%s) - t0 ))" >>"$d/cell.tsv"
  k=0
  il_report "$a" identity-start || fail "lifecycle-report"
  printf 'target_id\t%s\nplatform\t%s\nproxy\t%s\npihole\tstandard\nsource_rev\t%s\nimages\tgeneration-of-%s+proxy-%s\n' \
    "$a" "$plat" "$proxy" "$(il_sha)" "$(il_sha)" "${sha:0:12}" >"$d/identity.tsv"

  start="$(date +%s)"
  printf 'start\t%s\n' "$start" >>"$d/cell.tsv"
  at=( $((start + win / 6)) $((start + 2 * win / 6)) $((start + 4 * win / 6)) $((start + 5 * win / 6)) )
  next_rep="$start"; ev=0
  while :; do
    now="$(date +%s)"
    # The window, and every event even when they ran past it (a short dry run).
    [ "$now" -lt $((start + win)) ] || [ "$ev" -lt 4 ] || break
    if [ "$ev" -lt 4 ] && [ "$now" -ge "${at[$ev]}" ]; then
      e=$((ev + 1))
      if [ $((e % 2)) -eq 1 ]; then kind="sleep"; else kind="loss"; fi
      t0="$(date +%s)"
      if [ "$kind" = sleep ]; then
        rec="$(sk_sleep "$a" "$e")" || fail "$a: event $e (sleep) did not recover"
      else
        rec="$(ndf_loss "$a" "$d/events/loss-$e")" || fail "$a: event $e (network loss) did not recover"
      fi
      printf 'event\t%s\t%s\t%s\t%s\t%s\n' "$e" "$kind" "$t0" "$(date +%s)" "$rec" >>"$d/events.tsv"
      ev=$e
      continue
    fi
    if [ "$now" -ge "$next_rep" ]; then
      cs_report "$a" "reports/hour-$(( (now - start) / 3600 ))" || printf 'report\tfailed\t%s\n' "$now" >>"$d/cell.tsv"
      next_rep=$((next_rep + 3600))
    fi
    k=$((k + 1))
    for c in cold warm; do
      if [ "$c" = cold ]; then n=3; else n=5; fi
      if sk_collect "$a" "$c" "$n" "$d/blocks/$c-$k.tsv"; then sk_append "$d/blocks/$c-$k.tsv" "$d/samples.tsv"
      else printf 'tick\t%s\t%s\tcollect-failed\n' "$k" "$c" >>"$d/cell.tsv"; fi
    done
    now="$(date +%s)"
    [ $((start + k * SK_TICK)) -le "$now" ] || sleep $((start + k * SK_TICK - now))
  done
  assert_eq 4 "$(grep -c '^event	' "$d/events.tsv" 2>/dev/null)" "$a: all four events ran"
  cs_report "$a" reports/final || fail "$a: the final controller-report"
  il_report "$a" identity-end || fail "lifecycle-report"

  # The images that ran at the end are those of the start.
  assert_eq "$(il_sec "$d/identity-start.tsv" running | LC_ALL=C sort)" "$(il_sec "$d/identity-end.tsv" running | LC_ALL=C sort)" \
    "$a: the same images ran at the end as at the start"

  # Steady samples: outside every event, from its start to its recovery.
  steady="$d/steady.tsv"
  python3 - "$d/samples.tsv" "$d/events.tsv" "$steady" <<'PY'
import datetime, sys
src, ev, out = sys.argv[1:4]
win = []
for l in open(ev):
    p = l.rstrip("\n").split("\t")
    if p[0] == "event":
        win.append((int(p[3]), int(p[4])))
with open(src) as f, open(out, "w") as o:
    for i, l in enumerate(f):
        if i < 2:
            o.write(l); continue
        t = l.split("\t")[2]
        e = datetime.datetime.strptime(t[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp()
        if not any(a <= e <= b for a, b in win):
            o.write(l)
PY
  python3 "$SK_PA" check --cell "$plat/$proxy/standard" --candidate "$steady" >"$d/check.tsv" 2>"$d/check.err"
  for c in cold warm; do
    r="$(awk -F '\t' -v w="$c" '$1 == "workload" && $3 == w { print $4; exit }' "$d/check.tsv")"
    printf 'steady_%s\t%s\n' "$c" "$r" >>"$d/cell.tsv"
    if [ -z "${NICE_DNS_SOAK_SECS:-}" ]; then
      assert_eq pass "$r" "$a: steady $c meets the frozen limits ($(awk -F '\t' -v w="$c" '$1 == "workload" && $3 == w' "$d/check.tsv" | grep -oE 'timeouts_cand=[^	]*|reason=[^	]*' | tr '\n' ' '))"
    fi
  done

  # The controller: one pass at least every SK_GAP_S, except across a sleep.
  for r in "$d"/reports/*.tsv; do cs_ticks "$r" "$start"; done | LC_ALL=C sort -n -u -k1,1 >"$d/ticks.txt"
  awk -v g="$SK_GAP_S" 'NR > 1 && $1 - p > g { print p, $1 } { p = $1 }' "$d/ticks.txt" >"$d/tick-gaps.txt"
  bad="$(python3 - "$d/tick-gaps.txt" "$d/events.tsv" <<'PY'
import sys
gaps = [tuple(map(int, l.split())) for l in open(sys.argv[1]) if l.strip()]
sl = []
for l in open(sys.argv[2]):
    p = l.rstrip("\n").split("\t")
    if p[0] == "event" and p[2] == "sleep":
        sl.append((int(p[3]), int(p[4])))
for a, b in gaps:
    if not any(s <= b and a <= e for s, e in sl):
        print(a, b)
PY
)"
  assert_ne 0 "$(grep -c . "$d/ticks.txt")" "$a: the controller's passes were read"
  assert_eq "" "$bad" "$a: no pass gap over $SK_GAP_S s outside a sleep (no stale controller)"

  # Counted, not judged: recovery requests and proxy restarts.
  for r in "$d"/reports/*.tsv; do cs_jrows "$r" journal-active "$start"; done | LC_ALL=C sort -u >"$d/journal.tsv"
  {
    printf 'target\t%s\nplatform\t%s\ncell\t%s/%s/standard\nwindow_s\t%s\n' "$a" "$plat" "$plat" "$proxy" "$win"
    printf 'samples\t%s\nsteady_samples\t%s\n' "$(grep -vc '^#' "$d/samples.tsv")" "$(grep -vc '^#' "$steady")"
    awk -F '\t' '$1 ~ /^steady_/' "$d/cell.tsv"
    awk -F '\t' '$1 == "event" { print "event\t" $2 "\t" $3 "\trecovered_after_s=" $6 }' "$d/events.tsv"
    printf 'controller_passes\t%s\ntick_gaps_over_%ss\t%s\n' "$(grep -c . "$d/ticks.txt")" "$SK_GAP_S" "$(grep -c . "$d/tick-gaps.txt")"
    printf 'recovery_requests\t%s\n' "$(awk -F '\t' '$4 == "requested"' "$d/journal.tsv" | grep -c .)"
    printf 'bridge_refreshes\t%s\n' "$(awk -F '\t' '$3 == "bridges"' "$d/journal.tsv" | grep -c .)"
    printf 'proxy_starts\t%s\n' "$(for r in "$d"/reports/*.tsv; do cs_gen "$r"; done | grep . | LC_ALL=C sort -u | grep -c .)"
    printf 'manual_repair\tnone\n'
  } >"$d/summary.tsv"
  if [ "$win" -ge 86400 ]; then
    assert_ne 0 "$(awk -F '\t' '$3 == "bridges"' "$d/journal.tsv" | grep -c .)" "$a: the daily bridge refresh ran in the window"
  fi
}

t_1_soak() {
  cs_selection
  il_each sk_cell
}

t_2_evidence_is_private() {
  [ -d "$ARTIFACT_DIR/soak" ] || fail "no evidence: t_1 did not run"
  assert_eq "" "$(grep -rlE 'obfs4 |cert=|iat-mode=' "$ARTIFACT_DIR"/soak/*/*.tsv "$ARTIFACT_DIR"/soak/*/reports 2>/dev/null)" \
    "no bridge line in the soak's reports and summaries"
}
