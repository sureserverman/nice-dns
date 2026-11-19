# Stage 1 premises — 2026-11-18-backlog-sweep-sub-02-controller-bridges-plan

Goal: A person whose machine refreshes its bridges every day never gets two restarts fighting each other, and never loses a good bridge for 30 days because of one bad hour.
Risk: MEDIUM — the adoption restart is a destructive action moved under a lock; a mistake could stall a refresh. The fixture race test and the 600 s unit bound cover it; Task 2.6 runs one refresh live.

Outcomes:
- Works: a refresh that must restart the proxy does so under the controller's lock, and the journal shows the request, the acknowledgement and the time, as for any restart
- Works: when the controller is busy, the refresh restarts nothing; the new set waits and the proxy takes it at its next start
- Works: `nice-dns bridges off` during a refresh is respected: the refresh restarts nothing afterwards
- Works: a bridge judged weak once is left out of the new set at once, but is remembered for 30 days only when the next refresh judges it weak again
- Works: when dropping weak bridges would leave fewer than 3, the refresh keeps the set and reports `weak_blocked` with the count

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: the running proxy's Tor keeps per-bridge path-bias use counters (`Guard in=bridges ... pb_use_attempts= pb_use_successes=`) in /app/data/tor/state, the input `_nd_br_weak` judges and Task 1.2 judges twice.
Checked: on mint, 2026-11-19 06:30 UTC: `podman exec tor-socat sh -c 'grep -c "^Guard in=bridges" /app/data/tor/state; grep "^Guard in=bridges" /app/data/tor/state | head -2'` (fingerprints and addresses masked).
Result: 7 bridge guard lines; each carries `listed=`, `pb_use_attempts=` and `pb_use_successes=` (e.g. 27.000000/27.000000, 38.000000/38.000000). mint runs with `TOR_BRIDGES=off`, so these are counters kept from before, `listed=0`.
Verdict: holds

## Premise 2
Assumption: on Linux the refresh unit's `TimeoutStartSec` is what bounds one refresh (systemd ends a oneshot past it with `Result=timeout`), and today it is 420 s.
Checked: on mint: `systemctl --user show -p TimeoutStartUSec -p Result nice-dns-health-bridges.service`.
Result: `TimeoutStartUSec=7min`, `Result=success`.
Verdict: holds

## Premise 3
Assumption: the macOS refresh job has a launchd limit Task 1.3 can match ("the same total as the launchd job's limit on macOS").
Checked: read health/nice-dns-health:780-815 (the org.nice-dns.health-bridges plist): `ProgramArguments`, `StartCalendarInterval`, log paths, `PATH`; no time key. launchd.plist(5) has no start-time limit (`ExitTimeOut` bounds a stop, not a run). The Mac was not touched.
Result: there is no macOS job limit; one macOS refresh is bounded only by the script's own bounds (bridge-eval, the lock waits, the restart).
Verdict: not checkable here — the Mac is not used in this stage; read from the code, no live macOS limit exists to match. Task 1.3 sets the Linux unit only and says so.

## Premise 4
Assumption (the plan's early premise): the bridge fixtures can hold the state lock while a refresh runs.
Checked: `grep -n 'nd_state_lock' tests/integration/bridge-lifecycle.sh`: t_a_crash_looping_proxy_is_not_restarted_to_adopt_a_set takes the lock in the case's shell and commits a seed state; the refresh runs in the same fixture world (lib/recovery.sh sourced, ND_STATE_DIR per case). The group last passed 28/28 at c41d8e2 (Sub-plan 1, Stage 3 round 1).
Result: a case can hold the lock under its own token; a lock taken in the case's shell is held by a live pid, so nd_state_lock in the refresh sees it busy.
Verdict: holds
