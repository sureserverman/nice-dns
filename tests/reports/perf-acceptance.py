#!/usr/bin/env python3
"""Frozen performance acceptance: limits and baseline-vs-candidate comparison
(sub-plan 05, Task 1.1; ARCH-09, DEC-001).

Usage:
  perf-acceptance.py derive BL-TARGETS.txt
  perf-acceptance.py check-manifest [--manifest M] [--bl-targets F]
  perf-acceptance.py compare [--manifest M] [--bl-targets F] --cell P/X/H \\
      --baseline ARM.tsv --candidate ARM.tsv
  perf-acceptance.py summarize [--manifest M] [--bl-targets F] \\
      [--platform P]... RESULT.tsv...

derive prints the acceptance manifest (tests/manifests/performance-acceptance.tsv)
mechanically from a frozen baseline receipt's BL-TARGETS.txt, the matrix and the
workload manifest. The receipt id is the name of the directory holding the file.
check-manifest, compare and summarize first re-derive the manifest from the
receipt its provenance names (default: <artifact root>/receipts/baseline/<id>/,
artifact root = $NICE_DNS_TEST_ARTIFACTS or ${XDG_STATE_HOME:-~/.local/state}/
nice-dns-tests) and refuse any byte of difference, so a hand-loosened limit is
never used.

compare reads two nice-dns-sample/1 files for one cell, one per arm, each one run
(tests/reports/stats.sh validates them: schema, sample_id 1..N under one run_id,
so a deleted or filtered row is refused). It prints one verdict row per manifest
workload: pass | fail | insufficient | blocked, with counts, Wilson 95% intervals
on the timeout and failure rates, stats.sh percentiles with their support labels,
and the median gain with its interval. See the method rows of the manifest.

Verdict of a workload, first match wins:
  blocked       an arm has no rows for it (idle/wake need a same-session
                baseline arm; missing rows are never green)
  insufficient  an arm is below the sample budget (never pass, never fail)
  fail          timeout or failure count above its limit, frozen platform p95
                target exceeded, or a problem class slower beyond variability
  pass          otherwise
A cell is fail if any workload fails, else blocked, else insufficient, else pass.
A platform (summarize) passes only when every one of its matrix cells has a
result and passes, and at least one cell improved a problem class (cold, idle,
wake, or restart: time to the first answer after a stack restart, DEC-014).

Refusals (exit 2, no verdicts): manifest not a fresh derivation, invalid sample
file, arms from one run, rows of another cell, a workload row whose cache_class
differs from the manifest (classes are never pooled), arms that differ in a
control (target_id resolver transport qtype timeout_ms), utc_start going
backwards inside an arm, arms not interleaved.

Exit: compare/summarize 0 all pass; 1 a verdict is not pass; 2 refused.
derive/check-manifest 0 ok; 1 manifest differs; 2 refused.
"""
import datetime
import hashlib
import math
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MANIFESTS = os.path.join(ROOT, "tests", "manifests")
DEFAULT_MANIFEST = os.path.join(MANIFESTS, "performance-acceptance.tsv")
STATS = os.path.join(ROOT, "tests", "reports", "stats.sh")
SAMPLE_SCHEMA = "nice-dns-sample/1"
MANIFEST_SCHEMA = "nice-dns-perf-acceptance/1"
RESULT_SCHEMA = "nice-dns-perf-compare/1"

# Frozen by this task (sub-plan 05 Task 1.1); changing any of them changes
# every derivation, so it is visible in the committed manifest's diff.
# restart (DEC-014): one sample per arm swap, so its budget is sized to the
# swaps a run can afford; simulated with this tool's test at alpha 0.05/16,
# n=10 per arm keeps the no-difference false-improvement rate at or below
# alpha and detects a 20% cut 86% of the time at log-spread 0.1 (40%: 100%).
MIN_BUDGET = {"warm": 1000, "cold": 30, "idle": 30, "wake": 30, "restart": 10}
PROBLEM = ("cold", "idle", "wake", "restart")
ALPHA_FAMILY = "0.05"
MIN_BLOCKS = 5
CONTROLS = ("target_id", "resolver", "transport", "qtype", "timeout_ms")
REQUIRED_RULES = ("no-timeout-regression", "improve-problem-class", "security-absolute")
CELL_KEYS = ("attempted", "timeout_rate", "failure_rate", "p50_all_us", "p95_all_us",
             "p99_all_us", "p95_support")
TARGET_KEYS = ("timeout_rate_max", "p95_all_us_max")
INF = math.inf


class Refused(Exception):
    pass


def refuse(msg):
    raise Refused(msg)


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def data_rows(path):
    """Tab-split rows of a manifest-style file, comments and blanks skipped."""
    rows = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            if "\r" in line:
                refuse("%s: carriage return in a row" % path)
            rows.append(line.split("\t"))
    return rows


def matrix_cells():
    cells = []
    for r in data_rows(os.path.join(MANIFESTS, "matrix.tsv")):
        if len(r) != 3:
            refuse("matrix.tsv: row %r is not platform/proxy/pihole" % r)
        cells.append("/".join(r))
    return cells


def workloads():
    out = []
    for r in data_rows(os.path.join(MANIFESTS, "workloads.tsv")):
        if len(r) != 4:
            refuse("workloads.tsv: row %r has not four columns" % r)
        if r[0] not in MIN_BUDGET:
            refuse("workloads.tsv: workload %s has no sample budget in this tool" % r[0])
        out.append((r[0], r[1]))
    if sorted(w for w, _ in out) != sorted(MIN_BUDGET):
        refuse("workloads.tsv must define exactly %s" % " ".join(sorted(MIN_BUDGET)))
    return out


def kv(fields, where):
    d = {}
    for f in fields:
        if "=" not in f:
            refuse("%s: field %r is not key=value" % (where, f))
        k, v = f.split("=", 1)
        if k in d:
            refuse("%s: key %s repeated" % (where, k))
        d[k] = v
    return d


def us_value(s, where):
    if s == "inf":
        return s
    if not s.isdigit():
        refuse("%s: %r is neither microseconds nor inf" % (where, s))
    return s


def rate_count(rate, n, where):
    """A 4-decimal rate over n attempts as the whole count it rounds from."""
    if len(rate) != 6 or rate[1] != "." or not (rate[0] + rate[2:]).isdigit():
        refuse("%s: rate %r is not d.dddd" % (where, rate))
    k = int(round(float(rate) * n))
    if not 0 <= k <= n or "%.4f" % (k / n) != rate:
        refuse("%s: rate %s is not a whole count over %d attempts" % (where, rate, n))
    return k


# ─────────────────────────── derive ───────────────────────────


def derive(bl_path):
    bl_path = os.path.abspath(bl_path)
    if not os.path.isfile(bl_path):
        refuse("frozen baseline not found: %s" % bl_path)
    receipt = os.path.basename(os.path.dirname(bl_path))
    cells = matrix_cells()
    wls = workloads()
    rules, coverage, frozen, targets = [], None, {}, {}
    for r in data_rows(bl_path):
        where = "BL-TARGETS %s" % " ".join(r[:3])
        if r[0] == "coverage" and len(r) == 2:
            if coverage is not None:
                refuse("BL-TARGETS: coverage repeated")
            coverage = r[1]
        elif r[0] == "rule" and len(r) == 2 and ": " in r[1]:
            name, text = r[1].split(": ", 1)
            if name in [n for n, _ in rules]:
                refuse("BL-TARGETS: rule %s repeated" % name)
            rules.append((name, text))
        elif r[0] == "cell" and len(r) >= 3:
            key = (r[1], r[2])
            if key in frozen:
                refuse("%s: repeated" % where)
            d = kv(r[3:], where)
            if sorted(d) != sorted(CELL_KEYS):
                refuse("%s: keys must be %s" % (where, " ".join(CELL_KEYS)))
            if not d["attempted"].isdigit() or int(d["attempted"]) < 1:
                refuse("%s: attempted must be a positive integer" % where)
            n = int(d["attempted"])
            d["timeouts"] = rate_count(d["timeout_rate"], n, where)
            d["failures"] = rate_count(d["failure_rate"], n, where)
            if d["timeouts"] > d["failures"]:
                refuse("%s: more timeouts than failures" % where)
            for k in ("p50_all_us", "p95_all_us", "p99_all_us"):
                us_value(d[k], where)
            if d["p95_support"] not in ("supported", "exploratory"):
                refuse("%s: p95_support %r" % (where, d["p95_support"]))
            frozen[key] = d
        elif r[0] == "target" and len(r) >= 3:
            key = (r[1], r[2])
            if key in targets:
                refuse("%s: repeated" % where)
            d = kv(r[3:], where)
            if sorted(d) != sorted(TARGET_KEYS):
                refuse("%s: keys must be %s" % (where, " ".join(TARGET_KEYS)))
            if len(d["timeout_rate_max"]) != 6 or d["timeout_rate_max"][1] != ".":
                refuse("%s: timeout_rate_max %r" % (where, d["timeout_rate_max"]))
            us_value(d["p95_all_us_max"], where)
            targets[key] = d
        else:
            refuse("BL-TARGETS: unknown or malformed row %r" % "\t".join(r))
    for name in REQUIRED_RULES:
        if name not in [n for n, _ in rules]:
            refuse("BL-TARGETS: frozen rule %s missing" % name)
    known = set(cells)
    for c, w in frozen:
        if c not in known:
            refuse("BL-TARGETS: cell %s is not in the matrix" % c)
        if w not in dict(wls):
            refuse("BL-TARGETS: workload %s is not in workloads.tsv" % w)
    frozen_wls = sorted({w for _, w in frozen})
    if not frozen_wls:
        refuse("BL-TARGETS: no cell rows")
    for c in cells:
        for w in frozen_wls:
            if (c, w) not in frozen:
                refuse("BL-TARGETS: cell %s has no frozen %s row: a baseline class is "
                       "never dropped" % (c, w))
    if coverage != "%d cells" % len(cells):
        refuse("BL-TARGETS: coverage %r, expected '%d cells'" % (coverage, len(cells)))
    platforms = []
    for c in cells:
        p = c.split("/")[0]
        if p not in platforms:
            platforms.append(p)
    for p in platforms:
        for w in frozen_wls:
            if (p, w) not in targets:
                refuse("BL-TARGETS: platform %s has no %s target" % (p, w))
    for p, w in targets:
        if p not in platforms or w not in frozen_wls:
            refuse("BL-TARGETS: target %s/%s matches no frozen cell row" % (p, w))
    per_platform = {p: sum(1 for c in cells if c.startswith(p + "/")) * len(PROBLEM)
                    for p in platforms}
    if len(set(per_platform.values())) != 1:
        refuse("platforms have different cell counts: %r" % per_platform)

    out = []
    add = out.append
    add("# Performance acceptance manifest (sub-plan 05, Task 1.1; ARCH-09, DEC-001).")
    add("# GENERATED by `python3 tests/reports/perf-acceptance.py derive <receipt>/BL-TARGETS.txt`")
    add("# from the frozen baseline receipt named below, tests/manifests/matrix.tsv and")
    add("# tests/manifests/workloads.tsv. Never edit by hand: check-manifest, compare and")
    add("# summarize re-derive it from the receipt and refuse any difference. It tightens the")
    add("# receipt's rules and never drops a frozen class; its two relaxations are named in")
    add("# the rules below, each with its decision (DEC-013: warm's absolute p95 target is")
    add("# context, and a check has no warm latency gate; DEC-014: restart may satisfy the")
    add("# improvement rule).")
    add("# Rows (tab-separated), parsed as data by tests/reports/perf-acceptance.py:")
    add("#   provenance <key> <value>        receipt id and sha256 of its BL-TARGETS.txt")
    add("#   rule       <name> <text>        frozen rules verbatim, then this task's tightenings")
    add("#   method     <key> <value>        statistics and interleaving parameters")
    add("#   workload   <name> <cache_class> problem|steady")
    add("#   limit      <cell> <workload> source=frozen|same-session budget=<min per arm>")
    add("#              timeouts=<k/n>|arm failures=<k/n>|arm [frozen percentiles]")
    add("#   target     <platform> <workload> frozen platform targets")
    add("#   unmeasured <class> <reason>     a class the sample schema cannot separate")
    add("provenance\tschema\t%s" % MANIFEST_SCHEMA)
    add("provenance\tbaseline_receipt\t%s" % receipt)
    add("provenance\tbl_targets_sha256\t%s" % sha256(bl_path))
    add("provenance\tbl_targets_coverage\t%s" % coverage)
    for name, text in rules:
        add("rule\t%s\t%s" % (name, text))
    add("rule\tno-failure-regression\ttightening: per cell and workload, the candidate failure "
        "count (timeout, SERVFAIL, REFUSED, error) must not exceed the baseline failure rate "
        "either, so timeouts traded for fast failures never pass")
    add("rule\tsame-session-baseline\ta workload without a frozen row is compared with a baseline "
        "arm measured interleaved in the same session; in a comparison without that arm it is blocked; "
        "a check (DEC-012: a cell judged from its candidate samples alone) reports it unbaselined, names "
        "it on the cell row and does not gate it: its timeouts and latency are judged only on the "
        "platform's representative cell")
    add("rule\trestart-first-answer\tDEC-014: the time from a stack restart to the first answered query "
        "is a problem class, one sample per arm at every arm swap; the frozen Linux cold class came from "
        "lookups right after an install, which a steady cold name no longer reproduces; it has no frozen "
        "row, so it is held to its same-session arm; an improved restart satisfies improve-problem-class, "
        "which the frozen rule's text (cold/idle/post-wake) does not name")
    add("rule\tno-problem-class-slowdown\ttightening: a cold/idle/wake/restart class whose candidate median "
        "is slower beyond measured variability fails, so one problem class is never bought with "
        "another; warm is held to the same test against its same-session arm (DEC-013)")
    add("rule\tplatform-target\tper cell, the candidate p95_all_us of a frozen problem class must not "
        "exceed its platform target; warm's target is reported as context, never gated (DEC-013: the "
        "baseline arm itself missed it on 2026-09-28)")
    add("rule\tsample-budget\tan arm below its budget is insufficient, never pass")
    add("rule\tinterleaved-arms\tbaseline and candidate arms of one workload alternate in time: "
        "ordered by utc_start, no same-arm run exceeds ceil(n_arm/min_blocks) samples and each arm "
        "forms at least min(min_blocks, n_arm) runs; otherwise the comparison is refused")
    add("rule\tseparate-classes\tone cache_class per workload, never pooled; NXDOMAIN answers are "
        "answered queries and their share is reported per arm")
    add("method\timprovement\tblock-paired: the alternating same-arm runs by utc_start are blocks "
        "(samples of one block share a stack restart and a set of circuits, so the block is the "
        "independent unit; DEC-015); per block the nearest-rank median, every failed attempt worst "
        "(+inf); gain = baseline minus candidate per paired block; exact Wilcoxon signed-rank over "
        "the sign assignments of the observed ranks (zeros dropped, ties share the average rank)")
    add("method\tpooled_context\tthe exact percentile bootstrap of the difference of pooled "
        "medians (samples as if independent) is reported as gain_lo_us/gain_hi_us/p_not_better, "
        "never as a verdict")
    add("method\talpha_family\t%s" % ALPHA_FAMILY)
    add("method\tcomparisons_per_platform\t%d" % next(iter(per_platform.values())))
    add("method\timproved_when\tp_block_better < alpha_family/comparisons_per_platform "
        "(one-sided, Bonferroni over every cell x problem class of a platform); with n paired "
        "blocks the smallest possible p is 2^-n, so an improvement needs at least 9 blocks")
    add("method\tslower_when\tp_block_worse < alpha_family/comparisons_per_platform")
    add("method\tmin_blocks\t%d" % MIN_BLOCKS)
    add("method\trate_interval\tWilson score 95%")
    add("method\tpercentile_support\ttests/reports/stats.sh: supported when "
        "attempted*(100-p)/100 >= 10, else exploratory")
    for w, cls in wls:
        add("workload\t%s\t%s\t%s" % (w, cls, "problem" if w in PROBLEM else "steady"))
    for c in cells:
        for w, _ in wls:
            if (c, w) in frozen:
                d = frozen[(c, w)]
                n = int(d["attempted"])
                add("limit\t%s\t%s\tsource=frozen\tbudget=%d\ttimeouts=%d/%d\tfailures=%d/%d\t"
                    "p50_all_us=%s\tp95_all_us=%s\tp99_all_us=%s\tp95_support=%s"
                    % (c, w, max(MIN_BUDGET[w], n), d["timeouts"], n, d["failures"], n,
                       d["p50_all_us"], d["p95_all_us"], d["p99_all_us"], d["p95_support"]))
            else:
                add("limit\t%s\t%s\tsource=same-session\tbudget=%d\ttimeouts=arm\tfailures=arm"
                    % (c, w, MIN_BUDGET[w]))
    for p in platforms:
        for w in frozen_wls:
            d = targets[(p, w)]
            add("target\t%s\t%s\ttimeout_rate_max=%s\tp95_all_us_max=%s"
                % (p, w, d["timeout_rate_max"], d["p95_all_us_max"]))
    add("unmeasured\tstale\tnice-dns-sample/1 has no stale-answer marker (no TTL, EDE or flag "
        "column): a serve-stale answer is indistinguishable from a fresh one, so no stale "
        "class is measured or claimed")
    return "\n".join(out) + "\n"


# ─────────────────────────── manifest ───────────────────────────


def artifact_root():
    r = os.environ.get("NICE_DNS_TEST_ARTIFACTS")
    if r:
        return r
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "nice-dns-tests")


def load_manifest(path, bl_path):
    """Verify path equals a fresh derivation; return parsed rows."""
    if not os.path.isfile(path):
        refuse("manifest not found: %s" % path)
    text = open(path).read()
    rows = [l.split("\t") for l in text.splitlines() if l and not l.startswith("#")]
    prov = {r[1]: r[2] for r in rows if r[0] == "provenance" and len(r) == 3}
    rid = prov.get("baseline_receipt", "")
    if not rid or "/" in rid or rid.startswith("."):
        refuse("%s: no usable provenance baseline_receipt" % path)
    if bl_path is None:
        bl_path = os.path.join(artifact_root(), "receipts", "baseline", rid, "BL-TARGETS.txt")
    if not os.path.isfile(bl_path):
        refuse("frozen baseline receipt %s not found at %s: the manifest cannot be verified "
               "(BLOCKED)" % (rid, bl_path))
    if os.path.basename(os.path.dirname(os.path.abspath(bl_path))) != rid:
        refuse("%s is not receipt %s named by the manifest" % (bl_path, rid))
    if sha256(bl_path) != prov.get("bl_targets_sha256"):
        refuse("sha256 of %s does not match the manifest's bl_targets_sha256: the frozen "
               "receipt changed or is another one" % bl_path)
    fresh = derive(bl_path)
    if fresh != text:
        a, b = text.splitlines(), fresh.splitlines()
        i = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
        raise Mismatch("%s differs from a fresh derivation of %s at line %d:\n  manifest: %s\n"
                       "  derived:  %s" % (path, bl_path, i + 1, a[i] if i < len(a) else "<end>",
                                           b[i] if i < len(b) else "<end>"))
    m = {"text": text, "sha256": hashlib.sha256(text.encode()).hexdigest(), "prov": prov,
         "method": {}, "workloads": [], "limits": {}, "targets": {}, "cells": [],
         "unmeasured": []}
    for r in rows:
        if r[0] == "method":
            m["method"][r[1]] = r[2]
        elif r[0] == "workload":
            m["workloads"].append((r[1], r[2], r[3]))
        elif r[0] == "limit":
            m["limits"][(r[1], r[2])] = kv(r[3:], "manifest limit")
            if r[1] not in m["cells"]:
                m["cells"].append(r[1])
        elif r[0] == "target":
            m["targets"][(r[1], r[2])] = kv(r[3:], "manifest target")
        elif r[0] == "unmeasured":
            m["unmeasured"].append((r[1], r[2]))
    return m


class Mismatch(Exception):
    pass


# ─────────────────────────── samples ───────────────────────────


def parse_utc(s, where):
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return datetime.datetime.strptime(s, fmt)
        except ValueError:
            pass
    refuse("%s: utc_start %r is not an ISO UTC stamp" % (where, s))


def load_arm(path, label, cell):
    if not os.path.isfile(path):
        refuse("%s arm: no such file %s" % (label, path))
    p = subprocess.run(["bash", STATS, path], capture_output=True, text=True)
    if p.returncode != 0:
        refuse("%s arm %s refused by stats.sh: %s" % (label, path, p.stderr.strip()))
    stats = {}
    lines = p.stdout.splitlines()
    head = lines[0].split("\t")
    for l in lines[1:]:
        f = l.split("\t")
        stats[f[0]] = dict(zip(head, f))
    rows, cols = [], None
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#"):
                continue
            if cols is None:
                cols = line.split("\t")
                continue
            rows.append(dict(zip(cols, line.split("\t"))))
    platform, proxy, pihole = cell.split("/")
    prev = None
    for r in rows:
        where = "%s arm %s sample %s" % (label, path, r["sample_id"])
        if (r["platform"], r["proxy"], r["pihole"]) != (platform, proxy, pihole):
            refuse("%s: belongs to %s/%s/%s, not cell %s"
                   % (where, r["platform"], r["proxy"], r["pihole"], cell))
        r["t"] = parse_utc(r["utc_start"], where)
        if prev is not None and r["t"] < prev:
            refuse("%s: utc_start goes backwards (clock step?); interleaving cannot be "
                   "established" % where)
        prev = r["t"]
        r["answered"] = r["outcome"] in ("ok", "nxdomain")
        r["v"] = float(r["elapsed_us"]) if r["answered"] else INF
    return {"path": path, "rows": rows, "stats": stats, "run_id": rows[0]["run_id"],
            "source_rev": rows[0]["source_rev"], "images": rows[0]["images"],
            "target_id": rows[0]["target_id"]}


def check_interleaved(w, b, c):
    merged = sorted([(r["t"], 0) for r in b] + [(r["t"], 1) for r in c])
    runs = []
    for _, arm in merged:
        if runs and runs[-1][0] == arm:
            runs[-1][1] += 1
        else:
            runs.append([arm, 1])
    blocks = [0, 0]
    for arm, length in runs:
        n = len(b) if arm == 0 else len(c)
        bound = -(-n // MIN_BLOCKS)
        if length > bound:
            refuse("workload %s: arms are not interleaved: a run of %d %s samples exceeds "
                   "ceil(%d/%d)=%d" % (w, length, ("baseline", "candidate")[arm], n,
                                       MIN_BLOCKS, bound))
        blocks[arm] += 1
    for arm, n in ((0, len(b)), (1, len(c))):
        if blocks[arm] < min(MIN_BLOCKS, n):
            refuse("workload %s: arms are not interleaved: the %s arm forms %d runs, fewer "
                   "than %d" % (w, ("baseline", "candidate")[arm], blocks[arm], min(MIN_BLOCKS, n)))
    return blocks


def paired_blocks(w, b, c):
    """The alternating same-arm runs by utc_start, paired in order: block k of
    the baseline with block k of the candidate. Samples of one block share a
    stack restart and a set of Tor circuits, so the block, not the sample, is
    the independent unit (Stage 1 gate, DEC-015)."""
    merged = sorted([(r["t"], 0, r["v"]) for r in b] + [(r["t"], 1, r["v"]) for r in c])
    runs = [[], []]
    last = None
    for _, arm, v in merged:
        if arm != last:
            runs[arm].append([])
            last = arm
        runs[arm][-1].append(v)
    if len(runs[0]) != len(runs[1]):
        refuse("workload %s: the arms form %d and %d blocks; a block-paired test needs equal "
               "counts" % (w, len(runs[0]), len(runs[1])))
    return list(zip(runs[0], runs[1]))


def signed_rank(ds):
    """Exact Wilcoxon signed-rank over paired block gains (baseline minus
    candidate medians): (P(T+ >= observed), P(T- >= observed)) under sign
    flips of the observed ranks. Zeros are dropped, tied magnitudes share the
    average rank, +/-inf rank above every finite value. No pairs left: (1, 1)."""
    ds = [d for d in ds if d != 0]
    n = len(ds)
    if n == 0:
        return 1.0, 1.0
    mags = sorted(set(abs(d) for d in ds))
    pos = {}
    k = 0
    for m in mags:
        cnt = sum(1 for d in ds if abs(d) == m)
        pos[m] = k + (cnt + 1) / 2.0
        k += cnt
    ranks = [pos[abs(d)] for d in ds]
    tplus = sum(r for r, d in zip(ranks, ds) if d > 0)
    tminus = sum(r for r, d in zip(ranks, ds) if d < 0)
    # Distribution of T+ over the 2^n sign assignments (ranks doubled: integers).
    dist = {0: 1}
    for r in ranks:
        r2 = int(round(2 * r))
        nd = {}
        for t, cnt in dist.items():
            nd[t] = nd.get(t, 0) + cnt
            nd[t + r2] = nd.get(t + r2, 0) + cnt
        dist = nd
    total = float(2 ** n)
    ge = lambda x: sum(cnt for t, cnt in dist.items() if t >= int(round(2 * x))) / total
    return ge(tplus), ge(tminus)


# ─────────────────────────── statistics ───────────────────────────


def nearest_rank(vals, p):
    s = sorted(vals)
    r = max(1, (p * len(s) + 99) // 100)
    return s[r - 1]


def median_bootstrap(vals):
    """Exact bootstrap distribution of the nearest-rank median: [(value, mass)]."""
    n = len(vals)
    r = max(1, (50 * n + 99) // 100)
    lf = [0.0] * (n + 1)
    for k in range(2, n + 1):
        lf[k] = lf[k - 1] + math.log(k)

    def tail(p):  # P(Binomial(n, p) >= r)
        if p >= 1.0:
            return 1.0
        lp, lq = math.log(p), math.log1p(-p)
        s = 0.0
        for k in range(r, n + 1):
            s += math.exp(lf[n] - lf[k] - lf[n - k] + k * lp + (n - k) * lq)
        return min(1.0, s)

    xs = sorted(vals)
    out, prev, i = [], 0.0, 0
    while i < n:
        j = i
        while j < n and xs[j] == xs[i]:
            j += 1
        F = tail(j / n)
        if F - prev > 0:
            out.append((xs[i], F - prev))
        prev, i = F, j
    return out


def gain(b, c):
    if b == c:
        return 0.0
    return b - c  # +inf - finite = inf; finite - inf = -inf


def gain_distribution(bvals, cvals):
    B, C = median_bootstrap(bvals), median_bootstrap(cvals)
    pairs = []
    for bv, bm in B:
        if bm < 1e-15:
            continue
        for cv, cm in C:
            m = bm * cm
            if m >= 1e-18:
                pairs.append((gain(bv, cv), m))
    pairs.sort()
    total = sum(m for _, m in pairs)
    return [(d, m / total) for d, m in pairs]


def quantile(dist, a):
    cum = 0.0
    for d, m in dist:
        cum += m
        if cum >= a:
            return d
    return dist[-1][0]


def wilson(k, n, z=1.959964):
    c = (k + z * z / 2) / (n + z * z)
    h = z * math.sqrt(k * (n - k) / n + z * z / 4) / (n + z * z)
    return "%.4f-%.4f" % (max(0.0, c - h), min(1.0, c + h))


def fmt_us(v):
    if v == INF:
        return "inf"
    if v == -INF:
        return "-inf"
    return "%d" % round(v)


def ratio(s):
    k, n = s.split("/")
    return int(k), int(n)


def not_above(k, n, lk, ln):
    """k/n <= lk/ln, exactly."""
    return k * ln <= lk * n


# ─────────────────────────── compare ───────────────────────────


def compare(m, cell, base, cand, scope=None):
    """scope: the workloads judged (DEC-012: a tuning attempt interleaves cold and
    warm only); the others are `deferred` and the cell row names the scope, so
    summarize never takes it for the cell's result."""
    if cell not in m["cells"]:
        refuse("cell %s is not in the manifest" % cell)
    names = [w for w, _, _ in m["workloads"]]
    if scope is not None:
        unknown = [w for w in scope if w not in names]
        if unknown or not scope:
            refuse("--workloads names unknown workloads: %s" % ",".join(unknown))
    B = load_arm(base, "baseline", cell)
    C = load_arm(cand, "candidate", cell)
    if B["run_id"] == C["run_id"]:
        refuse("both arms are run %s: a comparison needs two runs" % B["run_id"])
    alpha = float(m["method"]["alpha_family"]) / int(m["method"]["comparisons_per_platform"])
    platform = cell.split("/")[0]
    out = ["# schema\t%s" % RESULT_SCHEMA,
           "provenance\tbaseline_receipt=%s\tbl_targets_sha256=%s\tmanifest_sha256=%s"
           % (m["prov"]["baseline_receipt"], m["prov"]["bl_targets_sha256"], m["sha256"])]
    for label, A in (("baseline", B), ("candidate", C)):
        out.append("arm\t%s\trun_id=%s\tsource_rev=%s\timages=%s\ttarget_id=%s\tsamples=%d\tfile=%s"
                   % (label, A["run_id"], A["source_rev"], A["images"], A["target_id"],
                      len(A["rows"]), os.path.basename(A["path"])))
    known = {w for w, _, _ in m["workloads"]}
    verdicts, improved = [], []
    # Refusals first, for every workload, before any verdict is printed.
    per = {}
    for w, cls, kind in m["workloads"]:
        if scope is not None and w not in scope:
            continue
        b = [r for r in B["rows"] if r["workload"] == w]
        c = [r for r in C["rows"] if r["workload"] == w]
        for label, rows in (("baseline", b), ("candidate", c)):
            bad = sorted({r["cache_class"] for r in rows} - {cls})
            if bad:
                refuse("workload %s: %s arm has cache_class %s where the manifest has %s; "
                       "classes are never pooled" % (w, label, ",".join(bad), cls))
        if b and c:
            for k in CONTROLS:
                vals = sorted({r[k] for r in b + c})
                if len(vals) != 1:
                    refuse("workload %s: arms differ in %s (%s): not the same controlled "
                           "workload" % (w, k, ",".join(vals)))
            blocks = check_interleaved(w, b, c)
        else:
            blocks = [0, 0]
        per[w] = (b, c, blocks)
    for w, cls, kind in m["workloads"]:
        if scope is not None and w not in scope:
            verdicts.append("deferred")
            out.append("workload\t%s\t%s\tdeferred\treason=outside this comparison's scope (%s)"
                       % (cell, w, ",".join(scope)))
            continue
        b, c, blocks = per[w]
        lim = m["limits"][(cell, w)]
        budget = int(lim["budget"])
        f = {"class": cls, "source": lim["source"], "n_base": str(len(b)), "n_cand": str(len(c)),
             "budget": str(budget)}
        reason = []
        if not b or not c:
            verdict = "blocked"
            if not b:
                reason.append("no same-session baseline arm rows for %s" % w)
            if not c:
                reason.append("no candidate rows for %s" % w)
        else:
            tb = sum(r["outcome"] == "timeout" for r in b)
            tc = sum(r["outcome"] == "timeout" for r in c)
            fb = sum(not r["answered"] for r in b)
            fc = sum(not r["answered"] for r in c)
            nxb = sum(r["outcome"] == "nxdomain" for r in b)
            nxc = sum(r["outcome"] == "nxdomain" for r in c)
            if lim["source"] == "frozen":
                tlim, flim = ratio(lim["timeouts"]), ratio(lim["failures"])
            else:
                tlim, flim = (tb, len(b)), (fb, len(b))
            f.update({"timeouts_base": "%d/%d" % (tb, len(b)), "timeouts_cand": "%d/%d" % (tc, len(c)),
                      "timeout_rate_cand": "%.4f" % (tc / len(c)),
                      "timeout_ci95_cand": wilson(tc, len(c)),
                      "timeout_limit": "%d/%d" % tlim,
                      "timeout": "pass" if not_above(tc, len(c), *tlim) else "fail",
                      "failures_base": "%d/%d" % (fb, len(b)), "failures_cand": "%d/%d" % (fc, len(c)),
                      "failure_ci95_cand": wilson(fc, len(c)),
                      "failure_limit": "%d/%d" % flim,
                      "failure": "pass" if not_above(fc, len(c), *flim) else "fail",
                      "nx_base": "%d/%d" % (nxb, len(b)), "nx_cand": "%d/%d" % (nxc, len(c))})
            bv, cv = [r["v"] for r in b], [r["v"] for r in c]
            dist = gain_distribution(bv, cv)
            p_not_better = sum(mm for d, mm in dist if d <= 0)
            p_not_worse = sum(mm for d, mm in dist if d >= 0)
            is_problem = kind == "problem"
            # The verdicts come from the block-paired test; the pooled
            # bootstrap (samples as if independent) is reported as context.
            pairs = paired_blocks(w, b, c)
            ds = [gain(nearest_rank(pb, 50), nearest_rank(pc, 50)) for pb, pc in pairs]
            p_better, p_worse = signed_rank(ds)
            f.update({"p50_base": fmt_us(nearest_rank(bv, 50)), "p50_cand": fmt_us(nearest_rank(cv, 50)),
                      "gain_us": fmt_us(gain(nearest_rank(bv, 50), nearest_rank(cv, 50))),
                      "gain_lo_us": fmt_us(quantile(dist, alpha)),
                      "gain_hi_us": fmt_us(quantile(dist, 1 - alpha)),
                      "alpha": "%.6f" % alpha,
                      "p_not_better": "%.6f" % p_not_better,
                      "pooled_p_not_worse": "%.6f" % p_not_worse,
                      "blocks_paired": str(len(pairs)),
                      "blocks_better": str(sum(d > 0 for d in ds)),
                      "blocks_worse": str(sum(d < 0 for d in ds)),
                      "p_block_better": "%.6f" % p_better,
                      "p_block_worse": "%.6f" % p_worse,
                      "improvement": ("yes" if p_better < alpha else "no") if is_problem else "n/a",
                      "latency": "slower" if p_worse < alpha else "ok"})
            sb, sc = B["stats"][w], C["stats"][w]
            f.update({"p95_base": sb["p95_all_us"], "p95_cand": sc["p95_all_us"],
                      "p95_support_cand": sc["p95_support"], "p99_base": sb["p99_all_us"],
                      "p99_cand": sc["p99_all_us"], "p99_support_cand": sc["p99_support"]})
            tgt = m["targets"].get((platform, w))
            if tgt:
                mx = tgt["p95_all_us_max"]
                ok = mx == "inf" or (sc["p95_all_us"] != "inf" and int(sc["p95_all_us"]) <= int(mx))
                # DEC-013: warm's absolute target is context; the baseline arm
                # measured alongside is its reference (the slowdown test below).
                if is_problem:
                    f.update({"p95_target": mx, "target": "pass" if ok else "fail"})
                else:
                    f.update({"p95_target": mx, "target": "context:within" if ok else "context:over"})
            else:
                f.update({"p95_target": "n/a", "target": "n/a"})
            f.update({"blocks_base": str(blocks[0]), "blocks_cand": str(blocks[1])})
            if len(b) < budget or len(c) < budget:
                verdict = "insufficient"
                reason.append("arm below the budget of %d (baseline %d, candidate %d)"
                              % (budget, len(b), len(c)))
            else:
                failed = [k for k in ("timeout", "failure", "target") if f[k] == "fail"]
                # Every workload is held to the arm measured alongside it: the
                # problem classes (Task 1.1) and warm (DEC-013).
                if f["latency"] == "slower":
                    failed.append("slower")
                verdict = "fail" if failed else "pass"
                if failed:
                    reason.append("failed: " + ",".join(failed))
                if verdict == "pass" and f["improvement"] == "yes":
                    improved.append(w)
        f["reason"] = "; ".join(reason) if reason else "-"
        verdicts.append(verdict)
        out.append("workload\t%s\t%s\t%s\t%s" % (cell, w, verdict,
                                                 "\t".join("%s=%s" % kv_ for kv_ in f.items())))
    for w in sorted({r["workload"] for r in B["rows"] + C["rows"]} - known):
        out.append("ignored\t%s\t%s\tnot a manifest workload" % (cell, w))
    for cls, why in m["unmeasured"]:
        out.append("unmeasured\t%s\t%s" % (cls, why))
    cell_v = next((v for v in ("fail", "blocked", "insufficient") if v in verdicts), "pass")
    row = "cell\t%s\t%s\timproved=%s" % (cell, cell_v, ",".join(improved) or "none")
    if scope is not None:
        row += "\tscope=%s" % ",".join(scope)
    out.append(row)
    return "\n".join(out) + "\n", cell_v == "pass"


# ─────────────────────────── check (DEC-012) ───────────────────────────


def check(m, cell, cand):
    """One cell from its candidate samples alone, against the frozen limits.

    DEC-012: every cell is held to no regression against the frozen receipt;
    the improvement is proven by `compare` on one representative cell per
    platform. A workload without a frozen limit (idle, wake) is reported
    `unbaselined`: measured, never gated here, never a pass either.
    """
    if cell not in m["cells"]:
        refuse("cell %s is not in the manifest" % cell)
    C = load_arm(cand, "candidate", cell)
    platform = cell.split("/")[0]
    out = ["# schema\t%s" % RESULT_SCHEMA,
           "provenance\tbaseline_receipt=%s\tbl_targets_sha256=%s\tmanifest_sha256=%s"
           % (m["prov"]["baseline_receipt"], m["prov"]["bl_targets_sha256"], m["sha256"]),
           "mode\tcheck\tfrozen limits only (DEC-012); no baseline arm, no improvement claim",
           "arm\tcandidate\trun_id=%s\tsource_rev=%s\timages=%s\ttarget_id=%s\tsamples=%d\tfile=%s"
           % (C["run_id"], C["source_rev"], C["images"], C["target_id"], len(C["rows"]),
              os.path.basename(C["path"]))]
    known = {w for w, _, _ in m["workloads"]}
    verdicts = []
    for w, cls, kind in m["workloads"]:
        c = [r for r in C["rows"] if r["workload"] == w]
        bad = sorted({r["cache_class"] for r in c} - {cls})
        if bad:
            refuse("workload %s: candidate arm has cache_class %s where the manifest has %s; "
                   "classes are never pooled" % (w, ",".join(bad), cls))
    for w, cls, kind in m["workloads"]:
        c = [r for r in C["rows"] if r["workload"] == w]
        lim = m["limits"][(cell, w)]
        budget = int(lim["budget"])
        f = {"class": cls, "source": lim["source"], "n_cand": str(len(c)), "budget": str(budget)}
        reason = []
        if not c:
            verdict = "blocked"
            reason.append("no candidate rows for %s" % w)
        else:
            tc = sum(r["outcome"] == "timeout" for r in c)
            fc = sum(not r["answered"] for r in c)
            nxc = sum(r["outcome"] == "nxdomain" for r in c)
            sc = C["stats"][w]
            f.update({"timeouts_cand": "%d/%d" % (tc, len(c)), "timeout_ci95_cand": wilson(tc, len(c)),
                      "failures_cand": "%d/%d" % (fc, len(c)), "failure_ci95_cand": wilson(fc, len(c)),
                      "nx_cand": "%d/%d" % (nxc, len(c)),
                      "p50_cand": fmt_us(nearest_rank([r["v"] for r in c], 50)),
                      "p95_cand": sc["p95_all_us"], "p95_support_cand": sc["p95_support"],
                      "p99_cand": sc["p99_all_us"], "p99_support_cand": sc["p99_support"]})
            if lim["source"] != "frozen":
                verdict = "unbaselined"
                reason.append("no frozen limit; its baseline arm is measured on the platform's "
                              "representative cell (DEC-012)")
            else:
                tlim, flim = ratio(lim["timeouts"]), ratio(lim["failures"])
                f.update({"timeout_limit": "%d/%d" % tlim,
                          "timeout": "pass" if not_above(tc, len(c), *tlim) else "fail",
                          "failure_limit": "%d/%d" % flim,
                          "failure": "pass" if not_above(fc, len(c), *flim) else "fail"})
                tgt = m["targets"].get((platform, w))
                if tgt:
                    mx = tgt["p95_all_us_max"]
                    ok = mx == "inf" or (sc["p95_all_us"] != "inf" and int(sc["p95_all_us"]) <= int(mx))
                    if kind == "problem":
                        f.update({"p95_target": mx, "target": "pass" if ok else "fail"})
                    else:  # DEC-013: context, never a gate
                        f.update({"p95_target": mx, "target": "context:within" if ok else "context:over"})
                else:
                    f.update({"p95_target": "n/a", "target": "n/a"})
                if len(c) < budget:
                    verdict = "insufficient"
                    reason.append("below the budget of %d (%d)" % (budget, len(c)))
                else:
                    failed = [k for k in ("timeout", "failure", "target") if f[k] == "fail"]
                    verdict = "fail" if failed else "pass"
                    if failed:
                        reason.append("failed: " + ",".join(failed))
        f["reason"] = "; ".join(reason) if reason else "-"
        verdicts.append(verdict)
        out.append("workload\t%s\t%s\t%s\t%s" % (cell, w, verdict,
                                                 "\t".join("%s=%s" % kv_ for kv_ in f.items())))
    for w in sorted({r["workload"] for r in C["rows"]} - known):
        out.append("ignored\t%s\t%s\tnot a manifest workload" % (cell, w))
    for cls, why in m["unmeasured"]:
        out.append("unmeasured\t%s\t%s" % (cls, why))
    cell_v = next((v for v in ("fail", "blocked", "insufficient") if v in verdicts), "pass")
    # A check gates the frozen workloads only (DEC-012); the cell row names
    # the ones it measured without judging, so a pass is never read as theirs.
    ungated = [w for (w, _, _), v in zip(m["workloads"], verdicts) if v == "unbaselined"]
    out.append("cell\t%s\t%s\timproved=none\tunbaselined=%s" % (cell, cell_v, ",".join(ungated) or "none"))
    return "\n".join(out) + "\n", cell_v == "pass"


# ─────────────────────────── summarize ───────────────────────────


def summarize(m, platforms, results):
    got = {}
    for path in results:
        if not os.path.isfile(path):
            refuse("no such result file: %s" % path)
        lines = open(path).read().splitlines()
        if not lines or lines[0] != "# schema\t%s" % RESULT_SCHEMA:
            refuse("%s: not a %s result" % (path, RESULT_SCHEMA))
        prov = [l for l in lines if l.startswith("provenance\t")]
        if len(prov) != 1 or "manifest_sha256=%s" % m["sha256"] not in prov[0].split("\t"):
            refuse("%s: compared against another manifest" % path)
        cells = [l.split("\t") for l in lines if l.startswith("cell\t")]
        if len(cells) != 1:
            refuse("%s: expected one cell row" % path)
        c = cells[0]
        if any(x.startswith("scope=") for x in c[4:]):
            refuse("%s: a scoped comparison (%s) is never a cell's result" % (path, c[-1]))
        if c[1] in got:
            refuse("cell %s has two results" % c[1])
        got[c[1]] = (c[2], c[3][len("improved="):])
    all_p = []
    for c in m["cells"]:
        p = c.split("/")[0]
        if p not in all_p:
            all_p.append(p)
    for p in platforms:
        if p not in all_p:
            refuse("platform %s is not in the manifest" % p)
    out, ok = [], True
    for p in platforms or all_p:
        cells = [c for c in m["cells"] if c.startswith(p + "/")]
        have = [c for c in cells if c in got]
        vs = [got[c][0] for c in have]
        imp = ["%s:%s" % (c, w) for c in have for w in got[c][1].split(",") if w != "none"]
        missing = [c for c in cells if c not in got]
        if "fail" in vs:
            v, why = "fail", "a cell failed"
        elif missing or "blocked" in vs:
            v, why = "blocked", ("missing " + ",".join(missing)) if missing else "a cell is blocked"
        elif "insufficient" in vs:
            v, why = "insufficient", "a cell is below its sample budget"
        elif not imp:
            v, why = "fail", "no problem class (cold/idle/wake/restart) improved beyond measured variability"
        else:
            v, why = "pass", "-"
        ok = ok and v == "pass"
        out.append("platform\t%s\t%s\tcells=%d/%d\timproved=%s\treason=%s"
                   % (p, v, len(have), len(cells), ",".join(imp) or "none", why))
    return "\n".join(out) + "\n", ok


# ─────────────────────────── main ───────────────────────────


def opts(argv, names, multi=()):
    d, rest = {k: None for k in names}, []
    for k in multi:
        d[k] = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            k = a[2:]
            if k not in d or i + 1 >= len(argv):
                refuse("unknown option or missing value: %s" % a)
            if k in multi:
                d[k].append(argv[i + 1])
            else:
                d[k] = argv[i + 1]
            i += 2
        else:
            rest.append(a)
            i += 1
    return d, rest


def verified_manifest(o):
    """For compare/summarize an unverifiable manifest is a refusal, not a diff."""
    try:
        return load_manifest(o["manifest"] or DEFAULT_MANIFEST, o["bl-targets"])
    except Mismatch as e:
        refuse(str(e))


def main(argv):
    if not argv:
        refuse("usage: perf-acceptance.py derive|check-manifest|compare|check|summarize ...")
    cmd, args = argv[0], argv[1:]
    if cmd == "derive":
        if len(args) != 1:
            refuse("usage: derive BL-TARGETS.txt")
        sys.stdout.write(derive(args[0]))
        return 0
    if cmd == "check-manifest":
        o, rest = opts(args, ("manifest", "bl-targets"))
        if rest:
            refuse("check-manifest takes no operands")
        m = load_manifest(o["manifest"] or DEFAULT_MANIFEST, o["bl-targets"])
        print("manifest ok: receipt %s sha256 %s" % (m["prov"]["baseline_receipt"],
                                                      m["prov"]["bl_targets_sha256"]))
        return 0
    if cmd == "compare":
        o, rest = opts(args, ("manifest", "bl-targets", "cell", "baseline", "candidate", "workloads"))
        if rest or not (o["cell"] and o["baseline"] and o["candidate"]):
            refuse("usage: compare [--manifest M] [--bl-targets F] --cell C --baseline A --candidate B [--workloads W,W]")
        m = verified_manifest(o)
        scope = [w for w in o["workloads"].split(",")] if o["workloads"] else None
        text, ok = compare(m, o["cell"], o["baseline"], o["candidate"], scope)
        sys.stdout.write(text)
        return 0 if ok else 1
    if cmd == "check":
        o, rest = opts(args, ("manifest", "bl-targets", "cell", "candidate"))
        if rest or not (o["cell"] and o["candidate"]):
            refuse("usage: check [--manifest M] [--bl-targets F] --cell C --candidate B")
        m = verified_manifest(o)
        text, ok = check(m, o["cell"], o["candidate"])
        sys.stdout.write(text)
        return 0 if ok else 1
    if cmd == "summarize":
        o, rest = opts(args, ("manifest", "bl-targets", "platform"), multi=("platform",))
        if not rest:
            refuse("usage: summarize [--manifest M] [--bl-targets F] [--platform P]... RESULT...")
        m = verified_manifest(o)
        text, ok = summarize(m, o["platform"], rest)
        sys.stdout.write(text)
        return 0 if ok else 1
    refuse("unknown command %s" % cmd)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Mismatch as e:
        print("perf-acceptance: %s" % e, file=sys.stderr)
        sys.exit(1)
    except Refused as e:
        print("perf-acceptance: %s" % e, file=sys.stderr)
        sys.exit(2)
