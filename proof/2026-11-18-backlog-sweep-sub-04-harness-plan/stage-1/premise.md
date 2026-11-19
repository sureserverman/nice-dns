# Stage 1 premises — 2026-11-18-backlog-sweep-sub-04-harness-plan

Goal: For the person who reads a green live run: a case that scanned nothing, a switch that started no bridge, or a remote call that never returned can no longer end green.
Risk: LOW — harness code only; every change has a fixture case in a dry-run group.

Outcomes:
- A live group's privacy case fails when the run left no report to scan, so a green privacy line means evidence was scanned.
- A bridges switch fails unless the spawn line it judges is of the generation it started, and, with bridges on, names at least one bridge.
- An install cell or a command op that never returns ends at its outer limit with `timeout` and the op's name, and the cell fails.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: a privacy case's only assertion today is an empty `grep -rl` result, which an empty artifact directory also gives (the defect Task 1.1 fixes is real).
Checked: `d=$(mktemp -d); grep -rlE 'cert=[A-Za-z0-9+/]{20}' "$d" --include='*.tsv'` on this host, and the case bodies (`grep -nE 'assert_eq ""[^|]*grep -rl' tests/live/*.sh`).
Result: empty output (rc 1), so `assert_eq ""` passes; 14 group-level privacy cases have no other assertion than that scan or only a `[ -d ]` guard.
Verdict: holds

## Premise 2
Assumption: the dry-run groups run the live cases against fixture targets, so every Stage 1 change can be proven without a host.
Checked: `bash tests/run.sh integration bridges-toggle-dryrun` and `command-recovery-dryrun` (Preflight baseline), and their headers (NICE_DNS_TARGET_ADAPTER=tests/fixtures/*-adapter.sh, `. tests/live/<group>.sh`).
Result: 9/9 and 9/9 pass (runs 20261119T192645Z-c4448c99, 20261119T192733Z-e8f0decf); both source the live file and run its steps through `il_each` against the adapter.
Verdict: holds

## Premise 3
Assumption: the real proxy image's spawn line names the generation it started, so `bt_switch` can judge the line of its own generation.
Checked: `timeout 90 bash tests/live/target.sh proxy-supervisor-lines mint --targets tests/live/targets.env` (read-only op), 2026-11-19.
Result: `supervisor_line	tor-socat	tor-supervisor: spawned tor pid=12 generation=1 direct (no bridges)` (mint is in bridges-off mode now).
Verdict: holds

## Premise 4
Assumption: the host running the harness has `timeout` for the outer limits of Task 1.3.
Checked: `command -v timeout; timeout --version`
Result: /usr/bin/timeout, GNU coreutils 9.4.
Verdict: holds
