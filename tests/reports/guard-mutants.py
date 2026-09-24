#!/usr/bin/env python3
"""Per-guard mutant battery for the runner's scenario-requirement checks.

Maintainer tool (sub-plan 02, Stage 1 gate), not a test group: it edits
tests/run.sh in place, one guard at a time, runs `unit harness-contracts`,
and restores the file (also on error or Ctrl-C). Each guard must turn at
least one case red; a guard no case notices is untested or dead.

Usage: python3 tests/reports/guard-mutants.py [GUARD...]
Exit: 0 every guard is caught; 1 some guard is not; 2 a mutation no longer
applies (the guard's code changed: update the list below).
"""
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUNNER = os.path.join(ROOT, "tests", "run.sh")

G=[
 ("missing-manifest",'  if [ ! -f "$f" ]; then\n    nd_err "required manifest missing','  if false; then\n    nd_err "required manifest missing'),
 ("malformed-req",'        if (malformed(line)) { print','        if (0) { print'),
 ("check-scen-malformed",'''  if grep -nE "$(printf '\\r')|^[[:space:]]+[^[:space:]]" "$sc" >/dev/null 2>&1; then''','  if false; then'),
 ("unknown-type",'        if (f[1] != "require" && f[1] != "owner" && f[1] != "count") { print','        if (0) { print'),
 ("duplicate",'        if (id in req) { print','        if (0) { print'),
 ("no-row",'        if (!(id in kind)) { print "required scenario " id " has no row in scenarios.tsv"; continue }','        if (!(id in kind)) continue'),
 ("deferred",'        if (kind[id] == "-") { print "required scenario " id " is deferred, not active"; continue }','        if (kind[id] == "-") continue'),
 ("identity",'        if (kind[id] != f[4] || grp[id] != f[5] || cas[id] != f[6]) {','        if (0) {'),
 ("not-in-stage",'        if (!(key in gfile)) { print "required scenario " id " runs in "','        if (!(key in gfile)) { continue; print "x "'),
 ("file",'        if (gfile[key] != pin) print','        if (0) print'),
 ("owner",'            else if (!((kind[id] "/" grp[id]) in gfile))\n','            else if (0)\n'),
 ("completeness",'          print "scenario " id " runs in " st " (" kind[id] "/" grp[id] ") but is not required there"','          continue'),
 ("count-missing",'      if (nreq > 0 && !counted) print','      if (0) print'),
 ("count-mismatch",'      if (counted && want != nreq) print','      if (0) print'),
 ("path-guard","    case \"$f\" in *'|'*|*'='*|*'\\'*|*\"$(printf '\\r')\"*)","    case \"$f\" in __never__)"),
 ("post-run","  if ! nd_required_results \"$what:$name\"; then","  if false; then"),
 ("purge","for _nd_f in $(compgen -A function); do unset -f \"$_nd_f\"; done","for _nd_f in; do :; done"),
]


def main():
    want = sys.argv[1:] or [n for n, _, _ in G]
    original = open(RUNNER).read()
    missed = broken = 0
    try:
        for name, old, new in G:
            if name not in want:
                continue
            if original.count(old) != 1:
                print("%-22s MUTATION DOES NOT APPLY" % name)
                broken += 1
                continue
            open(RUNNER, "w").write(original.replace(old, new))
            out = subprocess.run(["bash", RUNNER, "unit", "harness-contracts"],
                                 capture_output=True, text=True).stdout
            red = [l.split()[1] for l in out.splitlines() if l.startswith("FAIL ")]
            print("%-22s %s" % (name, " ".join(red) if red else "NOT CAUGHT"))
            missed += not red
    finally:
        open(RUNNER, "w").write(original)
    sys.exit(2 if broken else (1 if missed else 0))


if __name__ == "__main__":
    main()
