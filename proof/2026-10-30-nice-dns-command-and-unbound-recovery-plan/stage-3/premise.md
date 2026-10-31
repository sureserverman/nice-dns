# Stage 3 premises — 2026-10-30-nice-dns-command-and-unbound-recovery-plan

Goal: The owner knows the changes work on real hosts, not only on fixtures.
Risk: MEDIUM — the runs take DNS down on the targets, which are disposable by rule. Runs must stay short and be dry-run first.

Outcomes:
- Works: a receipt per platform shows recovery from both injected faults with no human action, and all four subcommands doing their job.
- A target is unreachable → that check is marked `[~]` with the reason, and the plan cannot close as completed without a `Blocked-accepted` line.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: `mint` and `mac` are reachable as the disposable targets, with the pinned host keys.
Checked: `bash tests/live/target.sh validate --targets tests/live/targets.env`, then `probe mint` and `probe mac`.
Result: both listed; both probes exit 0; each stack's containers run. mac runs container CLI 1.6.1 on macOS 27.0.1.
Verdict: holds

## Premise 2
Assumption: SIGSTOP on the unbound process can be sent inside the image on both platforms, and its state can be read back.
Checked: `podman exec unbound sh -c 'command -v pkill pgrep awk; pgrep -x unbound; awk "{ print \$3 }" /proc/$(pgrep -x unbound)/stat'` on mint; the same with `container exec` on mac.
Result: /usr/bin/pkill and /usr/bin/awk on both; one unbound process, state S.
Verdict: holds

## Premise 3
Assumption: a fresh name reaches upstream through the client resolver, so its answer says the chain works.
Checked: `dig @127.0.0.1 nd-cr-premise-<now>.example.com A` on mint; `dig @172.31.240.250` the same on mac.
Result: NOERROR with no answer, authority SOA elliott.ns.cloudflare.com, 1829 ms. That is Cloudflare's own negative answer, not a local one. A second name under cloudflare.com took 721 ms, then 4 ms from cache. The scenario also requires that a fresh name does not answer during each fault.
Verdict: holds

## Premise 4
Assumption: a command on the Mac can run in the GUI context from ssh, so an install does not hit BL-052.
Checked: `sudo -n launchctl asuser $(id -u) sudo -n -u $(id -un) env HOME=$HOME PATH=$PATH sh -c 'launchctl managername; id -un'` on mac.
Result: `Aqua`, `user`. The Stage 2 demo also installed this way. This does not close BL-052: a plain ssh install stays unproven and the receipt says so.
Verdict: holds

## Premise 5
Assumption: the controller on each target acts, on real timers, and each host has room for builds.
Checked: `mode` in the controller's install.tsv and `ls tunables.tsv` on both; `df -h ~` on mac.
Result: `mode active` on both; no tunables.tsv on either; 44 GiB free on mac (a build needs 20).
Verdict: holds
