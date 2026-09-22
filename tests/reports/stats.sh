#!/usr/bin/env bash
# Per-workload latency and failure summary (sub-plan 01, Task 1.3; ARCH-09).
#
# Usage: bash tests/reports/stats.sh SAMPLES.tsv
#
# Reads a nice-dns-sample/1 file and prints one TSV row per workload:
#   attempted ok failed timeouts failure_rate timeout_rate
#   p{50,95,99}_ok_us   nearest-rank over answered attempts (NOERROR/NXDOMAIN)
#   p{50,95,99}_all_us  nearest-rank over every attempt, failures = inf
#   p{50,95,99}_support supported when attempted*(100-p)/100 >= 10, else
#                       exploratory (too few samples beyond the percentile)
# Failures always stay in the denominators. n/a means no answered attempts.
# A file holds one run: sample_id must run 1..N in order under one run_id, so
# a deleted or filtered row is refused rather than shrinking the denominator.
# Exit 2 on a missing/unknown schema, a malformed row, a missing row, mixed
# runs, or zero samples.
#
# Portability: Bash 3.2, POSIX awk (no asort) and sort.

set -u

SCHEMA='nice-dns-sample/1'
NCOL=19
INF=999999999999999

die() { printf 'stats.sh: %s\n' "$*" >&2; exit 2; }

[ $# -eq 1 ] || die "usage: stats.sh SAMPLES.tsv"
f="$1"
[ -f "$f" ] || die "no such file: $f"
[ "$(sed -n 1p "$f")" = "# schema	$SCHEMA" ] || die "$f: first line must be '# schema<TAB>$SCHEMA'"

# Validate and flatten: workload<TAB>set<TAB>value, where set is ok or all.
flat="$(awk -F '\t' -v ncol="$NCOL" -v inf="$INF" '
  NR == 1 { next }
  /^#/ { next }
  !hdr {
    if (NF != ncol) { printf "stats.sh: header has %d columns, expected %d\n", NF, ncol > "/dev/stderr"; bad = 1; exit }
    for (i = 1; i <= NF; i++) col[$i] = i
    if (!("workload" in col) || !("elapsed_us" in col) || !("outcome" in col) || !("sample_id" in col) || !("run_id" in col)) { print "stats.sh: header lacks run_id/sample_id/workload/elapsed_us/outcome column" > "/dev/stderr"; bad = 1; exit }
    hdr = 1; next
  }
  {
    if (NF != ncol) { printf "stats.sh: line %d has %d columns, expected %d\n", NR, NF, ncol > "/dev/stderr"; bad = 1; exit }
    w = $col["workload"]; o = $col["outcome"]; e = $col["elapsed_us"]
    if (e !~ /^[0-9]+$/) { printf "stats.sh: line %d elapsed_us is not an integer\n", NR > "/dev/stderr"; bad = 1; exit }
    n++
    if ($col["sample_id"] != n) { printf "stats.sh: line %d has sample_id %s where %d was expected: missing or reordered rows\n", NR, $col["sample_id"], n > "/dev/stderr"; bad = 1; exit }
    if (n == 1) run = $col["run_id"]
    else if ($col["run_id"] != run) { printf "stats.sh: line %d belongs to run %s, not %s: one file holds one run\n", NR, $col["run_id"], run > "/dev/stderr"; bad = 1; exit }
    if (o == "ok" || o == "nxdomain") { print w "\tok\t" e; print w "\tall\t" e }
    else { print w "\tfail\t" (o == "timeout" ? "timeout" : "other"); print w "\tall\t" inf }
  }
  END { if (bad) exit 2; if (!n) { print "stats.sh: no samples (a header-only file is never a result)" > "/dev/stderr"; exit 2 } }
' "$f")" || exit 2

printf '%s\n' "$flat" | sort -t '	' -k1,1 -k2,2 -k3,3n | awk -F '\t' -v inf="$INF" '
  function pct(arr, n, p,   r) {
    if (n == 0) return "n/a"
    r = int((p * n + 99) / 100); if (r < 1) r = 1
    return (arr[r] == inf) ? "inf" : arr[r]
  }
  function support(n, p) { return (n * (100 - p) >= 1000) ? "supported" : "exploratory" }
  function flush() {
    if (cur == "") return
    att = nall; okn = nok
    printf "%s\t%d\t%d\t%d\t%d\t%.4f\t%.4f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", cur, att, okn, att - okn, nto,
      (att - okn) / att, nto / att,
      pct(okv, nok, 50), pct(okv, nok, 95), pct(okv, nok, 99),
      pct(allv, nall, 50), pct(allv, nall, 95), pct(allv, nall, 99),
      support(att, 50), support(att, 95), support(att, 99)
  }
  BEGIN {
    print "workload\tattempted\tok\tfailed\ttimeouts\tfailure_rate\ttimeout_rate\tp50_ok_us\tp95_ok_us\tp99_ok_us\tp50_all_us\tp95_all_us\tp99_all_us\tp50_support\tp95_support\tp99_support"
    cur = ""
  }
  $1 != cur { flush(); cur = $1; nok = 0; nall = 0; nto = 0; split("", okv); split("", allv) }
  $2 == "ok" { okv[++nok] = $3 }
  $2 == "all" { allv[++nall] = $3 }
  $2 == "fail" && $3 == "timeout" { nto++ }
  END { flush() }
'
