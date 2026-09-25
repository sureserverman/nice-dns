#!/usr/bin/env bash
# nice-dns test runner (sub-plan 01, Task 1.1; ARCH-01 tests/ tree).
#
# Usage:
#   bash tests/run.sh --list
#   bash tests/run.sh <unit|integration|live> <group> [options]
#   bash tests/run.sh stage <name> [options]
#   bash tests/run.sh plan <name> [options]        rows of plans.tsv (plan-scope)
#   bash tests/run.sh receipt <name> [options]     verify the newest <name> receipt
#   bash tests/run.sh check-matrix <matrix.tsv>
#   bash tests/run.sh check-contracts <workflow.md>
#   bash tests/run.sh check-scenarios              (also run before every stage)
#   bash tests/run.sh new-run <command words...>   (internal: prints a new run dir)
#
# Options: --include-slow --live --fresh-fixtures --reuse-verified-soak
#          --targets F --platforms V --variants V --proxies V --pihole V
#          --entrypoints V --matrix V --hours V --comparison V --images V
#          --require-{matrix,baseline,proxies,transport,platforms,controller,
#                     entrypoints,chain} V
#   Each is exported to cases as NICE_DNS_OPT_<NAME> (e.g. NICE_DNS_OPT_TARGETS).
#
# Exit status: 0 all collected cases passed (and at least one was collected);
#   1 a case failed, zero cases were collected, or --list found a problem;
#   2 usage or registry error (unknown kind/group/stage/option, missing file);
#   3 NOT RUN: tier gate refused (slow needs --include-slow; live needs
#     --live and --targets FILE).
#
# Environment:
#   NICE_DNS_TEST_MANIFESTS  manifest dir (default tests/manifests)
#   NICE_DNS_TEST_ARTIFACTS  artifact root (default
#                            ${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns-tests);
#                            must be outside the checkout.
#
# Portability: Bash 3.2 (macOS /bin/bash). Manifests are TSV data read with
# `while IFS=$'\t' read`; they are never sourced or evaluated. Group files are
# code: they are sourced (in subshells) to collect and run t_* functions.
#
# Runner-internal functions never start with t_, so collection with
# `compgen -A function t_` only sees the group's cases.

set -u
umask 077

# Functions exported by the caller's shell (export -f) would be collected as
# cases (t_*) or shadow the tools the runner calls (awk, grep, ...): the
# runner starts with none.
for _nd_f in $(compgen -A function); do unset -f "$_nd_f"; done
unset _nd_f

ND_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ND_ROOT_LOGICAL="$(cd "$(dirname "$0")/.." && pwd)"
ND_SELF="$ND_ROOT/tests/run.sh"
ND_MANIFESTS="${NICE_DNS_TEST_MANIFESTS:-$ND_ROOT/tests/manifests}"
ND_TAB="$(printf '\t')"
# Exported to cases: the checkout root and this runner.
NICE_DNS_ROOT="$ND_ROOT" NICE_DNS_RUNNER="$ND_SELF"
export NICE_DNS_ROOT NICE_DNS_RUNNER

ND_OK=0 ND_FAIL=1 ND_USAGE=2 ND_NOTRUN=3

nd_err() { printf 'run.sh: %s\n' "$*" >&2; }

# Guard against a case recursing into the runner without bound.
NICE_DNS_TEST_DEPTH=$(( ${NICE_DNS_TEST_DEPTH:-0} + 1 ))
export NICE_DNS_TEST_DEPTH
if [ "$NICE_DNS_TEST_DEPTH" -gt 3 ]; then
  nd_err "runner nesting depth $NICE_DNS_TEST_DEPTH exceeds 3; refusing"
  exit "$ND_USAGE"
fi

# Options from an outer run must not leak into this one's gates or cases.
for _v in $(compgen -v NICE_DNS_OPT_ 2>/dev/null); do unset "$_v"; done
unset _v NICE_DNS_CASE_ASSERTS

# ─────────────────────────── assertion helpers (visible to cases) ────────────
# Each helper records that an assertion ran; a case that asserts nothing fails.
# A failed assertion exits the case subshell with status 1.

_nd_tick() {
  if [ -n "${NICE_DNS_CASE_ASSERTS:-}" ]; then printf '.' >>"$NICE_DNS_CASE_ASSERTS"; fi
  return 0
}
_nd_afail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; exit 1; }

fail() { _nd_tick; _nd_afail "$*"; }
assert_eq() {
  _nd_tick
  [ "$1" = "$2" ] || _nd_afail "${3:-assert_eq}: expected [$1] got [$2]"
}
assert_ne() {
  _nd_tick
  [ "$1" != "$2" ] || _nd_afail "${3:-assert_ne}: both are [$1]"
}
assert_rc() {
  _nd_tick
  [ "$1" = "$2" ] || _nd_afail "${3:-assert_rc}: expected exit $1 got $2"
}
assert_nonzero() {
  _nd_tick
  [ "$1" != 0 ] || _nd_afail "${2:-assert_nonzero}: expected a non-zero exit"
}
assert_match() {
  _nd_tick
  printf '%s\n' "$2" | grep -Eq -- "$1" \
    || _nd_afail "${3:-assert_match}: /$1/ not found in:
$2"
}
assert_not_match() {
  _nd_tick
  if printf '%s\n' "$2" | grep -Eq -- "$1"; then
    _nd_afail "${3:-assert_not_match}: /$1/ unexpectedly found in:
$2"
  fi
}
assert_file() {
  _nd_tick
  [ -f "$1" ] || _nd_afail "${2:-assert_file}: no regular file $1"
}
assert_no_path() {
  _nd_tick
  if [ -e "$1" ] || [ -L "$1" ]; then _nd_afail "${2:-assert_no_path}: path exists $1"; fi
}

# ─────────────────────────── registry ────────────────────────────────────────

ND_G_KIND=() ND_G_NAME=() ND_G_FILE=() ND_G_TIER=()
ND_G_N=0

nd_resolve_file() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$ND_ROOT" "$1" ;;
  esac
}

nd_load_groups() {
  local reg="$ND_MANIFESTS/groups.tsv" k g f t extra ln=0 i
  [ -f "$reg" ] || { nd_err "group registry not found: $reg"; return "$ND_USAGE"; }
  while IFS="$ND_TAB" read -r k g f t extra || [ -n "${k:-}" ]; do
    ln=$((ln + 1))
    case "$k" in ''|'#'*) continue ;; esac
    if [ -z "$g" ] || [ -z "$f" ] || [ -z "$t" ] || [ -n "${extra:-}" ]; then
      nd_err "groups.tsv:$ln: expected 4 tab-separated fields (kind group file tier)"
      return "$ND_USAGE"
    fi
    case "$k" in unit|integration|live) ;; *)
      nd_err "groups.tsv:$ln: unknown kind '$k'"; return "$ND_USAGE" ;;
    esac
    case "$t" in local|slow|live) ;; *)
      nd_err "groups.tsv:$ln: unknown tier '$t'"; return "$ND_USAGE" ;;
    esac
    if [ "$k" = live ] && [ "$t" != live ]; then
      nd_err "groups.tsv:$ln: kind live must use tier live (got '$t')"; return "$ND_USAGE"
    fi
    case "$g" in *[!a-z0-9-]*|-*) nd_err "groups.tsv:$ln: bad group name '$g'"; return "$ND_USAGE" ;; esac
    # Group files are compared as whole records later; a path carrying a
    # record delimiter, an escape or a carriage return is refused.
    # shellcheck disable=SC1003  # a literal backslash pattern, not an escape
    case "$f" in *'|'*|*'='*|*'\'*|*"$(printf '\r')"*)
      nd_err "groups.tsv:$ln: group file path '$f' contains |, =, \\ or a carriage return"; return "$ND_USAGE" ;;
    esac
    i=0
    while [ "$i" -lt "$ND_G_N" ]; do
      if [ "${ND_G_KIND[$i]}" = "$k" ] && [ "${ND_G_NAME[$i]}" = "$g" ]; then
        nd_err "groups.tsv:$ln: duplicate group $k/$g"; return "$ND_USAGE"
      fi
      i=$((i + 1))
    done
    ND_G_KIND[$ND_G_N]="$k"; ND_G_NAME[$ND_G_N]="$g"
    ND_G_FILE[$ND_G_N]="$(nd_resolve_file "$f")"; ND_G_TIER[$ND_G_N]="$t"
    ND_G_N=$((ND_G_N + 1))
  done <"$reg"
  return 0
}

# nd_find_group <kind> <group>: prints the registry index, or nothing.
nd_find_group() {
  local i=0
  while [ "$i" -lt "$ND_G_N" ]; do
    if [ "${ND_G_KIND[$i]}" = "$1" ] && [ "${ND_G_NAME[$i]}" = "$2" ]; then
      printf '%s\n' "$i"; return 0
    fi
    i=$((i + 1))
  done
  return 1
}

nd_known_groups() {
  local i=0 out=""
  while [ "$i" -lt "$ND_G_N" ]; do
    [ "${ND_G_KIND[$i]}" = "$1" ] && out="$out ${ND_G_NAME[$i]}"
    i=$((i + 1))
  done
  printf '%s\n' "${out:- (none)}"
}

# nd_collect <file>: print sorted t_* case names; exit 97 if sourcing failed.
nd_collect() {
  (
    # shellcheck disable=SC1090
    . "$1" >/dev/null 2>&1 || exit 97
    compgen -A function t_ | LC_ALL=C sort
  )
}

# ─────────────────────────── options ─────────────────────────────────────────

ND_OPT_INCLUDE_SLOW=0 ND_OPT_LIVE=0 ND_OPT_TARGETS=""

nd_opt_name() { printf '%s\n' "${1#--}" | tr 'a-z-' 'A-Z_'; }

nd_parse_opts() {
  local name
  while [ $# -gt 0 ]; do
    case "$1" in
      --include-slow|--live|--fresh-fixtures|--reuse-verified-soak)
        name="$(nd_opt_name "$1")"
        printf -v "NICE_DNS_OPT_$name" '%s' 1
        export "NICE_DNS_OPT_$name"
        shift ;;
      --targets|--platforms|--variants|--proxies|--pihole|--entrypoints|\
      --matrix|--hours|--comparison|--images|\
      --require-matrix|--require-baseline|--require-proxies|--require-transport|\
      --require-platforms|--require-controller|--require-entrypoints|--require-chain)
        if [ $# -lt 2 ] || [ -z "$2" ]; then nd_err "option $1 needs a value"; return "$ND_USAGE"; fi
        case "$2" in --*) nd_err "option $1 needs a value, got '$2'"; return "$ND_USAGE" ;; esac
        name="$(nd_opt_name "$1")"
        printf -v "NICE_DNS_OPT_$name" '%s' "$2"
        # Cases run in their own case dir: a file path must not depend on
        # the caller's cwd.
        if [ "$1" = --targets ]; then
          case "$2" in /*) ;; *) printf -v "NICE_DNS_OPT_$name" '%s/%s' "$PWD" "$2" ;; esac
        fi
        export "NICE_DNS_OPT_$name"
        shift 2 ;;
      *) nd_err "unknown option '$1'"; return "$ND_USAGE" ;;
    esac
  done
  ND_OPT_INCLUDE_SLOW="${NICE_DNS_OPT_INCLUDE_SLOW:-0}"
  ND_OPT_LIVE="${NICE_DNS_OPT_LIVE:-0}"
  ND_OPT_TARGETS="${NICE_DNS_OPT_TARGETS:-}"
  return 0
}

# nd_tier_gate <index>: 0 if the tier may run under the parsed options.
nd_tier_gate() {
  local i="$1" id="${ND_G_KIND[$1]}/${ND_G_NAME[$1]}"
  case "${ND_G_TIER[$i]}" in
    local) return 0 ;;
    slow)
      if [ "$ND_OPT_INCLUDE_SLOW" = 1 ]; then return 0; fi
      printf 'NOT RUN: %s is tier slow; pass --include-slow to run it. Nothing was executed; this is not a pass.\n' "$id"
      return "$ND_NOTRUN" ;;
    live)
      if [ "$ND_OPT_LIVE" != 1 ]; then
        printf 'NOT RUN: %s is tier live; pass --live --targets FILE to run it. Nothing was executed; this is not a pass.\n' "$id"
        return "$ND_NOTRUN"
      fi
      if [ -z "$ND_OPT_TARGETS" ] || [ ! -f "$ND_OPT_TARGETS" ]; then
        printf 'NOT RUN: %s needs --targets FILE (an existing target file); got "%s". Nothing was executed; this is not a pass.\n' "$id" "$ND_OPT_TARGETS"
        return "$ND_NOTRUN"
      fi
      return 0 ;;
  esac
  return "$ND_USAGE"
}

# ─────────────────────────── run identity and artifacts ──────────────────────

RUN_ID="" ARTIFACT_DIR=""

nd_rand_hex8() {
  local h=""
  if [ -r /dev/urandom ]; then
    h="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  case "$h" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) printf -v h '%04x%04x' "$RANDOM" "$RANDOM" ;;
  esac
  printf '%s\n' "$h"
}

nd_inside_checkout() {
  case "$1/" in
    "$ND_ROOT"/*|"$ND_ROOT_LOGICAL"/*) return 0 ;;
  esac
  return 1
}

# nd_new_run <command words...>: create a run dir and receipt; sets RUN_ID
# and ARTIFACT_DIR. The receipt lets rollback remove only test-created dirs.
nd_new_run() {
  local root phys try=0 head dirty cmd a
  root="${NICE_DNS_TEST_ARTIFACTS:-${XDG_STATE_HOME:-${HOME:?HOME is unset}/.local/state}/nice-dns-tests}"
  while :; do case "$root" in */) root="${root%/}" ;; *) break ;; esac; done
  case "$root" in
    /*) ;;
    *) nd_err "artifact root must be an absolute path: '$root'"; return "$ND_USAGE" ;;
  esac
  case "$root/" in
    */../*|*/./*) nd_err "artifact root must not contain . or .. components: '$root'"; return "$ND_USAGE" ;;
  esac
  if nd_inside_checkout "$root"; then
    nd_err "artifact root '$root' is inside the checkout $ND_ROOT; refusing (tests write outside the repository)"
    return "$ND_USAGE"
  fi
  mkdir -p "$root/runs" || { nd_err "cannot create $root/runs"; return "$ND_USAGE"; }
  phys="$(cd "$root/runs" && pwd -P)"
  if nd_inside_checkout "$phys"; then
    nd_err "artifact root '$root' resolves inside the checkout ($phys); refusing"
    return "$ND_USAGE"
  fi
  while :; do
    try=$((try + 1))
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(nd_rand_hex8)"
    if mkdir "$root/runs/$RUN_ID" 2>/dev/null; then break; fi
    if [ "$try" -ge 20 ]; then nd_err "could not allocate a unique run id under $root/runs"; return "$ND_USAGE"; fi
  done
  ARTIFACT_DIR="$root/runs/$RUN_ID"
  head="$(GIT_OPTIONAL_LOCKS=0 git -C "$ND_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [ -n "$(GIT_OPTIONAL_LOCKS=0 git -C "$ND_ROOT" status --porcelain 2>/dev/null)" ]; then dirty=yes; else dirty=no; fi
  cmd=""
  for a in "$@"; do cmd="$cmd$(printf '%q' "$a") "; done
  {
    printf 'schema\tnice-dns-test-run/1\n'
    printf 'run_id\t%s\n' "$RUN_ID"
    printf 'created_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'git_head\t%s\n' "$head"
    printf 'git_dirty\t%s\n' "$dirty"
    printf 'checkout\t%s\n' "$ND_ROOT"
    printf 'artifact_dir\t%s\n' "$ARTIFACT_DIR"
    printf 'created_by\ttests/run.sh\n'
    printf 'command\t%s\n' "${cmd% }"
    # A run against altered manifests must not read like a real one.
    printf 'manifests\t%s\n' "$ND_MANIFESTS"
    if [ -n "${NICE_DNS_TEST_MANIFESTS:-}" ]; then printf 'manifests_override\tyes\n'; else printf 'manifests_override\tno\n'; fi
  } >"$ARTIFACT_DIR/receipt.tsv"
  export RUN_ID ARTIFACT_DIR
  return 0
}

# ─────────────────────────── execution ───────────────────────────────────────

ND_TOT_N=0 ND_TOT_P=0 ND_TOT_F=0

# nd_run_case <file> <case> <case_dir>: 0 pass, 1 fail. Each case runs in its
# own subshell with cwd and TMPDIR inside its case dir.
nd_run_case() {
  local file="$1" c="$2" cdir="$3" log rc asserts
  log="$cdir/case.log"
  mkdir -p "$cdir/tmp"
  (
    CASE_DIR="$cdir"; NICE_DNS_CASE_ASSERTS="$cdir/.asserts"; TMPDIR="$cdir/tmp"
    export CASE_DIR NICE_DNS_CASE_ASSERTS TMPDIR
    cd "$cdir" || exit 98
    # shellcheck disable=SC1090
    . "$file" || { printf 'group file failed to source\n' >&2; exit 98; }
    "$c"
  ) >"$log" 2>&1 </dev/null
  rc=$?
  asserts=0
  if [ -f "$cdir/.asserts" ]; then asserts="$(wc -c <"$cdir/.asserts" | tr -d ' ')"; fi
  if [ "$rc" -eq 0 ] && [ "$asserts" -eq 0 ]; then
    printf 'FAIL  %s (no assertions: a case that checks nothing is not green)\n' "$c"
    return 1
  fi
  if [ "$rc" -eq 0 ]; then
    printf 'PASS  %s\n' "$c"
    return 0
  fi
  printf 'FAIL  %s (exit %s; log %s)\n' "$c" "$rc" "$log"
  tail -n 20 "$log" | sed 's/^/      /'
  return 1
}

# nd_run_group_index <index>: runs every case; updates totals; 0 only if the
# group collected >0 cases and none failed.
nd_run_group_index() {
  local i="$1" kind="${ND_G_KIND[$1]}" group="${ND_G_NAME[$1]}" file="${ND_G_FILE[$1]}"
  local cases rc c n=0 p=0 f=0
  cases="$(nd_collect "$file")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL  %s/%s: group file did not source cleanly (%s)\n' "$kind" "$group" "$file"
    printf 'group %s/%s: collected=0 passed=0 failed=0\n' "$kind" "$group"
    return 1
  fi
  for c in $cases; do
    n=$((n + 1))
    if nd_run_case "$file" "$c" "$ARTIFACT_DIR/cases/$kind-$group/$c"; then
      p=$((p + 1)); printf '%s/%s\t%s\t%s\tpass\n' "$kind" "$group" "$file" "$c" >>"$ARTIFACT_DIR/results.tsv"
    else
      f=$((f + 1)); printf '%s/%s\t%s\t%s\tfail\n' "$kind" "$group" "$file" "$c" >>"$ARTIFACT_DIR/results.tsv"
    fi
  done
  ND_TOT_N=$((ND_TOT_N + n)); ND_TOT_P=$((ND_TOT_P + p)); ND_TOT_F=$((ND_TOT_F + f))
  if [ "$n" -eq 0 ]; then
    printf 'FAIL  %s/%s collected 0 cases; an empty group is never green\n' "$kind" "$group"
  fi
  printf 'group %s/%s: collected=%s passed=%s failed=%s\n' "$kind" "$group" "$n" "$p" "$f"
  [ "$n" -gt 0 ] && [ "$f" -eq 0 ]
}

nd_finish() {
  local ok="$1" status rc
  if [ "$ok" -eq 0 ] && [ "$ND_TOT_N" -gt 0 ] && [ "$ND_TOT_F" -eq 0 ]; then status=pass; rc="$ND_OK"; else status=fail; rc="$ND_FAIL"; fi
  printf 'collected=%s passed=%s failed=%s\n' "$ND_TOT_N" "$ND_TOT_P" "$ND_TOT_F"
  printf 'result=%s run_id=%s artifacts=%s\n' "$status" "$RUN_ID" "$ARTIFACT_DIR"
  {
    printf 'status\t%s\n' "$status"
    printf 'collected\t%s\npassed\t%s\nfailed\t%s\n' "$ND_TOT_N" "$ND_TOT_P" "$ND_TOT_F"
    printf 'finished_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'elapsed_seconds\t%s\n' "$SECONDS"
    printf 'exit\t%s\n' "$rc"
  } >"$ARTIFACT_DIR/result.tsv"
  return "$rc"
}

nd_prepare_group() {
  # nd_prepare_group <kind> <group>: prints index; validates registration/file.
  local idx
  idx="$(nd_find_group "$1" "$2")" || {
    nd_err "unknown group '$2' for kind '$1' (registered $1 groups:$(nd_known_groups "$1"))"
    return "$ND_USAGE"
  }
  if [ ! -f "${ND_G_FILE[$idx]}" ]; then
    nd_err "group $1/$2 is registered but its file is missing: ${ND_G_FILE[$idx]}"
    return "$ND_USAGE"
  fi
  printf '%s\n' "$idx"
}

cmd_group() {
  local kind="$1" group="$2" idx rc
  shift 2
  nd_load_groups || return $?
  nd_parse_opts "$@" || return $?
  idx="$(nd_prepare_group "$kind" "$group")" || return $?
  nd_tier_gate "$idx"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  nd_new_run tests/run.sh "$kind" "$group" "$@" || return $?
  printf 'run_id=%s artifacts=%s\n' "$RUN_ID" "$ARTIFACT_DIR"
  nd_run_group_index "$idx"; rc=$?
  nd_finish "$rc"
}

cmd_stage() { nd_composite stage stages.tsv "$@"; }
cmd_plan() { nd_composite plan plans.tsv "$@"; }

# nd_composite <stage|plan> <manifest> <name> [options]: run every group the
# manifest lists for <name>, in order, as one run.
nd_composite() {
  local what="$1" mf="$2" name="$3" s k g extra ln=0 idx idxs="" seen="" rc worst=0 i
  shift 3
  nd_load_groups || return $?
  nd_parse_opts "$@" || return $?
  [ -f "$ND_MANIFESTS/$mf" ] || { nd_err "$what list not found: $ND_MANIFESTS/$mf"; return "$ND_USAGE"; }
  while IFS="$ND_TAB" read -r s k g extra || [ -n "${s:-}" ]; do
    ln=$((ln + 1))
    case "$s" in ''|'#'*) continue ;; esac
    [ "$s" = "$name" ] || continue
    if [ -z "$k" ] || [ -z "$g" ] || [ -n "${extra:-}" ]; then
      nd_err "$mf:$ln: expected 3 tab-separated fields ($what kind group)"; return "$ND_USAGE"
    fi
    case "$seen" in *"|$k/$g|"*) nd_err "$mf:$ln: $k/$g listed twice in $what '$name'"; return "$ND_USAGE" ;; esac
    seen="$seen|$k/$g|"
    idx="$(nd_prepare_group "$k" "$g")" || { nd_err "$what '$name' ($mf:$ln) names unregistered or unusable group $k/$g"; return "$ND_USAGE"; }
    idxs="$idxs $idx"
  done <"$ND_MANIFESTS/$mf"
  if [ -z "$idxs" ]; then
    nd_err "unknown $what '$name' (it resolves to zero groups in $mf)"
    return "$ND_USAGE"
  fi
  # Refuse the whole run before running anything if scenario coverage is
  # incomplete, the stage's required scenarios are not all in it, or any tier
  # gate refuses.
  if ! cmd_check_scenarios >/dev/null; then
    nd_err "$what '$name' refused: scenario coverage is incomplete (bash tests/run.sh check-scenarios)"
    return "$ND_FAIL"
  fi
  local grouplist=""
  for i in $idxs; do grouplist="$grouplist${ND_G_KIND[$i]}/${ND_G_NAME[$i]}$ND_TAB${ND_G_FILE[$i]}
"; done
  if ! nd_stage_requirements "$what:$name" "$grouplist"; then
    nd_err "$what '$name' refused: its required scenarios are not all active in it (tests/manifests/stage-scenarios.tsv)"
    return "$ND_FAIL"
  fi
  for i in $idxs; do
    nd_tier_gate "$i"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
  done
  nd_new_run tests/run.sh "$what" "$name" "$@" || return $?
  for i in $idxs; do
    printf 'group\t%s/%s\t%s\n' "${ND_G_KIND[$i]}" "${ND_G_NAME[$i]}" "${ND_G_FILE[$i]}" >>"$ARTIFACT_DIR/receipt.tsv"
  done
  printf 'run_id=%s artifacts=%s %s=%s\n' "$RUN_ID" "$ARTIFACT_DIR" "$what" "$name"
  : >"$ARTIFACT_DIR/results.tsv"
  for i in $idxs; do
    printf '== %s/%s ==\n' "${ND_G_KIND[$i]}" "${ND_G_NAME[$i]}"
    nd_run_group_index "$i" || worst=1
  done
  if ! nd_required_results "$what:$name"; then
    printf 'FAIL  %s %s: a required case did not run and pass (see run.sh: lines above)\n' "$what" "$name"
    worst=1
  fi
  nd_finish "$worst"
}

# nd_stage_requirements <stage:NAME|plan:NAME> <|kind/group=file|...|>: rows
# of stage-scenarios.tsv (tab-separated, parsed as data) for this stage or plan:
#   require <NAME> <id> <kind> <group> <case> <file>
#       the proof's whole identity: scenarios.tsv has row <id>, active, proven
#       by exactly <kind>/<group> <case>; that group runs here and is
#       registered with exactly <file> (a checkout-relative path is resolved
#       against the checkout).
#   count   <NAME> <n>      exactly n require rows exist for NAME.
#   owner   <NAME> <owner>  every scenario row of that owner is active and
#                           runs here.
# The list is complete: every active scenario whose group runs here must be
# required here, and a NAME with require rows must have its count row. So a
# deleted, re-pointed, re-grouped, deferred or re-filed proof, a dropped
# group, a duplicate or malformed row, or an emptied, deleted or re-keyed
# manifest refuses the run. Retiring a mandatory proof takes an explicit edit
# of its require row and the count. What no manifest can see is a case whose
# body was gutted; the per-task mutation proofs cover that. A missing
# manifest refuses every stage and plan. Prints each problem; 1 if any.
nd_stage_requirements() {
  local f="$ND_MANIFESTS/stage-scenarios.tsv" errs
  if [ ! -f "$f" ]; then
    nd_err "required manifest missing: $f (every stage and plan checks its scenario requirements)"
    return 1
  fi
  # Inputs reach awk through ENVIRON and stdin, never -v (which decodes
  # backslash escapes) or file operands that could read as assignments.
  # Group records arrive on stdin as "kind/group<TAB>file" and are matched
  # whole, never as substrings.
  errs="$(printf '%s' "$2" | ND_AWK_NAME="$1" ND_AWK_ROOT="$ND_ROOT" ND_AWK_SC="$ND_MANIFESTS/scenarios.tsv" \
    ND_AWK_REQ="$f" awk -F '\t' '
    function malformed(line) {
      return line ~ /\r/ || line ~ /^[ \t]+[^ \t]/
    }
    BEGIN {
      st = ENVIRON["ND_AWK_NAME"]; root = ENVIRON["ND_AWK_ROOT"]
      scf = ENVIRON["ND_AWK_SC"]; reqf = ENVIRON["ND_AWK_REQ"]
      while ((getline line < "-") > 0) { split(line, g, "\t"); gfile[g[1]] = g[2] }
      while ((getline line < scf) > 0) {
        # Malformed scenarios.tsv lines are refused earlier by check-scenarios.
        split(line, r, "\t")
        if (r[1] == "" || r[1] ~ /^#/) continue
        kind[r[1]] = r[3]; grp[r[1]] = r[4]; cas[r[1]] = r[5]; own[r[1]] = r[6]; ids[++n] = r[1]
      }
      ln = 0
      while ((getline line < reqf) > 0) {
        ln++
        if (malformed(line)) { print "stage-scenarios.tsv:" ln ": malformed line (carriage return or leading whitespace)"; continue }
        nf = split(line, f, "\t")
        if (f[1] == "" || f[1] ~ /^#/) continue
        if (f[1] == "require" && nf != 7) { print "stage-scenarios.tsv:" ln ": require rows have 7 tab-separated fields (require NAME ID KIND GROUP CASE FILE)"; continue }
        if ((f[1] == "owner" || f[1] == "count") && nf != 3) { print "stage-scenarios.tsv:" ln ": " f[1] " rows have 3 tab-separated fields"; continue }
        if (f[1] != "require" && f[1] != "owner" && f[1] != "count") { print "stage-scenarios.tsv:" ln ": unknown row type \"" f[1] "\""; continue }
        if (f[2] != st) continue
        if (f[1] == "count") { if (counted) print "stage-scenarios.tsv:" ln ": second count row for " st; counted = 1; want = f[3]; continue }
        if (f[1] == "owner") {
          for (i = 1; i <= n; i++) {
            id = ids[i]
            if (own[id] != f[3]) continue
            if (kind[id] == "-") print "scenario " id " (owner " f[3] ") is still deferred"
            else if (!((kind[id] "/" grp[id]) in gfile))
              print "scenario " id " (owner " f[3] ") runs in " kind[id] "/" grp[id] ", which " st " does not run"
          }
          continue
        }
        id = f[3]; nreq++
        if (id in req) { print "stage-scenarios.tsv:" ln ": " id " is required twice in " st; continue }
        req[id] = 1
        if (!(id in kind)) { print "required scenario " id " has no row in scenarios.tsv"; continue }
        if (kind[id] == "-") { print "required scenario " id " is deferred, not active"; continue }
        if (kind[id] != f[4] || grp[id] != f[5] || cas[id] != f[6]) {
          print "required scenario " id " must be proven by " f[4] "/" f[5] " " f[6] ", but scenarios.tsv names " kind[id] "/" grp[id] " " cas[id]; continue
        }
        key = f[4] "/" f[5]
        if (!(key in gfile)) { print "required scenario " id " runs in " key ", which " st " does not run"; continue }
        pin = f[7]; if (pin !~ /^\//) pin = root "/" pin
        if (gfile[key] != pin) print "required scenario " id ": group " key " is registered with " gfile[key] ", not the pinned " pin
      }
      for (i = 1; i <= n; i++) {
        id = ids[i]
        if (kind[id] == "-" || (id in req)) continue
        if ((kind[id] "/" grp[id]) in gfile)
          print "scenario " id " runs in " st " (" kind[id] "/" grp[id] ") but is not required there"
      }
      if (nreq > 0 && !counted) print "stage-scenarios.tsv has require rows for " st " but no count row"
      if (counted && want != nreq) print st " has " nreq " require rows, but its count row says " want
    }')"
  [ -z "$errs" ] && return 0
  printf '%s\n' "$errs" | sed 's/^/run.sh: /' >&2
  return 1
}

# nd_required_results <stage:NAME|plan:NAME>: after the run, every require row
# of NAME must have a "pass" result in $ARTIFACT_DIR/results.tsv from exactly
# its kind/group, case and pinned file. The manifests say what must run; this
# says what did. Prints each gap; 1 if any.
nd_required_results() {
  local errs
  errs="$(ND_AWK_NAME="$1" ND_AWK_ROOT="$ND_ROOT" ND_AWK_RES="$ARTIFACT_DIR/results.tsv" \
    ND_AWK_REQ="$ND_MANIFESTS/stage-scenarios.tsv" awk -F '\t' '
    BEGIN {
      st = ENVIRON["ND_AWK_NAME"]; root = ENVIRON["ND_AWK_ROOT"]
      while ((getline line < ENVIRON["ND_AWK_RES"]) > 0) {
        split(line, r, "\t"); status[r[1] "\t" r[2] "\t" r[3]] = r[4]
      }
      while ((getline line < ENVIRON["ND_AWK_REQ"]) > 0) {
        n = split(line, f, "\t")
        if (f[1] != "require" || f[2] != st || n != 7) continue
        pin = f[7]; if (pin !~ /^\//) pin = root "/" pin
        k = f[4] "/" f[5] "\t" pin "\t" f[6]
        if (!(k in status)) print "required case " f[4] "/" f[5] " " f[6] " (" f[3] ") did not run from " pin
        else if (status[k] != "pass") print "required case " f[4] "/" f[5] " " f[6] " (" f[3] ") did not pass"
      }
    }')"
  [ -z "$errs" ] && return 0
  printf '%s\n' "$errs" | sed 's/^/run.sh: /' >&2
  return 1
}

cmd_list() {
  local i=0 cases rc n status bad=0 s k g extra ln=0
  nd_load_groups || return $?
  printf '%-12s %-28s %-6s %-9s %-8s %s\n' KIND GROUP TIER CASES STATUS FILE
  while [ "$i" -lt "$ND_G_N" ]; do
    n=0
    if [ ! -f "${ND_G_FILE[$i]}" ]; then
      status=MISSING; bad=1
    else
      cases="$(nd_collect "${ND_G_FILE[$i]}")"; rc=$?
      if [ "$rc" -ne 0 ]; then
        status=ERROR; bad=1
      else
        for _c in $cases; do n=$((n + 1)); done
        if [ "$n" -eq 0 ]; then status=EMPTY; bad=1; else status=OK; fi
      fi
    fi
    printf '%-12s %-28s %-6s cases=%-3s %-8s %s\n' "${ND_G_KIND[$i]}" "${ND_G_NAME[$i]}" "${ND_G_TIER[$i]}" "$n" "$status" "${ND_G_FILE[$i]}"
    i=$((i + 1))
  done
  if [ "$ND_G_N" -eq 0 ]; then printf '(no groups registered)\n'; bad=1; fi
  if [ -f "$ND_MANIFESTS/stages.tsv" ]; then
    printf '\nSTAGE ROWS\n'
    while IFS="$ND_TAB" read -r s k g extra || [ -n "${s:-}" ]; do
      ln=$((ln + 1))
      case "$s" in ''|'#'*) continue ;; esac
      if [ -z "$k" ] || [ -z "$g" ] || [ -n "${extra:-}" ]; then
        printf 'stages.tsv:%s MALFORMED\n' "$ln"; bad=1; continue
      fi
      if nd_find_group "$k" "$g" >/dev/null; then
        printf '%-22s %s/%s\n' "$s" "$k" "$g"
      else
        printf '%-22s %s/%s UNREGISTERED\n' "$s" "$k" "$g"; bad=1
      fi
    done <"$ND_MANIFESTS/stages.tsv"
  else
    printf 'stages.tsv MISSING\n'; bad=1
  fi
  [ "$bad" -eq 0 ] || { nd_err "--list found missing, empty or unregistered entries"; return "$ND_FAIL"; }
  return "$ND_OK"
}

# cmd_receipt <name> [--require-* ...]: verify the newest receipt of <name>
# under <artifact root>/receipts/<name>/<run-id>/receipt.tsv with
# tests/reports/verify.sh. No receipt is a failure, never a pass.
cmd_receipt() {
  local name="${1:-}" root dir latest a
  set -- "${@:2}"
  case "$name" in ''|--*) nd_err "usage: run.sh receipt <name> [--require-* ...]"; return "$ND_USAGE" ;; esac
  local vargs=()
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || { nd_err "option $1 needs a value"; return "$ND_USAGE"; }
    case "$1" in
      --require-matrix|--require-platforms|--require-proxies|--require-entrypoints) vargs+=("$1" "$2") ;;
      --require-baseline|--require-transport|--require-controller|--require-installers) vargs+=(--require-dep "$2") ;;
      --require-chain) for a in $(printf '%s' "$2" | tr ',' ' '); do vargs+=(--require-dep "$a"); done ;;
      *) nd_err "unknown receipt option '$1'"; return "$ND_USAGE" ;;
    esac
    shift 2
  done
  root="${NICE_DNS_TEST_ARTIFACTS:-${XDG_STATE_HOME:-${HOME:?HOME is unset}/.local/state}/nice-dns-tests}"
  dir="$root/receipts/$name"
  latest=""
  if [ -d "$dir" ]; then
    latest="$(for a in "$dir"/*/receipt.tsv; do [ -f "$a" ] && printf '%s\n' "$a"; done | LC_ALL=C sort | tail -1)"
  fi
  if [ -z "$latest" ]; then
    nd_err "no $name receipt under $dir; nothing verified (this is not a pass)"
    return "$ND_FAIL"
  fi
  printf 'receipt: %s\n' "$latest"
  bash "$ND_ROOT/tests/reports/verify.sh" check "$latest" ${vargs[@]+"${vargs[@]}"}
}

# ─────────────────────────── validators ──────────────────────────────────────

cmd_check_matrix() {
  local file="$1" line a b c extra ln=0 seen="" problems="" cell p x y
  [ -f "$file" ] || { nd_err "check-matrix: no such file: $file"; return "$ND_USAGE"; }
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    case "$line" in ''|'#'*) continue ;; esac
    a="" b="" c="" extra=""
    IFS="$ND_TAB" read -r a b c extra <<EOF
$line
EOF
    if [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ] || [ -n "$extra" ]; then
      problems="${problems}line $ln: expected 3 tab-separated fields (platform proxy pihole): '$line'
"
      continue
    fi
    case "$a" in linux|macos) ;; *) problems="${problems}line $ln: unknown platform '$a'
"; continue ;; esac
    case "$b" in haproxy|socat) ;; *) problems="${problems}line $ln: unknown proxy '$b'
"; continue ;; esac
    case "$c" in standard|hardened) ;; *) problems="${problems}line $ln: unknown pihole variant '$c'
"; continue ;; esac
    cell="$a/$b/$c"
    case "$seen" in
      *"|$cell|"*) problems="${problems}line $ln: duplicate cell $cell
" ;;
      *) seen="$seen|$cell|" ;;
    esac
  done <"$file"
  for p in linux macos; do
    for x in haproxy socat; do
      for y in standard hardened; do
        case "$seen" in *"|$p/$x/$y|"*) ;; *) problems="${problems}missing cell $p/$x/$y
" ;; esac
      done
    done
  done
  if [ -n "$problems" ]; then
    printf '%s' "$problems" | sed 's/^/check-matrix: /' >&2
    return "$ND_FAIL"
  fi
  printf 'check-matrix: OK (8 cells: linux|macos x haproxy|socat x standard|hardened) %s\n' "$file"
  return "$ND_OK"
}

# nd_section <doc> <id>: print the "## <id>" section up to the next "## ".
nd_section() {
  awk -v id="$2" '
    /^## / { insec = (index($0, "## " id) == 1) ; if (insec) { print; next } }
    insec { print }' "$1"
}

# nd_has_heading <text> <name>: a ###/#### heading starting with <name>.
nd_has_heading() {
  printf '%s\n' "$1" | awk -v n="$2" '
    match($0, /^####? /) { if (index(substr($0, RLENGTH + 1), n) == 1) f = 1 }
    END { exit(f ? 0 : 1) }'
}

cmd_check_contracts() {
  local doc="$1" ops="$ND_MANIFESTS/privacy-ops.tsv" problems="" id rest cnt sec h tag known
  [ -f "$doc" ] || { nd_err "check-contracts: no such file: $doc"; return "$ND_USAGE"; }
  [ -f "$ops" ] || { nd_err "check-contracts: privacy-ops manifest not found: $ops"; return "$ND_USAGE"; }
  for id in WF-DNS-001 WF-DNS-002 WF-DNS-003 WF-DNS-004; do
    cnt="$(grep -cE "^## $id([^0-9]|\$)" "$doc" || true)"
    if [ "$cnt" -eq 0 ]; then
      problems="${problems}missing workflow $id (no '## $id' heading)
"
      continue
    fi
    if [ "$cnt" -gt 1 ]; then
      problems="${problems}workflow $id is defined $cnt times
"
    fi
    sec="$(nd_section "$doc" "$id")"
    for h in "Trigger" "Contract (target, per ARCH)" "Steps" "Invariants" \
             "Current baseline (observed in source)" "Platform notes"; do
      nd_has_heading "$sec" "$h" || problems="${problems}workflow $id lacks a '$h' subsection
"
    done
    printf '%s\n' "$sec" | grep -Eq '\[(SEC|PRIV|EVD|REC)-[A-Z0-9-]+\]' \
      || problems="${problems}workflow $id tags no privacy/security operation
"
    printf '%s\n' "$sec" | grep -Eq '[A-Za-z0-9_./-]+:[0-9]+' \
      || problems="${problems}workflow $id cites no file:line for its current baseline
"
  done
  known="|"
  while IFS="$ND_TAB" read -r id rest || [ -n "${id:-}" ]; do
    case "$id" in ''|'#'*) continue ;; esac
    known="$known$id|"
    grep -qF "[$id]" "$doc" || problems="${problems}missing mandatory operation [$id]
"
  done <"$ops"
  # Citations are path:line at the doc's pinned "Baseline source" commit: each
  # cited file must exist there, be long enough, and be unchanged since (a
  # changed file means the citations must be re-derived, not read at HEAD).
  local pin cite path line nlines
  pin="$(awk '/Baseline source/ { on = 1 } on { if (match($0, /[0-9a-f]{40}/)) { print substr($0, RSTART, 40); exit } } on && /^- / && !/Baseline source/ { exit }' "$doc")"
  if [ -z "$pin" ] || ! GIT_OPTIONAL_LOCKS=0 git -C "$ND_ROOT" cat-file -e "$pin^{commit}" 2>/dev/null; then
    problems="${problems}no pinned baseline commit (a 40-hex commit on the 'Baseline source' line) known to this checkout
"
  else
    for cite in $(grep -oE '(^|[ (`,])[A-Za-z0-9_][A-Za-z0-9_./-]*:[0-9]+' "$doc" | sed -E 's/^[ (`,]//' | sort -u); do
      path="${cite%:*}" line="${cite##*:}"
      case "$path" in *[!0-9.]*) ;; *) continue ;; esac   # an address such as 127.0.0.1:53
      if ! GIT_OPTIONAL_LOCKS=0 git -C "$ND_ROOT" cat-file -e "$pin:$path" 2>/dev/null; then
        problems="${problems}cited $path is not in the pinned commit ${pin:0:12}
"; continue
      fi
      nlines="$(GIT_OPTIONAL_LOCKS=0 git -C "$ND_ROOT" show "$pin:$path" | wc -l | tr -d ' ')"
      [ "$line" -le "$nlines" ] || problems="${problems}cited $path:$line is past the end of $path ($nlines lines) at ${pin:0:12}
"
    done
    for path in $(grep -oE '(^|[ (`,])[A-Za-z0-9_][A-Za-z0-9_./-]*:[0-9]+' "$doc" | sed -E 's/^[ (`,]//; s/:[0-9]+$//' | sort -u); do
      case "$path" in *[!0-9.]*) ;; *) continue ;; esac
      GIT_OPTIONAL_LOCKS=0 git -C "$ND_ROOT" cat-file -e "$pin:$path" 2>/dev/null || continue
      GIT_OPTIONAL_LOCKS=0 git -C "$ND_ROOT" diff --quiet "$pin" -- "$path" 2>/dev/null \
        || problems="${problems}cited $path changed since the pinned commit ${pin:0:12}; re-derive its citations and re-pin
"
    done
  fi
  for tag in $(grep -oE '\[(SEC|PRIV|EVD|REC)-[A-Z0-9-]+\]' "$doc" | sort -u); do
    id="${tag#[}"; id="${id%]}"
    case "$known" in *"|$id|"*) ;; *) problems="${problems}unknown operation tag $tag (not in privacy-ops.tsv)
" ;; esac
  done
  if [ -n "$problems" ]; then
    printf '%s' "$problems" | sed 's/^/check-contracts: /' >&2
    return "$ND_FAIL"
  fi
  printf 'check-contracts: OK (WF-DNS-001..004 and all operations in %s) %s\n' "$ops" "$doc"
  return "$ND_OK"
}

# ─────────────────────────── dispatch ────────────────────────────────────────

# cmd_check_scenarios: scenario coverage (scenarios.tsv) against the
# mandatory privacy operations (privacy-ops.tsv) and Stage 1 variants
# (variants.tsv). Every operation needs a row; every variant needs an active
# row; an active row must name a registered group and an existing t_* case;
# a deferred row ("-" in kind, group and case) must name a later owner.
cmd_check_scenarios() {
  local sc="$ND_MANIFESTS/scenarios.tsv" opsf="$ND_MANIFESTS/privacy-ops.tsv" varf="$ND_MANIFESTS/variants.tsv"
  local f id cov k g c o extra rest ln=0 errs=0 active=0 deferred=0 idx
  local ids="|" known_ops="|" known_vars="|" covered="|" vcovered="|" owners=""
  for f in "$sc" "$opsf" "$varf"; do
    [ -f "$f" ] || { nd_err "check-scenarios: missing manifest $f"; return "$ND_FAIL"; }
  done
  if [ "$ND_G_N" -eq 0 ]; then nd_load_groups || return $?; fi
  while IFS="$ND_TAB" read -r id rest || [ -n "${id:-}" ]; do
    case "$id" in ''|'#'*) continue ;; esac
    known_ops="$known_ops$id|"
  done <"$opsf"
  while IFS="$ND_TAB" read -r id rest || [ -n "${id:-}" ]; do
    case "$id" in ''|'#'*) continue ;; esac
    known_vars="$known_vars$id|"
  done <"$varf"
  # One rule for both parsers: a carriage return or leading whitespace makes a
  # row malformed (IFS read would strip a leading tab, awk would not).
  if grep -nE "$(printf '\r')|^[[:space:]]+[^[:space:]]" "$sc" >/dev/null 2>&1; then
    nd_err "scenarios.tsv: malformed line(s) (carriage return or leading whitespace): $(grep -nE "$(printf '\r')|^[[:space:]]+[^[:space:]]" "$sc" | cut -d: -f1 | tr '\n' ' ')"
    errs=$((errs + 1))
  fi
  while IFS="$ND_TAB" read -r id cov k g c o extra || [ -n "${id:-}" ]; do
    ln=$((ln + 1))
    case "$id" in ''|'#'*) continue ;; esac
    if [ -z "${cov:-}" ] || [ -z "${k:-}" ] || [ -z "${g:-}" ] || [ -z "${c:-}" ] || [ -z "${o:-}" ] || [ -n "${extra:-}" ]; then
      nd_err "scenarios.tsv:$ln: expected 6 tab-separated fields (scenario covers kind group case owner)"
      errs=$((errs + 1)); continue
    fi
    case "$ids" in *"|$id|"*) nd_err "scenarios.tsv:$ln: duplicate scenario id '$id'"; errs=$((errs + 1)); continue ;; esac
    ids="$ids$id|"
    case "$cov" in
      variant:*)
        case "$known_vars" in *"|${cov#variant:}|"*) ;; *)
          nd_err "scenarios.tsv:$ln: unknown variant '${cov#variant:}' (not in variants.tsv)"; errs=$((errs + 1)); continue ;;
        esac ;;
      *)
        case "$known_ops" in *"|$cov|"*) ;; *)
          nd_err "scenarios.tsv:$ln: unknown operation '$cov' (not in privacy-ops.tsv)"; errs=$((errs + 1)); continue ;;
        esac ;;
    esac
    case "$o" in baseline|transport|controller|installers|qualification) ;; *)
      nd_err "scenarios.tsv:$ln: unknown owner '$o'"; errs=$((errs + 1)); continue ;;
    esac
    if [ "$k" = - ] && [ "$g" = - ] && [ "$c" = - ]; then
      deferred=$((deferred + 1)); owners="$owners $o:$cov"
      case "$cov" in variant:*) ;; *) covered="$covered$cov|" ;; esac
      continue
    fi
    if [ "$k" = - ] || [ "$g" = - ] || [ "$c" = - ]; then
      nd_err "scenarios.tsv:$ln: kind, group and case must all be '-' (deferred) or all be set"; errs=$((errs + 1)); continue
    fi
    idx="$(nd_find_group "$k" "$g")" || { nd_err "scenarios.tsv:$ln: scenario $id names unregistered group $k/$g"; errs=$((errs + 1)); continue; }
    if ! nd_collect "${ND_G_FILE[$idx]}" | grep -qx -- "$c"; then
      nd_err "scenarios.tsv:$ln: scenario $id names case $c, which $k/$g does not define"; errs=$((errs + 1)); continue
    fi
    active=$((active + 1))
    case "$cov" in variant:*) vcovered="$vcovered${cov#variant:}|" ;; *) covered="$covered$cov|" ;; esac
  done <"$sc"
  for id in $(printf '%s' "$known_ops" | tr '|' ' '); do
    case "$covered" in *"|$id|"*) ;; *) nd_err "privacy operation $id has no scenario row (active or deferred to its owner)"; errs=$((errs + 1)) ;; esac
  done
  for id in $(printf '%s' "$known_vars" | tr '|' ' '); do
    case "$vcovered" in *"|$id|"*) ;; *) nd_err "variant $id has no active scenario (a registered case that exercises it)"; errs=$((errs + 1)) ;; esac
  done
  printf 'scenarios: active=%s deferred=%s errors=%s\n' "$active" "$deferred" "$errs"
  for f in $owners; do printf '  deferred %s -> %s\n' "${f#*:}" "${f%%:*}"; done
  [ "$errs" -eq 0 ] || return "$ND_FAIL"
  return "$ND_OK"
}

nd_usage() { sed -n '2,34p' "$ND_SELF" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    --list|list) [ $# -eq 0 ] || { nd_err "--list takes no arguments"; return "$ND_USAGE"; }; cmd_list ;;
    unit|integration|live)
      if [ $# -lt 1 ]; then nd_err "usage: run.sh $cmd <group> [options]"; return "$ND_USAGE"; fi
      case "$1" in --*) nd_err "usage: run.sh $cmd <group> [options]"; return "$ND_USAGE" ;; esac
      cmd_group "$cmd" "$@" ;;
    stage)
      if [ $# -lt 1 ]; then nd_err "usage: run.sh stage <name> [options]"; return "$ND_USAGE"; fi
      case "$1" in --*) nd_err "usage: run.sh stage <name> [options]"; return "$ND_USAGE" ;; esac
      cmd_stage "$@" ;;
    plan)
      if [ $# -lt 1 ]; then nd_err "usage: run.sh plan <name> [options]"; return "$ND_USAGE"; fi
      case "$1" in --*) nd_err "usage: run.sh plan <name> [options]"; return "$ND_USAGE" ;; esac
      cmd_plan "$@" ;;
    receipt) cmd_receipt "$@" ;;
    check-matrix)
      [ $# -eq 1 ] || { nd_err "usage: run.sh check-matrix <matrix.tsv>"; return "$ND_USAGE"; }
      cmd_check_matrix "$1" ;;
    check-scenarios)
      [ $# -eq 0 ] || { nd_err "usage: run.sh check-scenarios"; return "$ND_USAGE"; }
      cmd_check_scenarios ;;
    check-contracts)
      [ $# -eq 1 ] || { nd_err "usage: run.sh check-contracts <workflow.md>"; return "$ND_USAGE"; }
      cmd_check_contracts "$1" ;;
    new-run)
      [ $# -ge 1 ] || { nd_err "usage: run.sh new-run <command words...>"; return "$ND_USAGE"; }
      nd_new_run "$@" || return $?
      printf '%s\n' "$ARTIFACT_DIR" ;;
    -h|--help|help) nd_usage ;;
    '') nd_usage >&2; return "$ND_USAGE" ;;
    *) nd_err "unknown kind or command '$cmd' (kinds: unit integration live; commands: --list stage plan receipt check-matrix check-contracts check-scenarios)"
       return "$ND_USAGE" ;;
  esac
}

main "$@"
exit $?
