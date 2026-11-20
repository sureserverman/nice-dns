# Stage 2 premises — 2026-11-20-macos-ssh-followups-plan

Goal: The Mac owner's own route, plain ssh, shows the install's runtime restart and the controller's runtime repair working on the real mac, before the branch merges.
Risk: MEDIUM — the mac's DNS is down during the reinstall and the runtime drill (minutes each); a wrong kickstart path leaves the mac without DNS until `nice-dns restart`

Outcomes:
- Works: a reinstall over plain ssh from the branch says the runtime stopped and started again, and DNS answers at 172.31.240.250 afterwards
- Works: with the runtime stopped, a hand-run `nice-dns-health tick` over plain ssh brings it back through the start-container agent; `launchctl list` over ssh still shows one `com.apple.container.apiserver`, and DNS answers again

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: plain ssh to the mac runs in a non-login domain while the user's gui/<uid> session and the start-container agent exist
Checked: ssh mac 'launchctl managername; launchctl print gui/$(id -u)/org.nice-dns.start-container' (2026-11-20 18:3x UTC)
Result: Background; print exit 0
Verdict: holds

## Premise 2
Assumption: over plain ssh `container ls` answers while `container system status` does not (the controller's runtime-down read and the reason the installer reads status through root-ops)
Checked: ssh mac '/opt/homebrew/bin/container system status; /opt/homebrew/bin/container ls'
Result: status exit 1, ls exit 0; one com.apple.container.apiserver in launchctl list
Verdict: holds

## Premise 3
Assumption: nothing is building on the mac and the stack answers before the reinstall (memory mac-builder-wedges-dnsnet)
Checked: ssh mac 'pgrep -fl "container build"; dig +short +time=10 @172.31.240.250 cloudflare.com'
Result: no build process; an address returned; kept source 22550ad29aea
Verdict: holds

## Premise 4
Assumption: a `launchctl kickstart gui/<uid>/org.nice-dns.start-container` issued from plain ssh starts the agent, which starts a stopped runtime in gui/<uid>
Checked: not run before the drill — running it means stopping the runtime
Result: —
Verdict: not checkable here — Task 2.2 is its proof; the Stage 2 Rollback covers a failure
