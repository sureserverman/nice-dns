# Stage 2 premises — 2026-11-05-gui-update-bridges-restart-sub-01-restart-policy-plan

Goal: A person whose Pi-hole hangs, whose container was paused, or whose proxy crashes in a loop gets DNS back without a reboot, and the controller never adds restarts to a loop.
Risk: MEDIUM — an unattended restart rule can cost the DNS it means to restore; the streak, cooldown, cap and the crash-loop hold are what prevent it, and each is a policy test.

Outcomes:
- Works: Pi-hole fails its check (or `local-service`) three passes in a row → restarted alone on Linux, journaled requested, acknowledged, ready; two restarts, then one every 30 minutes; a healthy reading clears the streak.
- A container is paused for two passes → unpaused on Linux (journaled); on macOS, which has no pause, the record escalates with the reason and nothing is restarted.
- A container's restart count rises → the controller starts its cooldown from that moment and issues no restart of its own; three rises within 10 minutes → one `crash-loop: <name>` escalation with one failure dump, repeated no more often than every 30 minutes; a count stable for 10 minutes clears it.
- Startup allowance or cooldown → the restart waits; the journal says why.
- The check could not run → indeterminate, no action.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: rootless podman on Linux can pause and unpause one stack container, and inspect reports `paused` meanwhile (Task 2.2's repair and its observation).
Checked: `ssh mint 'podman pause unbound; podman inspect -f "{{.State.Status}}" unbound; podman unpause unbound; podman inspect -f "{{.State.Status}}" unbound; dig +short @127.0.0.1 example.com'` (2026-11-05 15:05Z; cgroups v2 per `podman info`)
Result: pause_rc=0, `paused`; unpause_rc=0, `running`; dig answered 172.66.147.243 right after.
Verdict: holds

## Premise 2
Assumption: on Linux one pod member's unit can be restarted alone, without the pod (Task 2.4's `systemctl --user restart pi-hole.service`).
Checked: `ssh mint 'systemctl --user list-dependencies --reverse pi-hole.service --plain; podman ps --format "{{.Names}} {{.Status}}"'`
Result: only `nice-dns-pod.service` (Wants) and default.target depend on pi-hole.service, so a restart of it does not propagate to the pod; `unbound Up 2 days` beside `pi-hole/tor-haproxy/infra Up 5 days` shows the controller already restarted one member alone.
Verdict: holds (Pi-hole itself is restarted live in Stage 3)

## Premise 3
Assumption: the unit's restart count is readable on the real host (Task 2.3 reads `restarts N` from `NRestarts`).
Checked: `ssh mint 'systemctl --user show -p NRestarts,ActiveState pi-hole.service'`
Result: `NRestarts=0`, `ActiveState=active`.
Verdict: holds

## Premise 4
Assumption: Apple `container` has no pause, so a macOS paused reading can only escalate (Task 2.2's macOS branch).
Checked: `ssh mac '/opt/homebrew/bin/container --help | grep -ci pause'` (container 1.6.1)
Result: 0 matches; lifecycle verbs are kill, start, stop.
Verdict: holds
