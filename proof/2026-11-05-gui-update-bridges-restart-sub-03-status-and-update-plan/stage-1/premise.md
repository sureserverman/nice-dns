# Stage 1 premises — 2026-11-05-gui-update-bridges-restart-sub-03-status-and-update-plan

Goal: A person, a script or the GUI learns in one read-only call what is installed, what the controller last saw, and what it last did.
Risk: LOW — reads files the controller already writes, plus one new file.

Outcomes:
- Works: `nice-dns status` prints sections (install, controller, containers, routes, bridges, update, admin, recent actions); `--tsv` prints the same as `schema nice-dns-status/1` rows.
- Not installed → `installed no` and the README's curl line; exit 1.
- The controller has not run, or its last pass is older than 5 minutes → `controller stale <seconds>` and the observations are marked stale, still printed.
- The state directory is unreadable → `controller unreadable <reason>`; exit 2.
- No update check yet → `update unknown never-checked`.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: The scheduled pass has the pass's observation file in hand when it calls `nd_recovery_tick`, so it can copy that file after the decision.
Checked: `systemctl --user cat nice-dns-health.service | grep ExecStart`; `tail -n 4 ~/.local/state/nice-dns-health/health.log`; read health/nice-dns-health:1125-1152 (cmd_tick).
Result: The schedule runs `tick` every minute; the log reads `2026-11-06T18:40:04+0000 TICK active action=no-op target=- result=none generation=30948`. cmd_tick writes the observations to `$o`, validates them, then calls `nd_recovery_tick "$mode" "$o"`, then removes `$o`.
Verdict: holds, with a correction — `tick` logs the action summary, not `OK` / `FAIL [...]` / `INDETERMINATE [...]` (only the legacy `run` logs those). The `pass` row's verdict is therefore computed from the pass's observations by the same classification `run_checks` uses, which gives the format Task 1.1 names.

## Premise 2
Assumption: The controller's state directory exists, is private to the user and writable by the controller, so a new file there inherits that protection.
Checked: `ls -ld ~/.local/state/nice-dns/controller; ls ~/.local/state/nice-dns/controller/`
Result: `drwx------ user user ... /home/user/.local/state/nice-dns/controller`; holds bridges.last, bridges.pending, bridges.weak, escalation-reported, recovery.tsv, state.tsv.
Verdict: holds

## Premise 3
Assumption: The install records what is installed in files status can read without running anything (current generation and its prepare.tsv).
Checked: `ls ~/.local/state/nice-dns-install/`; `ssh mint 'cat ~/.local/state/nice-dns-install/current; grep -E "^(branch|source_commit|variant)" <latest generation>/prepare.tsv'`
Result: laptop: `current`, `generations`, `source`. mint: `20261106T150833Z-nogit0000000`, `variant socat`, `branch main`, `source_commit unknown`.
Verdict: holds

## Premise 4
Assumption: A live controller writes `observations.tsv` that the Stage 2 gate's read-only `status` on this laptop can show as a recent `last_pass`.
Checked: the laptop's installed controller is the bundle from its last install; OD-3 forbids reinstalling here.
Result: the laptop's controller predates Task 1.1, so it will not write `observations.tsv`; its status will show the row with no recent pass.
Verdict: not checkable here — the laptop is never reinstalled (OD-3); the live check is the master gate on mint after its reinstall from main (master OD-1).
