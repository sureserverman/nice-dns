# Stage 3 premises — 2026-11-05-gui-update-bridges-restart-sub-01-restart-policy-plan

Goal: The owner sees the three fault classes recover on real hosts, and knows whether a Mac can restart one container without rebuilding the stack.
Risk: MEDIUM — the runs take DNS down on the targets, which are disposable by rule; the crash-loop injection must stop by itself (a remote timer thaws, as `freeze-upstream` does).

Outcomes:
- Works: a receipt per platform shows a frozen Pi-hole restarted, a paused Unbound unpaused (Linux), a crash loop held with one escalation and back-off visible (Linux), and a stopped container repaired (macOS), each without human action.
- The macOS per-container restart keeps the container's address and the chain resolves → Unbound and Pi-hole restart alone on macOS from now on; BL-038 is updated.
- It does not → the kickstart stays, the finding is recorded on BL-038, nothing else changes.
- A target is unreachable → that check is `[~]` with the reason; the plan cannot close as completed without a `Blocked-accepted` line.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: `podman kill --signal ABRT <proxy>` crashes the proxy so its unit restarts (Task 3.1's crash injection as written).
Checked: `ssh mint 'podman exec tor-haproxy grep SigBlk /proc/1/status; podman kill --signal ABRT tor-haproxy; sleep 12; systemctl --user show -p NRestarts,Result tor-haproxy.service'` (2026-11-05 17:13Z)
Result: PID 1 is tini with SigBlk/SigCgt 0, so the kernel drops a default-action signal to a namespace init: NRestarts stayed 0, Result=success, the container kept running.
Verdict: false for the mechanism, not for the stage. The Goal and Outcomes need a crash loop, not this command, and Premise 2 shows the crash is injectable. Task 3.1 uses `podman exec <proxy> kill -ABRT 2` (tini's child). Recorded as a deviation in the task's commit.

## Premise 2
Assumption: an ABRT to tini's child crashes the proxy with rc 134 (the 2026-11-02 code), and `Restart=on-failure` restarts it and counts it in `NRestarts`.
Checked: `ssh mint 'podman exec tor-haproxy kill -ABRT 2; sleep 15; systemctl --user show -p NRestarts,Result tor-haproxy.service; journalctl --user -u tor-haproxy.service --since -1min'` and then a dig of a fresh name (17:15Z)
Result: `Main process exited, code=exited, status=134/n/a`; `Scheduled restart job, restart counter is at 1`; NRestarts=1; the fresh name answered NOERROR 30 s later. Units were main's (no RestartSteps yet; install-cell brings them).
Verdict: holds

## Premise 3
Assumption: Pi-hole's DNS process can be frozen by name inside the container on both platforms (freeze-service --component pi-hole), as freeze-unbound does for unbound.
Checked: `ssh mint 'podman exec pi-hole sh -c "pgrep -x pihole-FTL | wc -l"'`; `ssh mac 'container exec pi-hole sh -c "command -v pkill; pgrep -x pihole-FTL | wc -l"'`
Result: exactly one pihole-FTL on each; pkill present (/usr/bin/pkill). SIGSTOP cannot be ignored, unlike Premise 1.
Verdict: holds

## Premise 4
Assumption: Apple container can stop and start one container by id (stop-container on macOS, Task 3.2's qualification); whether the address survives is the qualification itself.
Checked: `ssh mac 'container stop --help; container start --help; container list --all'` (container 1.6.1)
Result: `container stop [--signal] [--time] <ids>` and `container start <id>` exist; pi-hole/unbound/tor-haproxy run at .250/.251/.252.
Verdict: holds (address retention: not checkable before Task 3.2 runs it, by design)

## Premise 5
Assumption: rootless podman can pause and unpause unbound and the unit's back-off keys are honored (systemd 254+).
Checked: Stage 2 Premise 1 (pause/unpause on mint, 15:05Z) and `ssh mint systemctl --version` (17:12Z)
Result: pause/unpause rc 0 with the `paused` state between; systemd 255.4.
Verdict: holds
