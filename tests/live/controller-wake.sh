# shellcheck shell=bash
# Group live/controller-wake (Sub-plan 3, Task 2.3's final-gate wake
# scenario; ARCH-07, ARCH-09). Run by the Stage 2 gate after
# live/controller-active, and alone when only the wake needs proving:
#   tests/run.sh live controller-wake --live --targets FILE --platforms all
#
#   CT-WAKE  on each target in turn, with the controller installed active,
#            the operator suspends the machine for at least 3 minutes and
#            wakes it (user choice: by hand). The case records the sleep
#            counter first, asks through "ACTION NEEDED" and the marker
#            <artifact dir>/WAKE-REQUEST-<alias>, and waits up to an hour
#            for the counter to rise and three passes to follow the gap the
#            sleep left: one pass a minute again, no recovery caused by the
#            time jump, the chain answering.
# Evidence: <artifact dir>/controller-active/wake-<alias>/ and wake.txt.

# shellcheck source=tests/live/controller-lib.sh
. "$NICE_DNS_ROOT/tests/live/controller-lib.sh"

CA_ROOT_DIR="" CA_CELL_DIR=""
cs_dir() { printf '%s\n' "$CA_CELL_DIR"; }

# ─────────────────────────── wake (by hand) ─────────────────────────────────

ca_woke() {
  local n
  n="$(cs_sleeps "$1")"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt "$CA_SLEEPS0" ] || return 1
  # Three passes after the gap the sleep left in the tick lines.
  cs_ticks "$1" "$CA_SINCE" | awk 'NR > 1 && $1 - p >= 120 { g = NR } { p = $1; n = NR } END { exit !(g && n - g >= 2) }'
}

ca_wake() {
  local plat="$1" a="$2" d
  CA_CELL_DIR="$CA_ROOT_DIR/wake-$a"; d="$CA_CELL_DIR"; mkdir -p "$d"
  cs_report "$a" wake-0 || fail "$a: report"
  CA_SINCE="$(cs_now "$d/wake-0.tsv")"; CA_SLEEPS0="$(cs_sleeps "$d/wake-0.tsv")"
  case "$CA_SLEEPS0" in ''|*[!0-9]*) fail "$a: no sleep counter in the report" ;; esac
  # The operator is asked through this marker (the session relays it).
  printf '%s\t%s\tsleep the machine for at least 3 minutes, then wake it\n' "$(date -u +%H:%M:%S)" "$a" >"$ARTIFACT_DIR/WAKE-REQUEST-$a"
  printf 'ACTION NEEDED: sleep %s for at least 3 minutes, then wake it (waiting up to 60 minutes)\n' "$a"
  cs_wait "$a" wake-1 3600 ca_woke || fail "$a: no sleep and wake with three later passes within 60 minutes"
  rm -f "$ARTIFACT_DIR/WAKE-REQUEST-$a"
  cs_ticks "$d/wake-1.tsv" "$CA_SINCE" >"$d/wake-ticks.txt"
  assert_eq "" "$(awk 'NR > 1 { g = $1 - p; if (g >= 120) seen = 1; else if (seen && (g < 30 || g > 120)) print g } { p = $1 }' "$d/wake-ticks.txt")" \
    "$a: after the wake, one pass a minute again"
  assert_eq "" "$(cs_jrows "$d/wake-1.tsv" journal-active "$CA_SINCE" | awk -F '\t' '$4 == "requested"')" "$a: the time jump caused no recovery action"
  ca_up "$d/wake-1.tsv" || fail "$a: the chain answers after the wake"
  { printf 'target\t%s\nplatform\t%s\nsleeps\t%s -> %s\n' "$a" "$plat" "$CA_SLEEPS0" "$(cs_sleeps "$d/wake-1.tsv")"
    awk 'NR > 1 && $1 - p >= 120 { printf "gap\t%s s before the pass at %s\n", $1 - p, $1 } { p = $1 }' "$d/wake-ticks.txt"; } >"$d/wake.txt"
}

t_1_wake() {
  local p
  cs_selection
  CA_ROOT_DIR="$ARTIFACT_DIR/controller-active"
  # One target at a time: the operator handles one machine, then the next.
  for p in $(cs_platforms); do
    cs_alias "$p"
    ( ca_wake "$p" "$CS_ALIAS" ) || fail "wake on $CS_ALIAS failed (see the case log)"
  done
  cat "$CA_ROOT_DIR"/wake-*/wake.txt >"$CA_ROOT_DIR/wake.txt"
}

