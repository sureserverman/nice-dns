#!/usr/bin/env python3
"""Soak stability verdict (sub-plan 05 Task 2.2; ARCH-09).

Reads the check.tsv that `perf-acceptance.py check` writes for a soak's
steady samples and judges each workload by the soak's own rule (user
decisions 2026-10-04): timeouts and failures each at most 1 in 100 of the
steady samples, on every platform; p95 latency is recorded, never gated.
The frozen limits of the performance manifest stay what Stage 1's
comparisons use. Was, for the soak: the manifest's frozen limits (macOS
cold timeouts 0/30, failures 0/30, p95 636 ms; Linux cold 7/30, p95 inf),
which a single onion-route timeout or the onion route's latency failed.

Usage: soak-verdict.py <check.tsv>
Prints one line per workload:
  workload <TAB> <name> <TAB> pass|fail|insufficient <TAB> timeouts=k/n
  <TAB> failures=k/n <TAB> p95=<us|inf> <TAB> reason=<text>
Exit 0 when every workload is judged, 2 on unreadable input.
"""
import re
import sys

RATE_NUM, RATE_DEN = 1, 100   # at most 1 in 100
MIN_SAMPLES = 30              # fewer steady samples than this are not judged
RATIO = re.compile(r"^(\d+)/(\d+)$")


def refuse(msg):
    sys.stderr.write("soak-verdict: %s\n" % msg)
    sys.exit(2)


def ratio(fields, key, where):
    v = fields.get(key)
    if v is None:
        refuse("%s: no %s" % (where, key))
    m = RATIO.match(v)
    if not m:
        refuse("%s: %s is not k/n: %r" % (where, key, v))
    k, n = int(m.group(1)), int(m.group(2))
    if k > n:
        refuse("%s: %s has more than its samples: %s" % (where, key, v))
    return k, n


def within(k, n):
    """k/n <= RATE_NUM/RATE_DEN, exactly."""
    return k * RATE_DEN <= RATE_NUM * n


def main(argv):
    if len(argv) != 1:
        refuse("usage: soak-verdict.py <check.tsv>")
    try:
        lines = open(argv[0]).read().splitlines()
    except OSError as e:
        refuse("cannot read %s: %s" % (argv[0], e))
    seen = 0
    for line in lines:
        p = line.split("\t")
        if p[0] != "workload":
            continue
        if len(p) < 5:
            refuse("short workload row: %r" % line)
        w = p[2]
        fields = dict(kv.split("=", 1) for kv in p[4:] if "=" in kv)
        if "timeouts_cand" not in fields:
            # perf-acceptance wrote no counts (no candidate rows): nothing to judge.
            print("workload\t%s\tinsufficient\ttimeouts=-\tfailures=-\tp95=-\treason=no samples" % w)
            seen += 1
            continue
        tk, tn = ratio(fields, "timeouts_cand", w)
        fk, fn = ratio(fields, "failures_cand", w)
        if tn != fn:
            refuse("%s: timeouts and failures count different samples (%d, %d)" % (w, tn, fn))
        if tk > fk:
            refuse("%s: more timeouts than failures" % w)
        reason = []
        if tn < MIN_SAMPLES:
            verdict = "insufficient"
            reason.append("%d steady samples, under %d" % (tn, MIN_SAMPLES))
        else:
            if not within(tk, tn):
                reason.append("timeouts %d/%d over %d/%d" % (tk, tn, RATE_NUM, RATE_DEN))
            if not within(fk, fn):
                reason.append("failures %d/%d over %d/%d" % (fk, fn, RATE_NUM, RATE_DEN))
            verdict = "fail" if reason else "pass"
        print("workload\t%s\t%s\ttimeouts=%d/%d\tfailures=%d/%d\tp95=%s\treason=%s"
              % (w, verdict, tk, tn, fk, fn, fields.get("p95_cand", "-"), "; ".join(reason) or "-"))
        seen += 1
    if not seen:
        refuse("no workload rows in %s" % argv[0])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
