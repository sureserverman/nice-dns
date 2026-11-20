# Stage 1 premises — 2026-11-20-macos-ssh-followups-plan

Goal: A Mac owner who runs nice-dns over ssh gets an uninstall that refuses before it changes anything, an install whose runtime restart is real or says it is not, and a controller that can never start a runtime in the ssh domain.
Risk: MEDIUM — installer and controller paths on macOS; a wrong stop check fails every macOS install

Outcomes:
- Works: an uninstall over ssh where sudo works, or where the helper does every root step, runs as before
- An uninstall over ssh where a root step needs sudo and sudo cannot ask for a password → it stops before anything changes and says to run it over `ssh -t` or from Terminal; DNS and the stack stay as they were
- An install or reinstall whose runtime does not stop when asked → the install fails at that step and says the runtime did not stop, instead of starting the stack on the old datapath; the rollback brings back the previous stack
- A hand-run `nice-dns-health tick` over ssh while the runtime is down → the controller kicks the start-container agent, the runtime comes back in the login session and no second runtime starts

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: over plain ssh the session is not Aqua, so the ssh code paths these fixes guard are the ones a Mac owner reaches
Checked: ssh mac 'launchctl managername' (2026-11-20, Preflight)
Result: Background
Verdict: holds

## Premise 2
Assumption: over plain ssh `container ls` answers while the gui runtime runs, so the controller's runtime-down read (`container ls` fails) does not fire on a healthy mac from ssh
Checked: ssh mac '/opt/homebrew/bin/container ls --format json' (2026-11-20, Preflight)
Result: exit 0, lists pi-hole, tor-socat, unbound; `launchctl list | grep -c com.apple.container.apiserver` = 1
Verdict: holds

## Premise 3
Assumption: the start-container agent can be kicked in gui/<uid> from plain ssh (the label exists in that domain)
Checked: ssh mac 'launchctl print gui/$(id -u)/org.nice-dns.start-container' (2026-11-20, dry run)
Result: exit 0
Verdict: holds for the label's reach; that a kickstart brings a stopped runtime back is not checkable here without stopping the runtime — Stage 2 Task 2.2 is its proof

## Premise 4
Assumption: a sudo that cannot ask for a password fails `sudo -n` and `sudo -v` with no terminal (the uninstall refusal's trigger)
Checked: not run — the mac has NOPASSWD sudo and no second account
Result: —
Verdict: not checkable here — the mac's sudo never asks; the fixture's sudo_needs_password knob models it (tests/fixtures/install-fakes.sh:164-167)

## Premise 5
Assumption: a gui runtime can ignore a stop (the stop read-back's trigger)
Checked: not run — no way to make the real runtime ignore a stop on purpose
Result: —
Verdict: not checkable here — modelled by the new `$FAKE/rt_stop_noop` knob; the 2026-11-19 ssh stop that reached no runtime (Sub-plan 3 OD-6) is the observed case
