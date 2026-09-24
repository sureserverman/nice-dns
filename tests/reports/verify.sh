#!/usr/bin/env bash
# Scenario and receipt verifier (sub-plan 01, Task 2.2; ARCH-09).
#
# Usage:
#   bash tests/reports/verify.sh check RECEIPT.tsv [requirements...]
#   bash tests/reports/verify.sh manifests
#
# Requirements:
#   --require-matrix all|representative|none   eight observed cells | at least
#                                               one observed linux and macos cell
#   --require-platforms all    every platform has an observed cell
#   --require-proxies all      every proxy has an observed cell
#   --require-entrypoints all  all four installer entrypoints recorded as pass
#   --require-dep NAME         a verified link to receipt NAME (repeatable)
#
# A receipt (schema nice-dns-receipt/1) is TSV data, never sourced. Row types:
#   receipt NAME | run_id ID | created_utc TS
#   source   REPO SHA40 clean|dirty                  (all five repositories)
#   arch     REPO SHA40 PLATFORM,...                 (CPU build support; must
#            equal the platforms the repo's .github/workflows/main.yml defines
#            at that SHA, so documented support cannot silently drop)
#   requires NAME PATH SHA256                        (linked receipt, verified
#            recursively)
#   cell     PLATFORM PROXY PIHOLE TARGET IMAGE_GEN observed|blocked
#   scenario ID CELL|- pass|fail|blocked ARTIFACT SHA256 IMAGE_GEN|-
#   aggregate PATH SHA256 SAMPLES                     (must equal stats.sh
#            recomputed over SAMPLES)
#   entrypoint NAME pass|fail
#   product  nice-dns|pi-hole-hardened SHA40        (the installed product;
#            optional, at most one per repository)
# Scenario ids, scopes and required links come from tests/manifests/NAME.tsv;
# anything undeclared fails. Content, not only structure, is checked:
#   - manifest `minimum SCENARIO N`: its artifact is a nice-dns-sample/1 file
#     with at least N sample rows;
#   - manifest `content SCENARIO ERE`: its artifact has a line matching ERE;
#   - every nice-dns-sample/1 file (scenario artifact or aggregate samples)
#     carries the receipt's run_id, the product (or, with no product row,
#     the nice-dns source) revision, and, for a cell's samples, exactly that
#     cell's target, platform, proxy, pihole and image generation;
#   - an artifact carrying a `git_head` line names the nice-dns source row. Artifact paths are relative to the receipt's
# directory, never absolute, never "..", never symlinks.
#
# Exit: 0 valid; 1 invalid (every problem is listed); 2 usage.
# Portability: Bash 3.2, POSIX awk, sha256sum or shasum.

set -u

V_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
V_SELF="$V_ROOT/tests/reports/verify.sh"
MAN="${NICE_DNS_TEST_MANIFESTS:-$V_ROOT/tests/manifests}"
SIB="${NICE_DNS_SIBLINGS_DIR:-$(cd "$V_ROOT/.." && pwd -P)}"
SCHEMA='nice-dns-receipt/1'
REPOS='nice-dns tor-haproxy tor-socat hardened-unbound pi-hole-hardened'
ARCH_REPOS='tor-haproxy tor-socat hardened-unbound pi-hole-hardened'
RECEIPTS='baseline transport controller installers qualification'
ENTRYPOINTS='install-deb.sh install-deb-hardened.sh install-mac.sh install-mac-hardened.sh'
TAB="$(printf '\t')"

ERRS=0
err() { printf 'verify.sh: %s\n' "$*" >&2; ERRS=$((ERRS + 1)); }
die() { printf 'verify.sh: %s\n' "$*" >&2; exit 2; }

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

source_platforms() {
  # source_platforms REPO SHA: platforms main.yml defines at SHA, sorted.
  git -C "$SIB/$1" show "$2:.github/workflows/main.yml" 2>/dev/null |
    awk '/^ *platform: *$/ { on = 1; next } on && /^ *- *linux\// { sub(/^ *- */, ""); print; next } on { on = 0 }' |
    sort | paste -sd, -
}

safe_rel() {
  # safe_rel DIR REL: REL is a relative path inside DIR with no symlink on the way.
  local d="$1" rel="$2" p part
  case "$rel" in ''|/*|..|../*|*/../*|*/..) return 1 ;; esac
  p="$d"
  for part in $(printf '%s' "$rel" | tr '/' ' '); do
    p="$p/$part"
    [ -L "$p" ] && return 1
  done
  [ -f "$p" ]
}

# ─── manifests ───────────────────────────────────────────────────────────────

manifest_rows() { awk -F '\t' -v t="$2" '!/^#/ && $1 == t' "$MAN/$1.tsv"; }

cmd_manifests() {
  local m kind a b c d ids reqs seen
  for m in $RECEIPTS; do
    [ -f "$MAN/$m.tsv" ] || { err "receipt manifest $MAN/$m.tsv is missing"; continue; }
    ids='|' reqs=''
    while IFS="$TAB" read -r kind a b c d || [ -n "${kind:-}" ]; do
      case "$kind" in ''|'#'*) continue ;; esac
      case "$kind" in
        requires)
          in_list "$a" "$RECEIPTS" || err "$m.tsv: requires unknown receipt '$a'"
          [ "$a" != "$m" ] || err "$m.tsv: requires itself"
          reqs="$reqs${reqs:+,}$a" ;;
        scenario)
          [ -n "${c:-}" ] && [ -z "${d:-}" ] || err "$m.tsv: scenario row needs id, scope, meaning"
          case "$b" in per-cell|global) ;; *) err "$m.tsv: scenario $a has scope '$b'" ;; esac
          case "$ids" in *"|$a|"*) err "$m.tsv: duplicate scenario $a" ;; esac
          ids="$ids$a|" ;;
        minimum)
          [ -n "${b:-}" ] && [ -z "${c:-}" ] || err "$m.tsv: minimum row needs scenario, count"
          case "$b" in ''|*[!0-9]*) err "$m.tsv: minimum for $a is not a count" ;; esac ;;
        content) ;;   # checked below from the raw row: its pattern may hold tabs
        *) err "$m.tsv: unknown row type '$kind'" ;;
      esac
    done <"$MAN/$m.tsv"
    while IFS= read -r a; do
      [ -n "$a" ] || err "$m.tsv: content row has an empty pattern"
    done < <(awk -F '\t' '!/^#/ && $1 == "content" { p = $0; if (!sub(/^[^\t]*\t[^\t]*\t/, "", p)) p = ""; print p }' "$MAN/$m.tsv")
    for a in $(awk -F '\t' '!/^#/ && ($1 == "minimum" || $1 == "content") { print $2 }' "$MAN/$m.tsv"); do
      case "$ids" in *"|$a|"*) ;; *) err "$m.tsv: minimum/content for undeclared scenario $a" ;; esac
    done
    printf '%s requires %s\n' "$m" "${reqs:-nothing}"
  done
  # The requires graph must be acyclic: walk it from every receipt.
  for m in $RECEIPTS; do
    seen="|$m|"
    walk_requires "$m" "$seen"
  done
  [ "$ERRS" -eq 0 ] || exit 1
  exit 0
}

walk_requires() {
  local r
  for r in $(manifest_rows "$1" requires 2>/dev/null | cut -f2); do
    case "$2" in *"|$r|"*) err "receipt manifests have a requires cycle through $r"; return ;; esac
    walk_requires "$r" "$2$r|"
  done
}

# ─── check ───────────────────────────────────────────────────────────────────

cmd_check() {
  local f="$1" d name n cells=0 scen=0
  local req_matrix=none req_platforms='' req_proxies='' req_entry='' req_deps=''
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --require-matrix|--require-platforms|--require-proxies|--require-entrypoints|--require-dep)
        [ $# -ge 2 ] || die "option $1 needs a value"
        case "$1" in
          --require-matrix) case "$2" in all|representative|none) req_matrix="$2" ;; *) die "--require-matrix all|representative|none" ;; esac ;;
          --require-platforms) [ "$2" = all ] || die "--require-platforms all"; req_platforms=all ;;
          --require-proxies) [ "$2" = all ] || die "--require-proxies all"; req_proxies=all ;;
          --require-entrypoints) [ "$2" = all ] || die "--require-entrypoints all"; req_entry=all ;;
          --require-dep) in_list "$2" "$RECEIPTS" || die "--require-dep: unknown receipt '$2'"; req_deps="$req_deps $2" ;;
        esac
        shift 2 ;;
      *) die "unknown option '$1'" ;;
    esac
  done
  [ "${NICE_DNS_VERIFY_DEPTH:-0}" -lt 6 ] || die "receipt dependency chain too deep"

  [ -L "$f" ] && die "receipt $f is a symlink"
  [ -f "$f" ] || die "receipt $f not found"
  d="$(cd "$(dirname "$f")" && pwd -P)"
  [ "$(sed -n 1p "$f")" = "# schema${TAB}$SCHEMA" ] || { err "$f: first line must be '# schema<TAB>$SCHEMA'"; finish "$f" 0 0; }

  # Row shapes and types.
  while IFS= read -r n; do err "$f: $n"; done < <(awk -F '\t' '
    BEGIN { w["receipt"] = 2; w["run_id"] = 2; w["created_utc"] = 2; w["source"] = 4; w["arch"] = 4
            w["requires"] = 4; w["cell"] = 7; w["scenario"] = 7; w["aggregate"] = 4; w["entrypoint"] = 3; w["product"] = 3 }
    /^#/ || /^$/ { next }
    !($1 in w) { printf "line %d: unknown row type %s\n", NR, $1; next }
    NF != w[$1] { printf "line %d: %s row has %d fields, expected %d\n", NR, $1, NF, w[$1] }
    $1 == "receipt" || $1 == "run_id" || $1 == "created_utc" { c[$1]++ }
    END { for (k in c) if (c[k] != 1) printf "%s appears %d times\n", k, c[k]
          if (!("receipt" in c)) print "no receipt row"; if (!("run_id" in c)) print "no run_id row" }' "$f")

  name="$(awk -F '\t' '$1 == "receipt" { print $2; exit }' "$f")"
  if ! in_list "$name" "$RECEIPTS" || [ ! -f "$MAN/$name.tsv" ]; then
    err "$f: unknown receipt '$name' (known: $RECEIPTS)"
    finish "$f" 0 0
  fi

  check_sources "$f"
  check_products "$f"
  check_requires "$f" "$name" "$req_deps"
  # Called directly (not in $(...)) so their err() calls reach ERRS.
  check_cells "$f"; cells="$CELLS"
  check_scenarios "$f" "$d" "$name"; scen="$SCEN"
  check_aggregates "$f" "$d"
  check_contents "$f" "$d" "$name"
  check_entrypoints "$f" "$req_entry"
  check_requirements "$f" "$req_matrix" "$req_platforms" "$req_proxies"
  finish "$f" "$cells" "$scen" "$name"
}

finish() {
  printf 'receipt=%s cells=%s scenarios=%s errors=%s file=%s\n' "${4:-?}" "$2" "$3" "$ERRS" "$1"
  [ "$ERRS" -eq 0 ] || exit 1
  exit 0
}

check_sources() {
  local f="$1" repo rows s p want got
  for repo in $REPOS; do
    rows="$(awk -F '\t' -v r="$repo" '$1 == "source" && $2 == r' "$f")"
    [ "$(printf '%s' "$rows" | grep -c .)" = 1 ] || { err "$f: need exactly one source row for $repo"; continue; }
    s="$(printf '%s\n' "$rows" | cut -f3)"
    printf '%s' "$s" | grep -Eq '^[0-9a-f]{40}$' || err "$f: source $repo sha '$s' is not a full commit id"
    case "$(printf '%s\n' "$rows" | cut -f4)" in clean|dirty) ;; *) err "$f: source $repo state must be clean or dirty" ;; esac
  done
  for repo in $(awk -F '\t' '$1 == "source" { print $2 }' "$f"); do
    in_list "$repo" "$REPOS" || err "$f: source row for unknown repository '$repo'"
  done
  for repo in $ARCH_REPOS; do
    rows="$(awk -F '\t' -v r="$repo" '$1 == "arch" && $2 == r' "$f")"
    [ "$(printf '%s' "$rows" | grep -c .)" = 1 ] || { err "$f: need exactly one arch (CPU build support) row for $repo"; continue; }
    p="$(printf '%s\n' "$rows" | cut -f3)"
    [ "$p" = "$(awk -F '\t' -v r="$repo" '$1 == "source" && $2 == r { print $3 }' "$f")" ] \
      || err "$f: arch row for $repo is at $p, not at the receipt's source revision"
    want="$(source_platforms "$repo" "$p")"
    got="$(printf '%s\n' "$rows" | cut -f4 | tr ',' '\n' | sort | paste -sd, -)"
    if [ -z "$want" ]; then err "$f: cannot read source-defined platforms for $repo at $p"
    elif [ "$want" != "$got" ]; then err "$f: $repo CPU build support is '$got' but source defines '$want'"
    fi
  done
}

check_requires() {
  local f="$1" name="$2" deps="$3" r rows p s rn
  for r in $(manifest_rows "$name" requires | cut -f2) $deps; do
    rows="$(awk -F '\t' -v r="$r" '$1 == "requires" && $2 == r' "$f")"
    [ -n "$rows" ] || { err "$f: $name must link a verified $r receipt (requires row missing)"; continue; }
  done
  while IFS="$TAB" read -r _ r p s; do
    manifest_rows "$name" requires | cut -f2 | grep -Fxq -- "$r" || { err "$f: $name does not declare a dependency on '$r'"; continue; }
    if [ -L "$p" ] || [ ! -f "$p" ]; then err "$f: linked $r receipt $p is missing or a symlink"; continue; fi
    [ "$(sha "$p")" = "$s" ] || { err "$f: linked $r receipt $p changed after it was linked (sha256 mismatch)"; continue; }
    rn="$(awk -F '\t' '$1 == "receipt" { print $2; exit }' "$p")"
    [ "$rn" = "$r" ] || { err "$f: linked file $p is a '$rn' receipt, not '$r'"; continue; }
    NICE_DNS_VERIFY_DEPTH=$(( ${NICE_DNS_VERIFY_DEPTH:-0} + 1 )) bash "$V_SELF" check "$p" >/dev/null 2>"$p.verify.err.$$" \
      || { err "$f: linked $r receipt does not verify:"; sed 's/^/    /' "$p.verify.err.$$" >&2; }
    rm -f "$p.verify.err.$$"
  done < <(awk -F '\t' '$1 == "requires"' "$f")
}

check_cells() {
  # Sets CELLS to the number of observed cells.
  local f="$1" p x h t g s key n=0 seen='|'
  while IFS="$TAB" read -r _ p x h t g s; do
    key="$p/$x/$h"
    awk -F '\t' -v p="$p" -v x="$x" -v h="$h" '!/^#/ && $1 == p && $2 == x && $3 == h { f = 1 } END { exit !f }' "$MAN/matrix.tsv" \
      || err "$f: cell $key is not in the eight-cell matrix"
    case "$seen" in *"|$key|"*) err "$f: cell $key listed twice" ;; esac
    seen="$seen$key|"
    [ -n "$t" ] && [ "$t" != - ] || err "$f: cell $key has no target identity"
    case "$g" in *=*) ;; *) err "$f: cell $key has no image generation" ;; esac
    case "$s" in observed) n=$((n + 1)) ;; blocked) ;; *) err "$f: cell $key status '$s'" ;; esac
  done < <(awk -F '\t' '$1 == "cell"' "$f")
  CELLS="$n"
}

check_scenarios() {
  # Sets SCEN to the number of scenario rows.
  local f="$1" d="$2" name="$3" id c s a h g scope want k n=0 seen='|'
  while IFS="$TAB" read -r _ id c s a h g; do
    n=$((n + 1))
    scope="$(manifest_rows "$name" scenario | awk -F '\t' -v i="$id" '$2 == i { print $3; exit }')"
    [ -n "$scope" ] || { err "$f: scenario $id is not declared in $name.tsv"; continue; }
    case "$seen" in *"|$id@$c|"*) err "$f: scenario $id for $c listed twice" ;; esac
    seen="$seen$id@$c|"
    [ "$s" = pass ] || err "$f: scenario $id ($c) is $s, not pass"
    if [ "$scope" = global ]; then
      [ "$c" = - ] && [ "$g" = - ] || err "$f: global scenario $id must not name a cell or image generation"
    else
      want="$(awk -F '\t' -v k="$c" '$1 == "cell" && $2 "/" $3 "/" $4 == k && $7 == "observed" { print $6; exit }' "$f")"
      if [ -z "$want" ]; then err "$f: scenario $id names $c, which is not an observed cell"
      elif [ "$g" != "$want" ]; then err "$f: scenario $id ($c) was recorded against image generation '$g', the cell runs '$want'"
      fi
    fi
    if ! safe_rel "$d" "$a"; then err "$f: scenario $id ($c) artifact '$a' is not a regular file inside the receipt dir"
    elif [ "$(sha "$d/$a")" != "$h" ]; then err "$f: scenario $id ($c) artifact $a changed (sha256 mismatch)"
    fi
  done < <(awk -F '\t' '$1 == "scenario"' "$f")
  while IFS="$TAB" read -r _ id scope _; do
    if [ "$scope" = global ]; then
      case "$seen" in *"|$id@-|"*) ;; *) err "$f: missing scenario $id" ;; esac
    else
      for k in $(awk -F '\t' '$1 == "cell" && $7 == "observed" { print $2 "/" $3 "/" $4 }' "$f"); do
        case "$seen" in *"|$id@$k|"*) ;; *) err "$f: missing scenario $id for cell $k" ;; esac
      done
    fi
  done < <(manifest_rows "$name" scenario)
  SCEN="$n"
}

check_products() {
  local f="$1" repo sha
  while IFS="$TAB" read -r _ repo sha; do
    case "$repo" in nice-dns|pi-hole-hardened) ;; *) err "$f: product row for unknown repository '$repo'" ;; esac
    printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || err "$f: product $repo '$sha' is not a full commit id"
  done < <(awk -F '\t' '$1 == "product"' "$f")
  for repo in nice-dns pi-hole-hardened; do
    [ "$(awk -F '\t' -v r="$repo" '$1 == "product" && $2 == r' "$f" | grep -c .)" -le 1 ] || err "$f: more than one product row for $repo"
  done
}

# sample_rows FILE: the sample rows of a nice-dns-sample/1 file (no header).
is_samples() { [ "$(sed -n 1p "$1" 2>/dev/null)" = "# schema${TAB}nice-dns-sample/1" ]; }

check_sample_identity() {
  # check_sample_identity RECEIPT FILE CELLKEY|- : run, revision and cell
  # identity of every sample row.
  local f="$1" s="$2" key="$3" run rev cellrow bad
  run="$(awk -F '\t' '$1 == "run_id" { print $2; exit }' "$f")"
  rev="$(awk -F '\t' '$1 == "product" && $2 == "nice-dns" { print $3; exit }' "$f")"
  [ -n "$rev" ] || rev="$(awk -F '\t' '$1 == "source" && $2 == "nice-dns" { print $3; exit }' "$f")"
  cellrow="-"
  [ "$key" = - ] || cellrow="$(awk -F '\t' -v k="$key" '$1 == "cell" && $2 "/" $3 "/" $4 == k { print $5 "\t" $2 "\t" $3 "\t" $4 "\t" $6; exit }' "$f")"
  bad="$(awk -F '\t' -v run="$run" -v rev="$rev" -v cell="$cellrow" '
    NR <= 2 || /^#/ { next }
    { n++
      if ($1 != run) { printf "row %d run_id %s is not the receipt run %s\n", NR, $1, run; exit }
      if ($11 != rev) { printf "row %d source_rev %s is not the recorded revision %s\n", NR, $11, rev; exit }
      if (cell != "-" && ($7 "\t" $8 "\t" $9 "\t" $10 "\t" $12) != cell) { printf "row %d is %s/%s/%s on %s (%s), not this cell\n", NR, $8, $9, $10, $7, $12; exit } }' "$s")"
  [ -z "$bad" ] || err "$f: samples ${s##*/} ($key): $bad"
}

check_contents() {
  local f="$1" d="$2" name="$3" id c a n min pat src head
  src="$(awk -F '\t' '$1 == "source" && $2 == "nice-dns" { print $3; exit }' "$f")"
  while IFS="$TAB" read -r _ id c _ a _ _; do
    safe_rel "$d" "$a" || continue
    if is_samples "$d/$a"; then check_sample_identity "$f" "$d/$a" "$c"; fi
    head="$(awk -F '\t' '$1 == "git_head" { print $2; exit }' "$d/$a")"
    [ -z "$head" ] || [ "$head" = "$src" ] || err "$f: scenario $id artifact names git_head $head, not the nice-dns source $src"
    min="$(manifest_rows "$name" minimum | awk -F '\t' -v i="$id" '$2 == i { print $3; exit }')"
    if [ -n "$min" ]; then
      if ! is_samples "$d/$a"; then err "$f: scenario $id ($c) artifact $a is not a sample file"
      else
        n="$(awk 'NR > 2 && !/^#/' "$d/$a" | grep -c .)"
        [ "$n" -ge "$min" ] || err "$f: scenario $id ($c) has $n samples, fewer than the declared minimum $min"
      fi
    fi
    # The pattern is the literal rest of the row after "content<TAB>ID<TAB>":
    # `read` with a tab IFS would merge adjacent tabs and strip a trailing one.
    while IFS= read -r pat; do
      grep -Eq -- "$pat" "$d/$a" || err "$f: scenario $id ($c) artifact $a has no line matching /$pat/"
    done < <(manifest_rows "$name" content | awk -F '\t' -v i="$id" '$2 == i { sub(/^[^\t]*\t[^\t]*\t/, ""); print }')
  done < <(awk -F '\t' '$1 == "scenario"' "$f")
  # Aggregate sample files under cells/P-X-H/ belong to that cell.
  while IFS="$TAB" read -r _ _ _ a; do
    safe_rel "$d" "$a" && is_samples "$d/$a" || continue
    c="$(awk -F '\t' -v p="$a" '$1 == "cell" { k = "cells/" $2 "-" $3 "-" $4 "/"; if (index(p, k) == 1) { print $2 "/" $3 "/" $4; exit } }' "$f")"
    check_sample_identity "$f" "$d/$a" "${c:--}"
  done < <(awk -F '\t' '$1 == "aggregate"' "$f")
}

check_aggregates() {
  local f="$1" d="$2" a h src
  while IFS="$TAB" read -r _ a h src; do
    if ! safe_rel "$d" "$a" || ! safe_rel "$d" "$src"; then err "$f: aggregate $a or its samples $src is not a regular file inside the receipt dir"; continue; fi
    [ "$(sha "$d/$a")" = "$h" ] || err "$f: aggregate $a changed (sha256 mismatch)"
    bash "$V_ROOT/tests/reports/stats.sh" "$d/$src" 2>/dev/null | cmp -s - "$d/$a" \
      || err "$f: aggregate $a does not equal stats recomputed over $src"
  done < <(awk -F '\t' '$1 == "aggregate"' "$f")
}

check_entrypoints() {
  local f="$1" req="$2" e s
  while IFS="$TAB" read -r _ e s; do
    in_list "$e" "$ENTRYPOINTS" || err "$f: unknown entrypoint '$e'"
    case "$s" in pass|fail) ;; *) err "$f: entrypoint $e status '$s'" ;; esac
  done < <(awk -F '\t' '$1 == "entrypoint"' "$f")
  [ "$req" = all ] || return 0
  for e in $ENTRYPOINTS; do
    [ "$(awk -F '\t' -v e="$e" '$1 == "entrypoint" && $2 == e { print $3 }' "$f")" = pass ] \
      || err "$f: entrypoint $e has no pass result"
  done
}

check_requirements() {
  local f="$1" m="$2" plats="$3" proxies="$4" p x h st v
  if [ "$m" = all ]; then
    while IFS="$TAB" read -r p x h; do
      case "$p" in ''|'#'*) continue ;; esac
      st="$(awk -F '\t' -v p="$p" -v x="$x" -v h="$h" '$1 == "cell" && $2 == p && $3 == x && $4 == h { print $7; exit }' "$f")"
      case "$st" in
        observed) ;;
        '') err "$f: cell $p/$x/$h is missing (skipped cells are never green)" ;;
        *) err "$f: cell $p/$x/$h is $st (skipped cells are never green)" ;;
      esac
    done <"$MAN/matrix.tsv"
  fi
  if [ "$m" = representative ] || [ "$plats" = all ]; then
    for v in linux macos; do
      awk -F '\t' -v v="$v" '$1 == "cell" && $2 == v && $7 == "observed" { f = 1 } END { exit !f }' "$f" \
        || err "$f: no observed $v cell"
    done
  fi
  if [ "$proxies" = all ]; then
    for v in haproxy socat; do
      awk -F '\t' -v v="$v" '$1 == "cell" && $3 == v && $7 == "observed" { f = 1 } END { exit !f }' "$f" \
        || err "$f: no observed $v cell"
    done
  fi
}

case "${1:-}" in
  check) shift; [ $# -ge 1 ] || die "usage: verify.sh check RECEIPT.tsv [requirements]"; cmd_check "$@" ;;
  manifests) shift; [ $# -eq 0 ] || die "usage: verify.sh manifests"; cmd_manifests ;;
  *) die "usage: verify.sh check RECEIPT.tsv [requirements] | verify.sh manifests" ;;
esac
