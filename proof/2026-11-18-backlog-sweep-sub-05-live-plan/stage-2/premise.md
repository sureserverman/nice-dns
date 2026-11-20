# Stage 2 premises — 2026-11-18-backlog-sweep-sub-05-live-plan

Goal: The owner has numbers and a verdict for every entry that was waiting on a measurement, so none of them stays open as a question.
Risk: MEDIUM — Task 2.4 swaps images on the mac for hours and its baseline arm is unverified today; Task 2.5 runs in a VM on this laptop. Each run happens once, the cheap reads come first, and a run that cannot start stops its own task only.

Outcomes:
- Works: each of BL-066, BL-027, BL-025, BL-035, BL-046 has a dated section with how it was measured, the numbers and one verdict line against the bar this plan sets
- Works: the 1.1.1.1 query seen on 2026-10-31 is traced to a sender the bootstrap record declares, and the proxies' logs of a day are scanned for errors
- A bar is missed → the old entry is replaced by one new improvement entry that carries the numbers

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: the update schedule fires on its own on mint (Task 2.1)
Checked: `ssh mint 'systemctl --user list-timers --all | grep nice-dns'` (2026-11-19 23:50 UTC)
Result: nice-dns-health-update.timer last fired Thu 2026-11-19 12:25:35 GMT, next 00:24:11; no hand start in this run
Verdict: holds

## Premise 2
Assumption: the mac's update agent fires at 04:47 and 16:47 and its log of a firing can be read (Task 2.1)
Checked: `ssh mac 'date; plutil -p ~/Library/LaunchAgents/org.nice-dns.health-update.plist; nice-dns status --tsv | grep ^update'`
Result: mac clock is GMT (23:51); StartCalendarInterval 04:47 and 16:47; `update result unknown never-checked`, `update auto loaded`: Task 1.1's uninstall removed the earlier update state and logs, so the first own firing to read is 04:47 GMT on 2026-11-20
Verdict: holds (waits until 04:47 GMT)

## Premise 3
Assumption: mint holds 7 days of proxy logs (Task 2.2)
Checked: `ssh mint 'podman inspect tor-socat --format {{.HostConfig.LogConfig.Type}}; journalctl --user CONTAINER_NAME=tor-socat | head -1'`
Result: log driver journald; the user journal (one boot since 2026-10-02) holds tor-socat lines from 2026-10-06 on, across every recreation
Verdict: holds (the logs exist; see Premise 7 for what they can show)

## Premise 4
Assumption: the mac holds 7 days of proxy logs (Task 2.2: "`container logs` and the agent's log on the mac")
Checked: `ssh mac '<container via launchctl asuser> logs tor-socat | wc -l; ls -la ~/Library/Logs/nice-dns-health/'`
Result: `container logs tor-socat` has 7 lines (the container was recreated at ~23:22 UTC by Stage 1); ~/Library/Logs/nice-dns-health/ starts 22:31 UTC, when Task 1.1's uninstall removed the old logs; ~/Library/Logs/nice-dns.log is the start-container agent's log (no proxy connect lines)
Verdict: false — the mac's last 7 days of proxy and controller logs were removed by Stage 1's own uninstall; only the time since 22:31 UTC on 2026-11-19 can be measured there
Resolution: owner, 2026-11-19: "Mint only" (OD-6) — Task 2.2 measures mint over 7 days and records the mac as not measured

## Premise 5
Assumption: the baseline arm of tune-transport can be prepared on the mac (Task 2.4)
Checked: not run
Result: preparing it builds images on the mac, which changes state; Task 2.4 checks it first and stops if it cannot
Verdict: not checkable here — needs a state change; checked at Task 2.4

## Premise 6
Assumption: the VM Ubuntu is free of other tests (Task 2.5)
Checked: `virsh -c qemu:///system domstate Ubuntu` (running since 22:06 UTC, started by this run's Preflight)
Result: running; nothing else is using it now
Verdict: not checkable here for the time of the run — Task 2.5 checks it right before

## Premise 7
Assumption: mint's 7 days of proxy logs show how long onion connects waited (a stall: onion connects that waited over 20 s with no data) (Task 2.2)
Checked: `journalctl --user --since "7 days ago" CONTAINER_NAME=tor-socat|tor-haproxy|unbound` profiled by line shape; `journalctl --user --since "7 days ago" | grep -cF route:cloudflare-onion`; `ls ~/.local/share/nice-dns-health ~/.local/state/nice-dns-health` (2026-11-20 00:05-00:15 UTC)
Result: tor-socat 575 lines, none timed (235 "socks: connect request rejected or failed", 124 "BACKUP health check failed", restarts, bootstraps); tor-haproxy 63 lines (it ran only in Task 1.4's window); unbound 33 start lines; 0 journal lines name route:cloudflare-onion (the controller keeps its observations in observations.tsv, overwritten each pass, and its own journal and health.log were reset by Task 1.1's uninstall at 22:28 UTC). mint's selected route is cloudflare-exit (transport-live run 20261119T233236Z-8f43d2c3), so onion stalls do not reach its queries in steady state. No target.sh op measures connect waits (route-onion writes a route file).
Verdict: false — no log on mint records an onion connect's wait; the stall lengths cannot be read, only measured anew
Resolution: owner, 2026-11-20: "Probe mint 6 h (Recommended)" (OD-7) — a DNS-over-TLS query to the onion route from inside mint's pod every 10 s for 6 h, timed end to end
