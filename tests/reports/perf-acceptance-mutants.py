#!/usr/bin/env python3
"""Per-guard mutant battery for tests/reports/perf-acceptance.py.

Maintainer tool (sub-plan 05, Task 1.1), not a test group: it edits
perf-acceptance.py in place, one guard at a time, runs
`unit performance-acceptance`, and restores the file (also on error or
Ctrl-C). Each guard must turn at least one case red; a guard no case notices
is untested or dead.

Usage: python3 tests/reports/perf-acceptance-mutants.py [GUARD...]
Exit: 0 every guard is caught; 1 some guard is not; 2 a mutation no longer
applies (the guard's code changed: update the list below).
"""
import os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUNNER = os.path.join(ROOT, "tests", "run.sh")
TOOL = os.path.join(ROOT, "tests", "reports", "perf-acceptance.py")

G = [
 ("drop-frozen-class", '            if (c, w) not in frozen:\n                refuse("BL-TARGETS: cell', '            if False:\n                refuse("BL-TARGETS: cell'),
 ("rate-not-count", '    if not 0 <= k <= n or "%.4f" % (k / n) != rate:', '    if not 0 <= k <= n:'),
 ("frozen-rule-missing", '        if name not in [n for n, _ in rules]:\n            refuse("BL-TARGETS: frozen rule', '        if False:\n            refuse("BL-TARGETS: frozen rule'),
 ("coverage", '    if coverage != "%d cells" % len(cells):', '    if False:'),
 ("target-missing", '            if (p, w) not in targets:\n                refuse("BL-TARGETS: platform', '            if False:\n                refuse("BL-TARGETS: platform'),
 ("manifest-equality", '    if fresh != text:', '    if False:'),
 ("receipt-sha256", '    if sha256(bl_path) != prov.get("bl_targets_sha256"):', '    if False:'),
 ("stats-refusal", '    if p.returncode != 0:\n        refuse("%s arm %s refused by stats.sh', '    if False:\n        refuse("%s arm %s refused by stats.sh'),
 ("cell-rows", '        if (r["platform"], r["proxy"], r["pihole"]) != (platform, proxy, pihole):', '        if False:'),
 ("clock-step", '        if prev is not None and r["t"] < prev:', '        if False:'),
 ("failures-rank-worst", '        r["v"] = float(r["elapsed_us"]) if r["answered"] else INF', '        r["v"] = float(r["elapsed_us"])'),
 ("nxdomain-answered", '        r["answered"] = r["outcome"] in ("ok", "nxdomain")', '        r["answered"] = r["outcome"] in ("ok",)'),
 ("same-run", '    if B["run_id"] == C["run_id"]:', '    if False:'),
 ("cache-class-pooling", '            if bad:', '            if False:'),
 ("controls", '                if len(vals) != 1:', '                if False:'),
 ("interleave-run-length", '        if length > bound:', '        if False:'),
 ("interleave-run-count", '        if blocks[arm] < min(MIN_BLOCKS, n):', '        if False:'),
 ("blocked", '        if not b or not c:\n            verdict = "blocked"', '        if not b or not c:\n            verdict = "pass"'),
 ("check-blocked", '        if not c:\n            verdict = "blocked"', '        if not c:\n            verdict = "pass"'),
 ("frozen-limit", '            if lim["source"] == "frozen":', '            if False:'),
 ("timeout-check", '\n                      "timeout": "pass" if not_above(tc, len(c), *tlim) else "fail",', '\n                      "timeout": "pass",'),
 ("check-timeout", '\n                          "timeout": "pass" if not_above(tc, len(c), *tlim) else "fail",', '\n                          "timeout": "pass",'),
 ("failure-check", '"failure": "pass" if not_above(fc, len(c), *flim) else "fail",', '"failure": "pass",'),
 ("check-failure", '"failure": "pass" if not_above(fc, len(c), *flim) else "fail"})', '"failure": "pass"})'),
 ("improvement-alpha", '("yes" if p_better < alpha else "no")', '("yes" if p_better < 0.5 else "no")'),
 ("improvement-pooled", '("yes" if p_better < alpha else "no")', '("yes" if p_not_better < alpha else "no")'),
 ("slower-pooled", '"latency": "slower" if p_worse < alpha else "ok"', '"latency": "slower" if p_not_worse < alpha else "ok"'),
 ("unpaired-blocks", '    if len(runs[0]) != len(runs[1]):', '    if False:'),
 ("tie-rank", '        pos[m] = k + (cnt + 1) / 2.0', '        pos[m] = k + cnt'),
 ("rank-by-size", '    ranks = [pos[abs(d)] for d in ds]', '    ranks = [1.0 for d in ds]'),
 ("failed-block-worst", 'ds = [gain(nearest_rank(pb, 50), nearest_rank(pc, 50)) for pb, pc in pairs]', 'ds = [d for d in (gain(nearest_rank(pb, 50), nearest_rank(pc, 50)) for pb, pc in pairs) if abs(d) != INF]'),
 ("check-names-ungated", '",".join(ungated) or "none"', '"none"'),
 ("method-text", 'add("method\\timprovement\\tblock-paired:', 'add("method\\timprovement\\tpooled:'),
 ("check-rule-text", '"a check (DEC-012: a cell judged', '"a check (a cell judged'),
 ("bonferroni", '    alpha = float(m["method"]["alpha_family"]) / int(m["method"]["comparisons_per_platform"])', '    alpha = float(m["method"]["alpha_family"])'),
 ("problem-class-only", 'if is_problem else "n/a"', 'if True else "n/a"'),
 ("slowdown-gate", '                if f["latency"] == "slower":', '                if False:'),
 ("platform-target", '\n                ok = mx == "inf" or', '\n                ok = True or'),
 ("check-platform-target", '\n                    ok = mx == "inf" or', '\n                    ok = True or'),
 ("sample-budget", '            if len(b) < budget or len(c) < budget:', '            if False:'),
 ("cell-verdict", '    cell_v = next((v for v in ("fail", "blocked", "insufficient") if v in verdicts), "pass")\n    row = ', '    cell_v = "pass"\n    row = '),
 ("check-cell-verdict", '    cell_v = next((v for v in ("fail", "blocked", "insufficient") if v in verdicts), "pass")\n    # A check gates', '    cell_v = "pass"\n    # A check gates'),
 ("summarize-improved", '        elif not imp:', '        elif False:'),
 ("summarize-missing-cell", '        elif missing or "blocked" in vs:', '        elif "blocked" in vs:'),
 ("restart-problem-class", 'PROBLEM = ("cold", "idle", "wake", "restart")', 'PROBLEM = ("cold", "idle", "wake")'),
 ("restart-budget", '"wake": 30, "restart": 10}', '"wake": 30, "restart": 9}'),
 ("restart-rule", 'add("rule\\trestart-first-answer\\tDEC-014:', 'add("rule\\trestart-first-answer\\tDEC-000:'),
 ("summarize-manifest", '        if len(prov) != 1 or "manifest_sha256=%s" % m["sha256"] not in prov[0].split("\\t"):', '        if len(prov) != 1:'),
]


def main():
    want = sys.argv[1:] or [n for n, _, _ in G]
    original = open(TOOL).read()
    missed = broken = 0
    try:
        for name, old, new in G:
            if name not in want:
                continue
            if original.count(old) != 1:
                print("%-24s MUTATION DOES NOT APPLY" % name)
                broken += 1
                continue
            open(TOOL, "w").write(original.replace(old, new))
            out = subprocess.run(["bash", RUNNER, "unit", "performance-acceptance"],
                                 capture_output=True, text=True).stdout
            red = [l.split()[1] for l in out.splitlines() if l.startswith("FAIL ")]
            print("%-24s %2d red: %s" % (name, len(red), " ".join(red) if red else "NOT CAUGHT"),
                  flush=True)
            missed += not red
    finally:
        open(TOOL, "w").write(original)
    sys.exit(2 if broken else (1 if missed else 0))


if __name__ == "__main__":
    main()
