#!/usr/bin/env bash
# Baseline characterization of one deployed cell (sub-plan 01, Task 2.3;
# ARCH-09). Observes; never repairs.
#
# Usage:
#   bash tests/live/baseline.sh characterize ALIAS --targets FILE [--label NAME]
#   bash tests/live/baseline.sh matrix ALIAS --targets FILE --source-sha SHA
#   bash tests/live/baseline.sh receipt --out DIR CELLDIR...
#
# characterize runs, against the cell the target currently runs (no
# reinstall), in this order:
#   snapshot, config          BL-CONFIG: images, versions, effective configs
#   cold, prime + warm        BL-COLD, BL-WARM: samples + stats aggregates
#   health (before)           the existing health verdict on a working chain
#   freeze-upstream           SIGSTOP tor in the proxy container: Pi-hole,
#                             Unbound and the proxy all keep listening
#   wait, health, cold, warm  BL-SEVERED: DNS outcome and the existing health
#                             verdict with upstream dead
#   thaw-upstream, recovery   time to the first answered cold query
#   restore, snapshot, cold   BL-RESTORED: containers, states and addresses
#                             equal the first snapshot, tor not stopped, and
#                             an uncached query answers
# into $ARTIFACT_DIR/baseline/NAME/ (NAME defaults to ALIAS). A scenario is "pass" when its
# observation is complete; product behaviour is recorded, not judged, in
# findings.tsv (e.g. health reporting healthy while upstream is dead). The
# upstream is always thawed and the snapshot's containers restarted on exit,
# including on error or interrupt; target.sh's remote dead-man timer thaws
# tor even if this process is killed.
#
# matrix installs every cell of ALIAS's platform (tests/manifests/matrix.tsv)
# with target.sh install-cell at SHA, the cell ALIAS ran before last so the
# target ends on it, waits for the first answered uncached query after each
# install (NICE_DNS_BASELINE_READY_SECS, default 1500) and characterizes each
# cell as label ALIAS-PROXY-PIHOLE. Install logs stay in
# $ARTIFACT_DIR/baseline-matrix/ALIAS/ and never enter a receipt (installer
# output can carry bridge lines).
#
# receipt assembles a nice-dns-receipt/1 "baseline" receipt from cell dirs
# (plus BL-STAGE and BL-INVENTORY evidence) for tests/reports/verify.sh, and
# freezes the per-platform targets from those cells into BL-TARGETS.txt.
#
# Environment (all optional): NICE_DNS_BASELINE_COLD (30), _WARM (100),
#   _SEVER_SECS (120, the wait before the severed observation: three podman
#   healthcheck intervals plus margin), _SEVERED_COUNT (5), _RECOVERY_COUNT
#   (36 attempts, 5 s apart), _TIMEOUT_MS (5000).
# Exit: 0 every scenario observed; 1 an observation is missing or the target
#   was not restored; 2 usage or refused.
# Portability: Bash 3.2.

set -u
umask 077

BL_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# Unit tests substitute a fake adapter; the live group refuses the override.
TGT="${NICE_DNS_TARGET_ADAPTER:-$BL_ROOT/tests/live/target.sh}"
STATS="$BL_ROOT/tests/reports/stats.sh"
TAB="$(printf '\t')"
SCENARIOS='BL-CONFIG BL-COLD BL-WARM BL-SEVERED BL-RESTORED'

die() { printf 'baseline.sh: %s\n' "$*" >&2; exit 2; }
say() { printf 'baseline.sh: %s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

num() {
  # num NAME DEFAULT: a positive integer from the environment.
  local v
  eval "v=\${$1:-$2}"
  case "$v" in ''|*[!0-9]*|0) die "$1 must be a positive integer" ;; esac
  printf '%s\n' "$v"
}

# ─── characterize ────────────────────────────────────────────────────────────

cmd_characterize() {
  local alias_="${1:-}" targets='' platform label=''
  [ $# -gt 0 ] && shift
  case "$alias_" in ''|-*) die "usage: baseline.sh characterize ALIAS --targets FILE [--label NAME]" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --targets|--label)
        [ $# -ge 2 ] || die "$1 needs a value"
        if [ "$1" = --targets ]; then targets="$2"; else label="$2"; fi
        shift 2 ;;
      *) die "unknown option '$1'" ;;
    esac
  done
  label="${label:-$alias_}"
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || die "--label must be a lowercase word"
  [ -n "$targets" ] || die "missing --targets FILE"
  case "${ARTIFACT_DIR:-}" in /*) ;; *) die "ARTIFACT_DIR must be the run's absolute artifact dir" ;; esac
  [ -n "${RUN_ID:-}" ] || die "RUN_ID must be set (tests/run.sh sets it)"
  platform="$(bash "$TGT" validate --targets "$targets" | awk -F '\t' -v a="$alias_" '$1 == a { print $2 }')"
  [ -n "$platform" ] || die "alias '$alias_' is not in $targets"

  N_COLD="$(num NICE_DNS_BASELINE_COLD 30)"
  N_WARM="$(num NICE_DNS_BASELINE_WARM 100)"
  SEVER_SECS="$(num NICE_DNS_BASELINE_SEVER_SECS 120)"
  N_SEV="$(num NICE_DNS_BASELINE_SEVERED_COUNT 5)"
  N_REC="$(num NICE_DNS_BASELINE_RECOVERY_COUNT 36)"
  TMO="$(num NICE_DNS_BASELINE_TIMEOUT_MS 5000)"

  ALIAS="$alias_" TARGETS="$targets" PLATFORM="$platform"
  D="$ARTIFACT_DIR/baseline/$label"
  [ -L "$ARTIFACT_DIR/baseline" ] || [ -L "$D" ] && die "baseline state path is a symlink"
  [ -e "$D" ] && die "$D already exists: one characterization per label per run"
  mkdir -p "$D" || die "cannot create $D"
  : >"$D/observations.tsv"
  : >"$D/findings.tsv"
  FROZEN=no PROXY_C=''
  trap on_exit EXIT
  trap 'exit 130' INT TERM

  observe
}

t() { bash "$TGT" "$1" "$ALIAS" --targets "$TARGETS" "${@:2}"; }

record() {
  # record SCENARIO pass|fail ARTIFACT NOTE
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$D/observations.tsv"
  say "$1 $2 ($4)"
}

finding() { printf '%s\t%s\n' "$1" "$2" >>"$D/findings.tsv"; say "finding: $1 — $2"; }

kv() { awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$2"; }

on_exit() {
  local rc=$?
  if [ "$FROZEN" = yes ]; then
    say "exit with upstream frozen: thawing $PROXY_C"
    t thaw-upstream --component "$PROXY_C" >>"$D/cleanup.log" 2>&1 || say "thaw failed; the remote dead-man timer thaws it"
    t restore >>"$D/cleanup.log" 2>&1 || say "restore failed (see $D/cleanup.log)"
  fi
  exit "$rc"
}

collect() {
  # collect WORKLOAD COUNT FILE [PAUSE_MS]: samples into FILE. 0 observed
  # (every attempt kept, answered or not); 1 nothing usable came back.
  local rc
  t collect --workload "$1" --count "$2" --identity "$D/identity.tsv" --timeout-ms "$TMO" \
    --pause-ms "${4:-0}" >"$3" 2>>"$D/collect.log"
  rc=$?
  case "$rc" in 0|3) ;; *) say "collect $1 failed (exit $rc)"; return 1 ;; esac
  [ "$(grep -vc '^#' "$3")" -eq "$(($2 + 1))" ] || { say "collect $1: expected $2 rows in $3"; return 1; }
  bash "$STATS" "$3" >"${3%.tsv}.stats.tsv" 2>>"$D/collect.log" || return 1
  return 0
}

answered() { awk -F '\t' 'NR > 2 && ($17 == "ok" || $17 == "nxdomain") { n++ } END { print n + 0 }' "$1"; }
attempts() { awk -F '\t' 'NR > 2 { n++ } END { print n + 0 }' "$1"; }

# The stack's own containers only: the product also runs short-lived ones
# (macOS bridge-eval's anonymous probe container on dnsnet) that are not
# state a restore owns.
containers_of() {
  awk -F '\t' '$1 == "section" { s = $2; next }
    s == "containers" && ($1 == "pi-hole" || $1 == "unbound" || $1 == "tor-haproxy" || $1 == "tor-socat") { print $1 "\t" $2 "\t" $3 }' "$1" | LC_ALL=C sort
}

identify() {
  # identify CONFIG DIR: identity.tsv + cell.tsv from a config dump; 1 when
  # the dump does not identify a complete cell (sets ID_NOTE).
  local cfg="$1" dir="$2" proxy pihole images src n pc
  pc="$(kv proxy_component "$cfg")"
  proxy="${pc#tor-}"
  pihole="$(kv pihole_variant "$cfg")"
  images="$(awk -F '\t' '$1 == "image" { printf "%s%s=%s", (n++ ? "," : ""), $2, $4 }' "$cfg")"
  src="$(GIT_OPTIONAL_LOCKS=0 git -C "$BL_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  n="$(awk -F '\t' '$1 == "image" && $4 ~ /^sha256:[0-9a-f]{64}$/' "$cfg" | grep -c .)"
  ID_NOTE="proxy='$pc' pihole='$pihole' image digests=$n of 3"
  if [ -z "$pc" ] || [ "$n" -ne 3 ] || { [ "$pihole" != standard ] && [ "$pihole" != hardened ]; } \
      || ! grep -q '^unbound_conf	' "$cfg" || ! grep -q '^pihole_upstream	' "$cfg"; then
    return 1
  fi
  {
    printf 'target_id\t%s\nplatform\t%s\nproxy\t%s\npihole\t%s\n' "$ALIAS" "$PLATFORM" "$proxy" "$pihole"
    printf 'source_rev\t%s\nimages\t%s\n' "$src" "$images"
  } >"$dir/identity.tsv"
  printf 'cell\t%s/%s/%s\ntarget\t%s\nimage_gen\t%s\n' "$PLATFORM" "$proxy" "$pihole" "$ALIAS" "$images" >"$dir/cell.tsv"
  ID_NOTE="$PLATFORM/$proxy/$pihole images=$images"
  return 0
}

observe() {
  local a first
  say "characterizing $ALIAS ($PLATFORM) into $D"

  # ── BL-CONFIG ──
  t snapshot >"$D/snapshot.log" 2>&1 || { record BL-CONFIG fail snapshot.log "snapshot refused or failed"; return 1; }
  cp "$ARTIFACT_DIR/targets/$ALIAS/snapshot.tsv" "$D/snapshot-before.tsv"
  t config >"$D/config.tsv" 2>"$D/config.err" || { record BL-CONFIG fail config.err "config failed"; return 1; }
  PROXY_C="$(kv proxy_component "$D/config.tsv")"
  if ! identify "$D/config.tsv" "$D"; then
    record BL-CONFIG fail config.tsv "incomplete: $ID_NOTE"
    return 1
  fi
  record BL-CONFIG pass config.tsv "$ID_NOTE"

  # ── BL-COLD / BL-WARM on a working chain ──
  if collect cold "$N_COLD" "$D/samples-cold.tsv"; then
    record BL-COLD pass samples-cold.tsv "attempted=$N_COLD answered=$(answered "$D/samples-cold.tsv")"
  else record BL-COLD fail collect.log "cold samples incomplete"; fi
  if collect warm 1 "$D/samples-prime.tsv" && collect warm "$N_WARM" "$D/samples-warm.tsv"; then
    record BL-WARM pass samples-warm.tsv "attempted=$N_WARM answered=$(answered "$D/samples-warm.tsv")"
  else record BL-WARM fail collect.log "warm samples incomplete"; fi
  t health >"$D/health-before.tsv" 2>>"$D/health.err" || say "health (before) failed"

  # ── BL-SEVERED: freeze tor, every listener stays up ──
  if ! t freeze-upstream --component "$PROXY_C" >"$D/freeze.tsv" 2>&1; then
    record BL-SEVERED fail freeze.tsv "freeze-upstream failed"
    t thaw-upstream --component "$PROXY_C" >>"$D/cleanup.log" 2>&1
  else
    FROZEN=yes
    printf 'frozen_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$D/freeze.tsv"
    say "upstream frozen; waiting ${SEVER_SECS}s for the existing health mechanisms to run"
    sleep "$SEVER_SECS" & wait $!   # wait, unlike a foreground sleep, returns to the INT/TERM trap at once
    t config >"$D/config-severed.tsv" 2>>"$D/config.err" || say "config (severed) failed"
    t health >"$D/health-severed.tsv" 2>>"$D/health.err"; a=$?
    if collect cold "$N_SEV" "$D/samples-severed-cold.tsv" && collect warm "$N_SEV" "$D/samples-severed-warm.tsv" && [ "$a" -eq 0 ]; then
      record BL-SEVERED pass health-severed.tsv "cold answered=$(answered "$D/samples-severed-cold.tsv")/$N_SEV warm answered=$(answered "$D/samples-severed-warm.tsv")/$N_SEV tor_state=$(kv tor_state "$D/config-severed.tsv")"
      judge_severed
    else
      record BL-SEVERED fail health.err "severed observation incomplete (health exit $a)"
    fi
    t thaw-upstream --component "$PROXY_C" >"$D/thaw.tsv" 2>&1 || say "thaw reported a problem (see thaw.tsv)"
    FROZEN=no
    printf 'thawed_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$D/thaw.tsv"
  fi

  # ── recovery and BL-RESTORED ──
  collect cold "$N_REC" "$D/samples-recovery.tsv" 5000 || say "recovery samples incomplete"
  first="$(awk -F '\t' 'NR > 2 && ($17 == "ok" || $17 == "nxdomain") { print $2; exit }' "$D/samples-recovery.tsv" 2>/dev/null)"
  printf 'first_answered_attempt\t%s\nattempts\t%s\n' "${first:-none}" "$(attempts "$D/samples-recovery.tsv" 2>/dev/null)" >"$D/recovery.tsv"
  t restore >"$D/restore.log" 2>&1 || say "restore reported a failure"
  t config >"$D/config-after.tsv" 2>>"$D/config.err" || say "config (after) failed"
  t health >"$D/health-after.tsv" 2>>"$D/health.err" || say "health (after) failed"
  collect cold 5 "$D/samples-after.tsv" || say "post-restore samples incomplete"
  containers_of "$D/snapshot-before.tsv" >"$D/containers-before.tsv"
  containers_of "$D/config-after.tsv" >"$D/containers-after.tsv"
  if cmp -s "$D/containers-before.tsv" "$D/containers-after.tsv" \
      && [ -s "$D/containers-before.tsv" ] \
      && [ -n "$(kv tor_state "$D/config-after.tsv")" ] \
      && ! printf ' %s ' "$(kv tor_state "$D/config-after.tsv")" | grep -q ' T ' \
      && [ -f "$D/samples-after.tsv" ] && [ "$(answered "$D/samples-after.tsv")" -ge 1 ]; then
    record BL-RESTORED pass containers-after.tsv "containers equal the snapshot; post-restore cold answered=$(answered "$D/samples-after.tsv")/5; first recovery answer at attempt ${first:-none}"
  else
    record BL-RESTORED fail containers-after.tsv "target not back to its snapshot state (see containers-before/after.tsv, samples-after.tsv)"
  fi
  compare_config
  complete
}

verdict_of() {
  # verdict_of FILE SOURCE: that health source's verdict, or nothing.
  awk -F '\t' -v s="$2" '$1 == "health" && $2 == s { print $3; exit }' "$1" 2>/dev/null
}

judge_severed() {
  # Findings, per existing health source, against its verdict on the
  # working chain before the fault (BL-018, EVD-CACHE-NOT-UPSTREAM):
  #   green before, green while uncached queries fail  -> health-false-green
  #   green before, red while severed                  -> health-detects
  #   red before (nothing to compare)                   -> health-not-discriminating
  local cold warm src v b
  cold="$(answered "$D/samples-severed-cold.tsv")"
  warm="$(answered "$D/samples-severed-warm.tsv")"
  if [ "$cold" -eq 0 ]; then
    [ "$warm" -gt 0 ] && finding cache-masks-outage "$warm/$N_SEV cached queries answered with upstream dead"
  else
    finding severed-cold-answered "$cold/$N_SEV uncached queries answered with tor stopped"
  fi
  while IFS="$TAB" read -r _ src v _; do
    b="$(verdict_of "$D/health-before.tsv" "$src")"
    case "$b:$v" in
      healthy:healthy|pass:pass)
        [ "$cold" -eq 0 ] && finding health-false-green "$src stayed $v while 0/$N_SEV uncached queries were answered" ;;
      healthy:*|pass:*) finding health-detects "$src went $b -> $v with upstream dead" ;;
      unhealthy:*|fail:*) finding health-not-discriminating "$src was already $b on the working chain (severed: $v)" ;;
    esac
  done < <(awk -F '\t' '$1 == "health"' "$D/health-severed.tsv")
  [ "$(kv tor_state "$D/config-severed.tsv")" = T ] \
    || finding upstream-self-recovered "tor was not stopped at the severed observation (state '$(kv tor_state "$D/config-severed.tsv")'): something restarted it"
}

compare_config() {
  # A container restarted by the runtime's own health action changes no
  # state, but its start time does; record it.
  local b a
  b="$(grep -c . "$D/containers-before.tsv")"; a="$(grep -c . "$D/containers-after.tsv")"
  [ "$b" = "$a" ] || finding container-set-changed "before=$b after=$a containers"
  local src v
  while IFS="$TAB" read -r _ src v _; do
    case "$v" in unhealthy|fail) finding health-red-when-working "$src reported $v on a working chain (before the fault)" ;; esac
  done < <(awk -F '\t' '$1 == "health"' "$D/health-before.tsv" 2>/dev/null)
  # A runtime health action that restarted a container shows as a changed
  # start time, not a changed state.
  local c t0 t1
  while IFS="$TAB" read -r _ c t0; do
    t1="$(awk -F '\t' -v c="$c" '$1 == "started" && $2 == c { print $3; exit }' "$D/config-after.tsv")"
    [ "$t0" = "$t1" ] || finding container-restarted "$c started $t0, now $t1"
  done < <(awk -F '\t' '$1 == "started"' "$D/config.tsv")
}

complete() {
  local s missing=0 st
  for s in $SCENARIOS; do
    st="$(awk -F '\t' -v s="$s" '$1 == s { v = $2 } END { print v }' "$D/observations.tsv")"
    [ "$st" = pass ] || { say "scenario $s not observed (${st:-missing})"; missing=1; }
  done
  [ "$missing" -eq 0 ]
}

# ─── matrix ──────────────────────────────────────────────────────────────────

cmd_matrix() {
  local alias_="${1:-}" targets='' sha='' platform M cells c orig got label rc=0 ready
  [ $# -gt 0 ] && shift
  case "$alias_" in ''|-*) die "usage: baseline.sh matrix ALIAS --targets FILE --source-sha SHA" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --targets|--source-sha)
        [ $# -ge 2 ] || die "$1 needs a value"
        if [ "$1" = --targets ]; then targets="$2"; else sha="$2"; fi
        shift 2 ;;
      *) die "unknown option '$1'" ;;
    esac
  done
  [ -n "$targets" ] || die "missing --targets FILE"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "--source-sha must be a full commit id"
  case "${ARTIFACT_DIR:-}" in /*) ;; *) die "ARTIFACT_DIR must be the run's absolute artifact dir" ;; esac
  [ -n "${RUN_ID:-}" ] || die "RUN_ID must be set (tests/run.sh sets it)"
  platform="$(bash "$TGT" validate --targets "$targets" | awk -F '\t' -v a="$alias_" '$1 == a { print $2 }')"
  [ -n "$platform" ] || die "alias '$alias_' is not in $targets"
  ALIAS="$alias_" TARGETS="$targets" PLATFORM="$platform"
  READY_SECS="$(num NICE_DNS_BASELINE_READY_SECS 1500)"
  TMO="$(num NICE_DNS_BASELINE_TIMEOUT_MS 5000)"
  M="$ARTIFACT_DIR/baseline-matrix/$alias_"
  [ -e "$M" ] && die "$M already exists"
  mkdir -p "$M" || die "cannot create $M"
  : >"$M/cells.tsv"

  # The cell the target runs now is installed last, so the target ends on it.
  t config >"$M/original-config.tsv" 2>"$M/original-config.err" || die "cannot read $ALIAS's current config"
  mkdir -p "$M/original"
  identify "$M/original-config.tsv" "$M/original" || die "cannot identify $ALIAS's current cell ($ID_NOTE); nothing to return it to"
  orig="$(kv cell "$M/original/cell.tsv")"; orig="${orig#*/}"
  cells="$(awk -F '\t' -v p="$PLATFORM" '!/^#/ && $1 == p { print $2 "/" $3 }' "$BL_ROOT/tests/manifests/matrix.tsv")"
  printf '%s\n' "$cells" | grep -Fxq -- "$orig" || die "current cell $orig is not in the matrix"
  cells="$(printf '%s\n' "$cells" | grep -Fxv -- "$orig"; printf '%s\n' "$orig")"
  say "matrix for $ALIAS ($PLATFORM): $(printf '%s ' $cells)(ends on $orig)"

  for c in $cells; do
    label="$ALIAS-${c%/*}-${c#*/}"
    say "installing $PLATFORM/$c on $ALIAS"
    if ! t snapshot >>"$M/$label.log" 2>&1 || ! t install-cell --cell "$c" --source-sha "$sha" >"$M/install-$label.log" 2>&1; then
      printf '%s\tinstall-failed\t%s\n' "$c" "install-$label.log" >>"$M/cells.tsv"; rc=1; continue
    fi
    if ! ready="$(wait_ready "$label")"; then
      printf '%s\tnot-ready\t%s\n' "$c" "$ready" >>"$M/cells.tsv"; rc=1; continue
    fi
    if ! bash "$0" characterize "$ALIAS" --targets "$TARGETS" --label "$label" >>"$M/$label.log" 2>&1; then
      printf '%s\tobservation-incomplete\t%s\n' "$c" "$ready" >>"$M/cells.tsv"; rc=1; continue
    fi
    got="$(kv cell "$ARTIFACT_DIR/baseline/$label/cell.tsv")"
    if [ "$got" != "$PLATFORM/$c" ]; then
      printf '%s\twrong-cell-installed\t%s\n' "$c" "$got" >>"$M/cells.tsv"; rc=1; continue
    fi
    printf '%s\tobserved\t%s\n' "$c" "$ready" >>"$M/cells.tsv"
  done
  t config >"$M/final-config.tsv" 2>>"$M/original-config.err"
  mkdir -p "$M/final"
  if identify "$M/final-config.tsv" "$M/final" && [ "$(kv cell "$M/final/cell.tsv")" = "$PLATFORM/$orig" ]; then
    say "$ALIAS ends on its original cell $PLATFORM/$orig"
  else
    say "$ALIAS does not end on its original cell $PLATFORM/$orig ($ID_NOTE)"; rc=1
  fi
  cat "$M/cells.tsv" >&2
  return "$rc"
}

wait_ready() {
  # wait_ready LABEL: poll one uncached query every 15 s until one is
  # answered; prints "ready_after_s=N attempts=K" (or the timeout note).
  local dir="$M/ready-$1" start now k=0 f
  mkdir -p "$dir"
  start="$(date +%s)"
  while :; do
    k=$((k + 1))
    if t config >"$dir/config.tsv" 2>/dev/null && identify "$dir/config.tsv" "$dir"; then
      f="$dir/attempt-$k.tsv"
      t collect --workload cold --count 1 --identity "$dir/identity.tsv" --timeout-ms "$TMO" >"$f" 2>/dev/null
      if [ "$(answered "$f")" -ge 1 ]; then
        now="$(date +%s)"; printf 'ready_after_s=%s attempts=%s\n' "$((now - start))" "$k"; return 0
      fi
    fi
    now="$(date +%s)"
    if [ $((now - start)) -ge "$READY_SECS" ]; then printf 'not ready after %ss (%s attempts)\n' "$READY_SECS" "$k"; return 1; fi
    sleep 15
  done
}

# ─── receipt ─────────────────────────────────────────────────────────────────

cmd_receipt() {
  local out='' cd r repo sib key gen s st a f
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] || die "--out needs a value"; out="$2"; shift 2 ;;
      --*) die "unknown option '$1'" ;;
      *) break ;;
    esac
  done
  [ -n "$out" ] || die "missing --out DIR"
  [ $# -ge 1 ] || die "usage: baseline.sh receipt --out DIR CELLDIR..."
  [ -e "$out/receipt.tsv" ] && die "$out/receipt.tsv exists"
  mkdir -p "$out/cells" || die "cannot create $out"
  sib="${NICE_DNS_SIBLINGS_DIR:-$(cd "$BL_ROOT/.." && pwd -P)}"
  r="$out/receipt.tsv"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\tbaseline\nrun_id\t%s\ncreated_utc\t%s\n' "${RUN_ID:?RUN_ID must be set}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for repo in nice-dns tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      if [ "$repo" = nice-dns ]; then cd="$BL_ROOT"; else cd="$sib/$repo"; fi
      if [ -n "$(GIT_OPTIONAL_LOCKS=0 git -C "$cd" status --porcelain --untracked-files=no 2>/dev/null)" ]; then st=dirty; else st=clean; fi
      printf 'source\t%s\t%s\t%s\n' "$repo" "$(git -C "$cd" rev-parse HEAD)" "$st"
    done
    for repo in tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      printf 'arch\t%s\t%s\t%s\n' "$repo" "$(git -C "$sib/$repo" rev-parse HEAD)" \
        "$(git -C "$sib/$repo" show HEAD:.github/workflows/main.yml |
          awk '/^ *platform: *$/ { on = 1; next } on && /^ *- *linux\// { sub(/^ *- */, ""); print; next } on { on = 0 }' |
          sort | paste -sd, -)"
    done
  } >"$r"
  for s in BL-STAGE BL-INVENTORY; do
    a="${NICE_DNS_BASELINE_GLOBAL_DIR:-}/$s.txt"
    [ -f "$a" ] || die "global evidence $a missing (set NICE_DNS_BASELINE_GLOBAL_DIR)"
    cp "$a" "$out/$s.txt"
    printf 'scenario\t%s\t-\tpass\t%s.txt\t%s\t-\n' "$s" "$s" "$(sha "$out/$s.txt")" >>"$r"
  done
  freeze_targets "$out/BL-TARGETS.txt" "$@" || die "cannot freeze targets"
  printf 'scenario\tBL-TARGETS\t-\tpass\tBL-TARGETS.txt\t%s\t-\n' "$(sha "$out/BL-TARGETS.txt")" >>"$r"
  for cd in "$@"; do
    [ -f "$cd/cell.tsv" ] && [ -f "$cd/observations.tsv" ] || die "$cd is not a characterized cell dir"
    key="$(kv cell "$cd/cell.tsv")"; gen="$(kv image_gen "$cd/cell.tsv")"
    a="cells/$(printf '%s' "$key" | tr / -)"
    [ -e "$out/$a" ] && die "cell $key given twice"
    mkdir -p "$out/$a"
    cp "$cd"/*.tsv "$out/$a/"
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "${key%%/*}" "$(printf '%s' "$key" | cut -d/ -f2)" "${key##*/}" \
      "$(kv target "$cd/cell.tsv")" "$gen" >>"$r"
    while IFS="$TAB" read -r s st f _; do
      printf 'scenario\t%s\t%s\t%s\t%s/%s\t%s\t%s\n' "$s" "$key" "$st" "$a" "$f" "$(sha "$out/$a/$f")" "$gen" >>"$r"
    done <"$cd/observations.tsv"
    for f in "$out/$a"/samples-*.tsv; do
      case "$f" in *.stats.tsv) continue ;; esac
      [ -f "${f%.tsv}.stats.tsv" ] || continue
      printf 'aggregate\t%s\t%s\t%s\n' "${f#"$out"/}" "$(sha "${f%.tsv}.stats.tsv")" "${f#"$out"/}" |
        awk -F '\t' 'BEGIN { OFS = "\t" } { sub(/\.tsv$/, ".stats.tsv", $2); print }' >>"$r"
    done
  done
  printf '%s\n' "$r"
}

freeze_targets() {
  # freeze_targets OUT CELLDIR...: the baseline each later candidate is held
  # to (master plan, Acceptance targets), frozen before any tuning.
  local out="$1" cd key w f
  shift
  {
    printf '# nice-dns baseline targets, frozen from this receipt before tuning (sub-plan 05 compares against them)\n'
    printf 'coverage\t%s cells\n' "$#"
    printf 'rule\tno-timeout-regression: per cell and workload, a candidate timeout_rate must not exceed the baseline timeout_rate\n'
    printf 'rule\timprove-problem-class: per platform, at least one previously problematic cold/idle/post-wake class improves beyond measured variability (interleaved runs, same workload)\n'
    printf 'rule\tsecurity-absolute: no latency target is met by weakening TLS, DNSSEC or the no-direct-resolver guarantees\n'
    for cd in "$@"; do
      key="$(kv cell "$cd/cell.tsv")"
      for w in cold warm; do
        f="$cd/samples-$w.stats.tsv"
        [ -f "$f" ] || return 1
        awk -F '\t' -v k="$key" -v w="$w" 'NR > 1 && $1 == w {
          printf "cell\t%s\t%s\tattempted=%s\ttimeout_rate=%s\tfailure_rate=%s\tp50_all_us=%s\tp95_all_us=%s\tp99_all_us=%s\tp95_support=%s\n", k, w, $2, $7, $6, $11, $12, $13, $15 }' "$f"
      done
    done
  } >"$out.tmp" || return 1
  awk -F '\t' '$1 == "cell" { split($2, c, "/"); p = c[1]; w = $3
      sub(/^timeout_rate=/, "", $5); t = $5; sub(/^p95_all_us=/, "", $8); q = $8
      key = p "\t" w
      if (!(key in tmax) || t + 0 > tmax[key] + 0) tmax[key] = t
      if (q == "inf" || q == "n/a") qmax[key] = q
      else if (!(key in qmax) || (qmax[key] != "inf" && qmax[key] != "n/a" && q + 0 > qmax[key] + 0)) qmax[key] = q }
    END { for (k in tmax) printf "target\t%s\ttimeout_rate_max=%s\tp95_all_us_max=%s\n", k, tmax[k], qmax[k] }' "$out.tmp" |
    LC_ALL=C sort >>"$out.tmp"
  mv "$out.tmp" "$out"
}

case "${1:-}" in
  characterize) shift; cmd_characterize "$@" ;;
  matrix) shift; cmd_matrix "$@" ;;
  receipt) shift; cmd_receipt "$@" ;;
  *) die "usage: baseline.sh characterize ALIAS --targets FILE [--label NAME] | matrix ALIAS --targets FILE --source-sha SHA | receipt --out DIR CELLDIR..." ;;
esac
