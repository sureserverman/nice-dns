#!/usr/bin/env bash
# Baseline characterization of one deployed cell (sub-plan 01, Task 2.3;
# ARCH-09). Observes; never repairs.
#
# Usage:
#   bash tests/live/baseline.sh characterize ALIAS --targets FILE
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
# into $ARTIFACT_DIR/baseline/ALIAS/. A scenario is "pass" when its
# observation is complete; product behaviour is recorded, not judged, in
# findings.tsv (e.g. health reporting healthy while upstream is dead). The
# upstream is always thawed and the snapshot's containers restarted on exit,
# including on error or interrupt; target.sh's remote dead-man timer thaws
# tor even if this process is killed.
#
# receipt assembles a nice-dns-receipt/1 "baseline" receipt from cell dirs
# (plus BL-STAGE and BL-INVENTORY evidence) for tests/reports/verify.sh.
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
  local alias_="${1:-}" targets='' platform
  [ $# -gt 0 ] && shift
  case "$alias_" in ''|-*) die "usage: baseline.sh characterize ALIAS --targets FILE" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --targets) [ $# -ge 2 ] || die "--targets needs a value"; targets="$2"; shift 2 ;;
      *) die "unknown option '$1'" ;;
    esac
  done
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
  D="$ARTIFACT_DIR/baseline/$alias_"
  [ -L "$ARTIFACT_DIR/baseline" ] || [ -L "$D" ] && die "baseline state path is a symlink"
  [ -e "$D" ] && die "$D already exists: one characterization per alias per run"
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

containers_of() { awk -F '\t' '$1 == "section" { s = $2; next } s == "containers" { print $1 "\t" $2 "\t" $3 }' "$1" | LC_ALL=C sort; }

observe() {
  local proxy pihole images src n a first
  say "characterizing $ALIAS ($PLATFORM) into $D"

  # ── BL-CONFIG ──
  t snapshot >"$D/snapshot.log" 2>&1 || { record BL-CONFIG fail snapshot.log "snapshot refused or failed"; return 1; }
  cp "$ARTIFACT_DIR/targets/$ALIAS/snapshot.tsv" "$D/snapshot-before.tsv"
  t config >"$D/config.tsv" 2>"$D/config.err" || { record BL-CONFIG fail config.err "config failed"; return 1; }
  PROXY_C="$(kv proxy_component "$D/config.tsv")"
  proxy="${PROXY_C#tor-}"
  pihole="$(kv pihole_variant "$D/config.tsv")"
  images="$(awk -F '\t' '$1 == "image" { printf "%s%s=%s", (n++ ? "," : ""), $2, $4 }' "$D/config.tsv")"
  src="$(GIT_OPTIONAL_LOCKS=0 git -C "$BL_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  n="$(awk -F '\t' '$1 == "image" && $4 ~ /^sha256:[0-9a-f]{64}$/' "$D/config.tsv" | grep -c .)"
  if [ -z "$PROXY_C" ] || [ "$n" -ne 3 ] || { [ "$pihole" != standard ] && [ "$pihole" != hardened ]; } \
      || ! grep -q '^unbound_conf	' "$D/config.tsv" || ! grep -q '^pihole_upstream	' "$D/config.tsv"; then
    record BL-CONFIG fail config.tsv "incomplete: proxy='$PROXY_C' pihole='$pihole' image digests=$n of 3"
    return 1
  fi
  {
    printf 'target_id\t%s\nplatform\t%s\nproxy\t%s\npihole\t%s\n' "$ALIAS" "$PLATFORM" "$proxy" "$pihole"
    printf 'source_rev\t%s\nimages\t%s\n' "$src" "$images"
  } >"$D/identity.tsv"
  printf 'cell\t%s/%s/%s\ntarget\t%s\nimage_gen\t%s\n' "$PLATFORM" "$proxy" "$pihole" "$ALIAS" "$images" >"$D/cell.tsv"
  record BL-CONFIG pass config.tsv "$PLATFORM/$proxy/$pihole images=$images"

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

case "${1:-}" in
  characterize) shift; cmd_characterize "$@" ;;
  receipt) shift; cmd_receipt "$@" ;;
  *) die "usage: baseline.sh characterize ALIAS --targets FILE | receipt --out DIR CELLDIR..." ;;
esac
