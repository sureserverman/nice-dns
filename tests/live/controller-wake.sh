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
  local plat="$1" a="$2" d t0
  CA_CELL_DIR="$CA_ROOT_DIR/wake-$a"; d="$CA_CELL_DIR"; mkdir -p "$d"
  # NICE_DNS_WAKE_BASELINE_DIR: an earlier run's artifact dir whose
  # wake-<alias>/wake-0.tsv was taken before a sleep the operator already did
  # (so a sleep is never asked for twice). It is copied into this run's
  # evidence and named in wake.txt.
  if [ -n "${NICE_DNS_WAKE_BASELINE_DIR:-}" ] && [ -f "$NICE_DNS_WAKE_BASELINE_DIR/controller-active/wake-$a/wake-0.tsv" ]; then
    cp "$NICE_DNS_WAKE_BASELINE_DIR/controller-active/wake-$a/wake-0.tsv" "$d/wake-0.tsv" || fail "$a: cannot copy the baseline"
    printf 'baseline	%s
' "$NICE_DNS_WAKE_BASELINE_DIR" >"$d/baseline.tsv"
  else
    cs_report "$a" wake-0 || fail "$a: report"
  fi
  CA_SINCE="$(cs_now "$d/wake-0.tsv")"; CA_SLEEPS0="$(cs_sleeps "$d/wake-0.tsv")"
  case "$CA_SLEEPS0" in ''|*[!0-9]*) fail "$a: no sleep counter in the report" ;; esac
  # The operator is asked through this marker (the session relays it).
  printf '%s\t%s\tsleep the machine for at least 3 minutes, then wake it\n' "$(date -u +%H:%M:%S)" "$a" >"$ARTIFACT_DIR/WAKE-REQUEST-$a"
  printf 'ACTION NEEDED: sleep %s for at least 3 minutes, then wake it (waiting up to 60 minutes)\n' "$a"
  # A sleeping target does not answer: a failed report here means "still
  # asleep" (live run 20260926T115513Z-0e67b953 quit on the first one).
  t0="$(date +%s)"
  while :; do
    if cs_report "$a" wake-1 && ca_woke "$d/wake-1.tsv"; then break; fi
    [ $(( $(date +%s) - t0 )) -lt 3600 ] || fail "$a: no sleep and wake with three later passes within 60 minutes"
    sleep 30
  done
  rm -f "$ARTIFACT_DIR/WAKE-REQUEST-$a"
  cs_ticks "$d/wake-1.tsv" "$CA_SINCE" >"$d/wake-ticks.txt"
  # After the gap: the pass the wake brings (a calendar schedule catches up
  # on resume: systemd Persistent=true, launchd StartCalendarInterval), then
  # the next wall-clock minute's pass, which may come seconds later (live,
  # mint 2026-09-26: 13:03:04 catch-up, 13:03:15 minute pass), then one a
  # minute. So the first interval after the gap is free; every later one is
  # 30..120 s.
  assert_eq "" "$(awk 'NR > 1 { g = $1 - p; if (g >= 120) { seen = 1; first = 1 } else if (seen && first) first = 0; else if (seen && (g < 30 || g > 120)) print g } { p = $1 }' "$d/wake-ticks.txt")" \
    "$a: after the wake's catch-up pass, one pass a minute again"
  assert_eq "" "$(cs_jrows "$d/wake-1.tsv" journal-active "$CA_SINCE" | awk -F '\t' '$4 == "requested"')" "$a: the time jump caused no recovery action"
  ca_up "$d/wake-1.tsv" || fail "$a: the chain answers after the wake"
  { printf 'target\t%s\nplatform\t%s\nsleeps\t%s -> %s\n' "$a" "$plat" "$CA_SLEEPS0" "$(cs_sleeps "$d/wake-1.tsv")"
    [ -f "$d/baseline.tsv" ] && cat "$d/baseline.tsv"
    awk 'NR > 1 && $1 - p >= 120 { printf "gap\t%s s before the pass at %s\n", $1 - p, $1 } { p = $1 }' "$d/wake-ticks.txt"; } >"$d/wake.txt"
}

# ca_reuse_wake <alias>: NICE_DNS_WAKE_REUSE_RUN names an earlier run whose
# live/controller-wake passed; its evidence for <alias> is copied with the run
# and the nice-dns revision it was taken at (user decision 2026-09-26: the
# representative gate reuses the day's wake instead of sleeping the machines
# again; the revision says it predates later fixes).
ca_reuse_wake() {
  local src="$NICE_DNS_WAKE_REUSE_RUN" a="$1"
  assert_match '	t_1_wake	pass$' "$(grep -F 'live/controller-wake' "$src/results.tsv" 2>/dev/null)" "the reused run's wake passed ($src)"
  assert_file "$src/controller-active/wake-$a/wake.txt" "$a: the reused run has wake evidence"
  mkdir -p "$CA_ROOT_DIR/wake-$a" && cp "$src/controller-active/wake-$a/"* "$CA_ROOT_DIR/wake-$a/" || fail "cannot copy the wake evidence"
  printf 'reused_from\t%s\tnice-dns %s\n' "$(basename "$src")" "$(awk -F '\t' '$1 == "git_head" { print $2 }' "$src/receipt.tsv")" >>"$CA_ROOT_DIR/wake-$a/wake.txt"
}

t_1_wake() {
  local p
  cs_selection
  CA_ROOT_DIR="$ARTIFACT_DIR/controller-active"
  if [ -n "${NICE_DNS_WAKE_REUSE_RUN:-}" ]; then
    for p in $(cs_platforms); do cs_alias "$p"; ca_reuse_wake "$CS_ALIAS"; done
    cat "$CA_ROOT_DIR"/wake-*/wake.txt >"$CA_ROOT_DIR/wake.txt"
    return 0
  fi
  # One target at a time: the operator handles one machine, then the next.
  for p in $(cs_platforms); do
    cs_alias "$p"
    ( ca_wake "$p" "$CS_ALIAS" ) || fail "wake on $CS_ALIAS failed (see the case log)"
  done
  cat "$CA_ROOT_DIR"/wake-*/wake.txt >"$CA_ROOT_DIR/wake.txt"
}

