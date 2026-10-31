# Stage 1 premises — 2026-10-30-nice-dns-command-and-unbound-recovery-plan

Goal: A person running nice-dns gets working DNS back without rebooting, whichever part of the chain broke, and the controller never goes idle during a long outage.
Risk: MEDIUM — an unattended restart loop would cost the DNS it means to restore; the streak, cooldown and retry limits are what prevent it.

Outcomes:
- Works: Unbound breaks while routes are healthy → within about 5 minutes it is restarted alone on Linux; the journal shows requested, acknowledged, ready.
- Unbound's control socket is dead during a Tor outage → it is restarted too, because that fault is Unbound's own.
- Only Unbound's route probe fails during a full outage → Unbound is left alone and the Tor ladder runs, since the probe is telling the truth.
- A restart does not cure it → two restarts, then one every 30 minutes, each journalled; it never stops silently.
- A full outage outlasts the ladder → the stack restarts every 30 minutes until a route answers, each journalled, and the first escalation of the outage writes one failure dump.
- A stack container is missing → the missing unit itself is started and acknowledged.
- The user service manager cannot start containers → what Task 1.6 finds: a working repair, or an error-level log and a `nice-dns-health status` line saying a reboot is needed. Never a silent loop.
- The check cannot run (a timeout, or an image without the probe) → indeterminate, no action, and the reason is in the observation.
- macOS → the same triggers, but the restart rebuilds the stack (BL-038) and costs a Tor bootstrap.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: `systemctl --user restart unbound.service` touches Unbound only, so a restart leaves Pi-hole and the proxy running.
Checked: `ssh mint systemctl --user show {unbound,tor-haproxy,pi-hole,nice-dns-pod}.service -p Requires,BindsTo,Wants,After` with XDG_RUNTIME_DIR set.
Result: pi-hole has Wants=unbound.service and BindsTo=nice-dns-pod.service; nothing has Requires= or BindsTo= on unbound.service.
Verdict: holds

## Premise 2
Assumption: `systemctl --user restart nice-dns-pod.service` restarts all three members (Task 1.4, Task 2.4).
Checked: the same `systemctl show`: every member has BindsTo=nice-dns-pod.service; the pod has Wants= on all three.
Result: BindsTo stops the members with the pod; Wants starts them with it. Not run here, because it takes mint's DNS down: Stage 3 runs it.
Verdict: holds

## Premise 3
Assumption: a hung Unbound can be observed from outside with `SIGSTOP` as the fault, and the plan's "a timeout is indeterminate" still lets the controller act on it.
Checked: on mint, `podman exec unbound kill -STOP 2`, then `timeout 40 podman exec --user unbound unbound unbound-control -c /usr/share/nice-dns/control.conf status`, `nice-dns-unbound-start probe-route`, `podman exec --user unbound unbound true`, and `dig @127.0.0.1`; then `kill -CONT 2`.
Result: control hung (rc 124 at 40 s); probe-route passed (rc 0 in 2 s, it does not use the frozen daemon); exec of `true` passed in 0 s; dig through Pi-hole timed out.
Verdict: false as written, resolved inside the Outcomes. A timeout alone would make this fault indeterminate for ever, so Stage 3's Fault 1 and the Stage 1 "Works" Outcome could not both hold. Task 1.1 keeps "the check cannot run -> indeterminate": a timeout is indeterminate when a plain exec in the container also fails or hangs. A control timeout with exec answering is the daemon's own failure: unhealthy `control:`.

## Premise 4
Assumption: the hermetic test suite can run in this session's environment.
Checked: `bash tests/run.sh stage controller` and `stage installers` here; `cat /proc/self/uid_map` (with and without the tool sandbox); `stat -c %U /usr/local`.
Result: this session runs in a one-ID user namespace (`1000 1000 1`): podman cannot start and root files show as nobody. 7 cases fail here for that reason. All 7 pass on mint from a copy of the same commit.
Verdict: false here, resolved by running every test on mint from a copy of the tree (controller 205/205, installers 133/133 at 6c98e11). mint's installed stack is not touched.
