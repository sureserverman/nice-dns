# Stage 2 premises — 2026-11-05-gui-update-bridges-restart-sub-03-status-and-update-plan

Goal: A person learns whether a newer nice-dns exists on their branch and applies it through the same transaction as a reinstall, with the stack untouched on any failure.
Risk: LOW — the apply path is `cmd_reinstall`, already live-proven; only the gate and the cache are new.

Outcomes:
- Works: `nice-dns update --check` prints `current` (exit 0) or `available <short remote commit>` (exit 10) and writes the cache; `nice-dns update` checks, then reinstalls the recorded branch when available, then re-checks and prints the new commit.
- Nothing new → `nice-dns update` prints `already current` and installs nothing; `--force` reinstalls anyway.
- The remote cannot be reached (DNS down, offline) within 60 s → `unknown: <reason>`, exit 1, the cache says `unknown`, nothing changes.
- The install fails → the existing rollback; the message names `nice-dns reinstall --local`.
- A local (dirty or unknown) source commit was recorded → `unknown: the installed source was not a clean commit`.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: GitHub answers `git ls-remote --heads` for the nice-dns repo over HTTPS with no clone, quickly, under the same low-speed bound `fetch_branch` uses.
Checked: `time git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=60 ls-remote --heads https://github.com/sureserverman/nice-dns.git refs/heads/main`
Result: `986b76f415ab83fc4b5cb444e0f8ccc778399f01	refs/heads/main` in 0.82 s.
Verdict: holds

## Premise 2
Assumption: `timeout` exists on both platforms, so the check can be bounded ("under timeout 90 where available").
Checked: `command -v timeout` on this laptop; `ssh mac 'command -v timeout gtimeout; sw_vers -productVersion; /bin/bash --version'`
Result: laptop `/usr/bin/timeout`; mac `/usr/bin/timeout`, macOS 27.2, bash 3.2.57.
Verdict: holds (the code still runs without it, bounded by the low-speed limit)

## Premise 3
Assumption: An install records its branch, source commit and whether the source was clean, so `update` can compare against the remote.
Checked: `grep -E '^(source_commit|source_dirty|source_origin|branch)' <current generation>/prepare.tsv` on the laptop; the same on mint and mac.
Result: laptop: `branch main`, `source_origin clone`, `source_commit 0fe6c628…`, `source_dirty 0`. mint and mac: `branch main`, `source_commit unknown` (installed by the live harness from a copy; generation suffix `nogit0000000`).
Verdict: holds — and both live targets will answer `unknown: the installed source was not a clean commit` until they are reinstalled from a clone (master OD-1 reinstalls mint from main).

## Premise 4
Assumption: The apply path, `nice-dns reinstall` with the recorded choices, exists and is transactional (the stack is untouched on a failed clone; the installer rolls back).
Checked: nice-dns cmd_reinstall and fetch_branch (read at 6008f05); tests/integration/nice-dns-cli.sh t_failed_clone_names_local_and_changes_nothing passes in the baseline (installers stage 168/168).
Result: a failed clone prints "The running stack is untouched" and names `nice-dns reinstall --local`.
Verdict: holds
