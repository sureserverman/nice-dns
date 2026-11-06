# Stage 1 premises — 2026-11-05-gui-update-bridges-restart-sub-02-bridges-off-images-plan

Goal: An operator who sets `TOR_BRIDGES=off` gets a proxy whose Tor connects directly, and one who sets nothing gets today's behaviour unchanged.
Risk: LOW — a guarded branch in two supervisors; the fake-tor test pins the exact argv.

Outcomes:
- Works: with `TOR_BRIDGES=off` the supervisor logs `direct (no bridges)`, launches Tor with `UseBridges 0` and no `Bridge` lines, and the route probes answer once bootstrapped.
- `TOR_BRIDGES` unset or `on` → today's path: at least one bridge required, the same refusal message.
- `TOR_BRIDGES` is anything else → exit 1 with `TOR_BRIDGES must be on or off`.
- `off` with `BRIDGEn` or `BRIDGE_EVAL` set → one log line each saying they are ignored.
- The in-image restart contract respawns Tor the same way in both modes.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: Tor started from the images' torrc with `UseBridges 0` and no `Bridge` lines bootstraps by connecting to guards directly (the plan's Early premise; the unused `ClientTransportPlugin obfs4` line is harmless).
Checked: 2026-11-06 on this laptop, released image v2.15, throwaway container, no stack change: `systemd-run --user --wait --pipe podman run --rm docker.io/sureserver/tor-haproxy:v2.15 sh -c 'tor -f /etc/tor/torrc UseBridges 0 DataDirectory /tmp/t ...'`
Result: `Bootstrapped 0% (starting)` at 10:05:29, `Bootstrapped 100% (done)` at 10:05:36 (9 s); no warning or error lines.
Verdict: holds
