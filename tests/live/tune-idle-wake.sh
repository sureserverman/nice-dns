# shellcheck shell=bash
# Group live/tune-idle-wake (Sub-plan 5 Stage 1 gate, B2; ARCH-09; DEC-012,
# DEC-015). Run once, on the final Stage 1 candidate, with `tests/run.sh live
# tune-idle-wake --live --targets FILE --platforms all --proxies all
# --comparison baseline`.
#
# The interleaved comparison of live/tune-transport (same cell, arms and
# candidate: this checkout's deployment with the proxy built from the sibling
# commit) for the two classes the baseline never measured:
#
#   idle  example.com after NICE_DNS_TI_GAP seconds without a client query
#         (default 305: past its 300 s TTL, so the answer has to come from
#         upstream over whatever the stack kept open, or from Unbound's
#         expired copy after serve-expired-client-timeout)
#   wake  one fresh name as soon as the default gateway answers after the
#         target slept NICE_DNS_TI_SLEEP seconds (default 60) and woke by
#         its own alarm (target.sh collect --after-sleep)
#
# Per block and arm: the restart sample of the swap (DEC-014), then 3 times
# gap, idle sample, sleep, wake sample. 10 blocks: 30 idle and 30 wake per arm
# (each class's budget), 10 restarts. About 21 minutes per block and arm, 7
# hours per platform; the platforms run side by side.
#
# The candidate arm runs as the product does: its controller's schedules are
# started after each swap to the candidate and stopped before each swap to
# the baseline (whose stack the controller does not manage). So the candidate
# holds the route its controller selects, and its per-minute passes run
# during the gaps. The baseline arm is the image swap of live/tune-resolver
# (b85bc9b's stack; its own 30-minute health job is not part of the arm).
#
# Evidence: $ARTIFACT_DIR/tune-idle-wake/<alias>/ (private).

TR_GROUP=tune-idle-wake
# shellcheck source=tests/live/tune-transport.sh
. "$NICE_DNS_ROOT/tests/live/tune-transport.sh"

TR_WORKLOADS=idle,wake,restart
TI_GAP="${NICE_DNS_TI_GAP:-305}"
TI_SLEEP="${NICE_DNS_TI_SLEEP:-60}"
TI_PER_BLOCK="${NICE_DNS_TI_PER_BLOCK:-3}"
TI_RETRY_WAIT="${NICE_DNS_TI_RETRY_WAIT:-60}"

tr_block() {
  local a="$1" arm="$2" k="$3" i=1 t
  while [ "$i" -le "$TI_PER_BLOCK" ]; do
    sleep "$TI_GAP"
    tr_collect "$a" "$arm" idle 1 "$k-$i"
    # A sleep can be cut short from outside (live mac 2026-09-30: a touch of
    # its mouse ended the sleep after 10 s and the cell with it): the wake
    # sample is tried up to 3 times, a minute apart.
    t=1
    until ( tr_collect "$a" "$arm" wake 1 "$k-$i" 0 "$TI_SLEEP" ); do
      [ "$t" -lt 3 ] || fail "$a: no wake sample ($arm, block $k-$i) in 3 tries"
      printf 'wake_retry\t%s\t%s\t%s\n' "$arm" "$k-$i" "$t" >>"$(il_dir "$a")/cell.tsv"
      t=$((t + 1)); sleep "$TI_RETRY_WAIT"
    done
    i=$((i + 1))
  done
}

ti_resume() {
  local d
  d="$(il_dir "$1")"
  il_t "$1" resume-agents >>"$d/agents.tsv" 2>>"$d/ops.log" || fail "$1: resume-agents: $(tail -n 5 "$d/agents.tsv")"
}

tr_hook_before_baseline() {
  local d
  d="$(il_dir "$1")"
  il_t "$1" quiesce-agents >>"$d/agents.tsv" 2>>"$d/ops.log" || fail "$1: quiesce-agents (block $2): $(tail -n 5 "$d/agents.tsv")"
}

# tune-transport's checks of the candidate swap (fix A, fix B) first.
eval "$(declare -f tr_hook_after_candidate | sed '1s/.*/tt_after_candidate ()/')"
tr_hook_after_candidate() { tt_after_candidate "$@"; ti_resume "$1"; }
