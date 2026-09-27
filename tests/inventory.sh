#!/usr/bin/env bash
# nice-dns source inventory (sub-plan 01, Task 1.1).
#
# Usage: bash tests/inventory.sh <baseline|transport|controller> [--out DIR]
#   (the label names the sub-plan taking the inventory; both record the same)
#
# Records, for nice-dns and its four sibling repositories (tor-haproxy,
# tor-socat, hardened-unbound, pi-hole-hardened): full HEAD SHA, branch,
# complete `git status` (untracked bridge-eval binaries flagged untrusted) and
# the complete `git ls-files` list — never truncated. Adds the master plan's
# content sweep over nice-dns host-control sources.
#
# Output: <out>/<repo>.inventory.tsv, <out>/summary.tsv,
#         <out>/content-sweep.tsv. Without --out, a new run directory is
#         created by `tests/run.sh new-run` (outside the checkout, with a
#         creation receipt) and <run>/inventory is used. The output directory
#         is printed as the last line.
#
# Environment: NICE_DNS_SIBLINGS_DIR (default: the checkout's parent dir),
#              NICE_DNS_TEST_ARTIFACTS (see tests/run.sh).
# Read-only towards every repository: git runs with GIT_OPTIONAL_LOCKS=0 so
# `git status` does not refresh or lock any index.
# Exit: 0 complete; 1 a repository is missing or unreadable (partial output
# is still written and named); 2 usage error. Bash 3.2 compatible.

set -u
umask 077

INV_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
INV_ROOT_LOGICAL="$(cd "$(dirname "$0")/.." && pwd)"
INV_RUNNER="$INV_ROOT/tests/run.sh"
INV_SIBS="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$INV_ROOT")}"
INV_SIBLINGS="tor-haproxy tor-socat hardened-unbound pi-hole-hardened"
INV_PATTERN='Health|health|forward-addr|BRIDGE|resolv.conf|networksetup'
GIT_OPTIONAL_LOCKS=0
export GIT_OPTIONAL_LOCKS

inv_err() { printf 'inventory.sh: %s\n' "$*" >&2; }
inv_usage() { inv_err "usage: inventory.sh <baseline|transport|controller> [--out DIR]"; }

inv_inside_checkout() {
  case "$1/" in "$INV_ROOT"/*|"$INV_ROOT_LOGICAL"/*) return 0 ;; esac
  return 1
}

# inv_repo <name> <path> <outdir>: 0 on success, 1 if missing/unreadable.
inv_repo() {
  local name="$1" path="$2" out="$3" f head branch porcelain dirty line xy p nfiles=0 nuntrusted=0
  f="$out/$name.inventory.tsv"
  if [ ! -d "$path" ]; then
    inv_err "MISSING repository $name: $path does not exist"
    printf '%s\t%s\tMISSING\t\t\t\t\n' "$name" "$path" >>"$out/summary.tsv"
    return 1
  fi
  if ! head="$(git -C "$path" rev-parse --verify HEAD 2>/dev/null)"; then
    inv_err "UNREADABLE repository $name: $path is not a git work tree with a HEAD commit"
    printf '%s\t%s\tUNREADABLE\t\t\t\t\n' "$name" "$path" >>"$out/summary.tsv"
    return 1
  fi
  case "$head" in
    *[!0-9a-f]*|'') inv_err "$name: unexpected HEAD '$head'"; return 1 ;;
  esac
  [ "${#head}" -eq 40 ] || { inv_err "$name: HEAD '$head' is not a full 40-hex SHA"; return 1; }
  branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  if ! porcelain="$(git -C "$path" status --porcelain --untracked-files=all 2>/dev/null)"; then
    inv_err "$name: git status failed"
    return 1
  fi
  if [ -n "$porcelain" ]; then dirty=yes; else dirty=no; fi
  {
    printf 'schema\tnice-dns-inventory/1\n'
    printf 'repo\t%s\n' "$name"
    printf 'path\t%s\n' "$(cd "$path" && pwd -P)"
    printf 'head\t%s\n' "$head"
    printf 'branch\t%s\n' "$branch"
    printf 'dirty\t%s\n' "$dirty"
    printf 'captured_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$f"
  if [ -n "$porcelain" ]; then
    while IFS= read -r line; do
      printf 'status\t%s\n' "$line" >>"$f"
      xy="$(printf '%s' "$line" | cut -c1-2)"
      p="$(printf '%s' "$line" | cut -c4-)"
      if [ "$xy" = '??' ]; then
        case "$p" in
          bridge-eval|*/bridge-eval)
            printf 'untrusted\t%s\tuntracked bridge-eval binary; not a reviewed build input\n' "$p" >>"$f"
            nuntrusted=$((nuntrusted + 1)) ;;
          *) printf 'untracked\t%s\n' "$p" >>"$f" ;;
        esac
      fi
    done <<EOF
$porcelain
EOF
  fi
  git -C "$path" ls-files >"$out/.ls-files.$name" 2>/dev/null || { inv_err "$name: git ls-files failed"; return 1; }
  while IFS= read -r line; do
    printf 'file\t%s\n' "$line" >>"$f"
    nfiles=$((nfiles + 1))
  done <"$out/.ls-files.$name"
  rm -f "$out/.ls-files.$name"
  printf 'file_count\t%s\n' "$nfiles" >>"$f"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$(cd "$path" && pwd -P)" "$head" "$branch" "$dirty" "$nfiles" "$nuntrusted" >>"$out/summary.tsv"
  printf '%-18s %s %-24s dirty=%s files=%s untrusted=%s\n' "$name" "$head" "$branch" "$dirty" "$nfiles" "$nuntrusted" >&2
  return 0
}

# Master plan sweep: rg -l '<pattern>' install-*.sh health/nice-dns-health
# deb/* deb/quadlet/* mac/* unbound/etc/*  (regular files only; grep fallback).
inv_sweep() {
  local out="$1" f tool rc cands="$1/.sweep-candidates" hits="$1/.sweep-hits" n=0
  : >"$cands"
  (
    cd "$INV_ROOT" || exit 1
    for f in install-*.sh health/nice-dns-health deb/* deb/quadlet/* mac/* unbound/etc/*; do
      [ -f "$f" ] && printf '%s\n' "$f"
    done | LC_ALL=C sort -u
  ) >"$cands" || { inv_err "content sweep: cannot enumerate candidates"; return 1; }
  while IFS= read -r f; do n=$((n + 1)); done <"$cands"
  if command -v rg >/dev/null 2>&1; then tool="rg"; else tool="grep"; fi
  (
    cd "$INV_ROOT" || exit 2
    set --
    while IFS= read -r f; do set -- "$@" "$f"; done <"$cands"
    [ $# -gt 0 ] || exit 1
    if [ "$tool" = rg ]; then
      rg -l --no-messages -e "$INV_PATTERN" -- "$@"
    else
      grep -lE -- "$INV_PATTERN" "$@"
    fi
  ) >"$hits" 2>/dev/null
  rc=$?
  if [ "$rc" -gt 1 ]; then inv_err "content sweep: $tool failed (exit $rc)"; return 1; fi
  {
    printf 'schema\tnice-dns-content-sweep/1\n'
    printf 'tool\t%s\n' "$tool"
    printf 'pattern\t%s\n' "$INV_PATTERN"
    printf 'candidates\t%s\n' "$n"
    while IFS= read -r f; do printf 'candidate\t%s\n' "$f"; done <"$cands"
    LC_ALL=C sort -u "$hits" | while IFS= read -r f; do printf 'match\t%s\n' "$f"; done
  } >"$out/content-sweep.tsv"
  rm -f "$cands" "$hits"
  return 0
}

main() {
  local mode="${1:-}" out="" phys base rc=0 r
  [ $# -gt 0 ] && shift
  case "$mode" in
    baseline|transport|controller) ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
    *) inv_usage; return 2 ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] && [ -n "$2" ] || { inv_usage; return 2; }; out="$2"; shift 2 ;;
      *) inv_err "unknown option '$1'"; inv_usage; return 2 ;;
    esac
  done
  if [ -n "$out" ]; then
    case "$out" in /*) ;; *) out="$(pwd)/$out" ;; esac
    if inv_inside_checkout "$out"; then inv_err "--out '$out' is inside the checkout; refusing"; return 2; fi
    mkdir -p "$out" || { inv_err "cannot create $out"; return 2; }
    phys="$(cd "$out" && pwd -P)"
    if inv_inside_checkout "$phys"; then inv_err "--out resolves inside the checkout ($phys); refusing"; return 2; fi
  else
    base="$(bash "$INV_RUNNER" new-run tests/inventory.sh "$mode")" || { inv_err "could not create a run directory"; return 2; }
    out="$base/inventory"
    mkdir -p "$out" || return 2
  fi
  printf '# repo\tpath\thead\tbranch\tdirty\tfile_count\tuntrusted_count\n' >"$out/summary.tsv"
  inv_repo nice-dns "$INV_ROOT" "$out" || rc=1
  for r in $INV_SIBLINGS; do
    inv_repo "$r" "$INV_SIBS/$r" "$out" || rc=1
  done
  inv_sweep "$out" || rc=1
  if [ "$rc" -ne 0 ]; then inv_err "inventory INCOMPLETE: see messages above; partial output in $out"; fi
  printf '%s\n' "$out"
  return "$rc"
}

main "$@"
exit $?
