# Stage 2 premises — 2026-11-05-gui-update-bridges-restart-sub-04-bridges-toggle-plan

Goal: The owner sees a Linux and a Mac stack go direct and come back to bridges with DNS answering after each switch.
Risk: MEDIUM — each switch costs a Tor bootstrap on the targets; four bootstraps per platform, each bounded.

Outcomes:
- Works: per platform, `off` restarts the proxy, the supervisor line says `direct (no bridges)`, a fresh name answers within 10 min, a forced refresh journals `skipped`; `on` brings `with N bridge(s)` back and a fresh name answers.
- A target is unreachable → that check is `[~]` with the reason.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: the pinned proxy image's supervisor logs the launch as `spawned tor ... direct (no bridges)` with bridges off and `... with N bridge(s)` with bridges on (the Stage 2 Outcomes' wording).
Checked: ssh mint 'podman exec tor-socat sh -c "grep -n ... /bin/start.sh"' (2026-11-07; socat v2.12, sha256:4feee064)
Result: start.sh:228 _how="direct (no bridges)"; :241 _how="with $NBRIDGES bridge(s)"; :250 echo "tor-supervisor: spawned tor pid=$TOR_PID generation=$GENERATION $_how".
Verdict: holds

## Premise 2
Assumption: mint takes `install-cell` from this branch over ssh, and `nice-dns` runs there with its user bus.
Checked: ssh mint 'export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user is-system-running; ~/.local/bin/nice-dns status --tsv' (2026-11-07)
Result: user bus answers ("degraded": transient podman healthcheck units and a flatpak scope only); installed generation 20261106T213807Z-590c905af0df (the Sub-plan 3 reinstall from main over ssh, 209 s).
Verdict: holds

## Premise 3
Assumption: the mac takes `install-cell` from this branch over ssh (Task 2.1/2.2: per platform, install-cell from this branch).
Checked: ssh mac 'launchctl print gui/$(id -u)/com.apple.container.apiserver; launchctl print user/$(id -u)/...; container system status' (2026-11-07)
Result: the apiserver runs in gui/501 (state = running); user/501 has none; over ssh `container system status` says "apiserver is not running and not registered with launchd". With the runtime there every ssh install fails at nd_install_macos_fresh_datapath (memory 2026-11-06, BL-052); Sub-plan 2's mac cells passed only with the runtime moved into the ssh-visible domain and the controller agents unloaded, by the owner's leave, then restored to gui/501.
Verdict: false (as written: a plain ssh install-cell); the known workaround needs the owner's decision
Resolution: owner, 2026-11-07: "Same workaround (Recommended)" (sub-plan OD-7): the mac cell moves the runtime into the ssh-visible domain for install-cell and restores gui/501 before the switches.
