# Stage 1 demo — 2026-10-30-nice-dns-command-and-unbound-recovery-plan

Environment: `ssh mint` (Linux, Podman quadlets, tor-haproxy variant) and `ssh mac` (macOS, Apple container CLI), 2026-10-30. Both shipped from `~/nice-dns-ci/nice-dns` (db67a47) with `bash health/nice-dns-health install` (`/bin/bash` on mac); install output and `install.tsv` on both: `bundle 5068eae4d3535ec7`, `previous 61857af757ebee58`, `mode active`. The demo used only the installed controller on its minute schedule, `nice-dns-health status|observe|failures`, the journal `recovery.tsv`, and `health.log`.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: Unbound breaks while routes are healthy → within about 5 minutes it is restarted alone on Linux; the journal shows requested, acknowledged, ready.
Verdict: holds
Evidence:
Default timers, mint, routes healthy. `podman exec unbound kill -STOP 2` at 20:20:32 (epoch 1793391632); `dig @127.0.0.1 example-*.com` then timed out.
Journal, nothing else added (requested 164 s after the freeze, ready 215 s after):
```
1793391796 nd-1793391796-45331 unbound requested    restart; unbound before: 9d965b33... 2026-10-30 19:38:17 running
1793391808 nd-1793391796-45331 unbound acknowledged unbound restarted: 8e3477b8... 2026-10-30 20:23:27 running
1793391847 nd-1793391796-45331 unbound ready        observed working 39s after the acknowledgement
```
health.log: `20:23:28 TICK active action=restart-component target=unbound result=acknowledged generation=45331`; next tick `no-op`.
Alone: `podman inspect` StartedAt afterwards: unbound 20:23:27, tor-haproxy still 19:17:05, pi-hole still 18:55:20. `dig @127.0.0.1 example.org` answers again; `observe`: `unbound healthy 1453 control and route answer`.

## Outcome 2
> Unbound's control socket is dead during a Tor outage → it is restarted too, because that fault is Unbound's own.
Verdict: holds
Evidence:
mint, short timers (STARTUP 60, GRACE 60, COOLDOWN 120, LADDER 240, RETRY 900, removed afterwards) so that no stack restart could fall due in the window; the restart counter was clear first (no `unbound_` line in state.tsv).
Fault at 21:28:55 (1793395735): the iptables REJECT of Outcome 3 plus `podman exec unbound kill -STOP 2`, daemon confirmed as pid 2 (`unbound -d -p`). `observe` 40 s later: `route:cloudflare-exit unhealthy no-answer ...`, `unbound unhealthy 10236 control: no answer within the deadline while the container still runs commands`.
```
1793395826 nd-1793395825-45398 tor     requested    restart request in tor-haproxy; generation before: 1
1793395832 nd-1793395825-45398 tor     acknowledged generation 1 -> 2, tor pid 28 -> 2668
1793396015 br-1793396015       bridges not-applied  bridge-eval exit 1; the last good set stays
1793396036 nd-1793396036-45399 unbound requested    restart; unbound before: d725b810... 21:24:16 running
1793396047 nd-1793396036-45399 unbound acknowledged unbound restarted: 21d954df... 21:34:07 running
```
health.log: `21:34:08 TICK active action=restart-component target=unbound result=acknowledged`; state `outage_since 1793395765`, `outage_restarts 1`, `unbound_restarts 1`. So inside an outage the Unbound fault is treated as Unbound's, while Outcome 3 (same outage, control answering) left Unbound alone.
The restart came 301 s after the freeze, because the tor rung and a bridge refresh (`21:31:04 BRIDGES outage refresh`, journal 21:33:35) held up the passes; see Minor m3.
An earlier try freezing at 21:18:39, after the proxy rung, was overtaken by the stack restart at 21:21:32 at RETRY 150, which recreated Unbound anyway.

## Outcome 3
> Only Unbound's route probe fails during a full outage → Unbound is left alone and the Tor ladder runs, since the probe is telling the truth.
Verdict: holds
Evidence:
mint, short timers (STARTUP 60, GRACE 60, COOLDOWN 120, LADDER 240, RETRY 150; removed afterwards).
Fault at 21:11:39 (1793394699): `sudo iptables -I OUTPUT -o wlp12s0 -m owner --uid-owner 1000 -p tcp ! --sport 22 -j REJECT`, same for ip6tables (rootless proxy's Tor cannot reach out; ssh keeps working). 40 s later `observe`: all four routes `unhealthy no-answer via tor-haproxy:...`, and `unbound unhealthy 15552 route: probe-route exit 1: ...`; `podman exec unbound unbound-control status` still answers (`version: 1.25.2`). `dig @127.0.0.1 ex-*.org` times out; a cached `cloudflare.com` still answers.
Ladder ran, Unbound left alone:
```
1793394812 nd-1793394811-45381 tor     requested    restart request in tor-haproxy; generation before: 1
1793394817 nd-1793394811-45381 tor     acknowledged generation 1 -> 2, tor pid 28 -> 1041
1793395110 nd-1793395110-45386 service requested    proxy restart for tor-haproxy; container before: 92f61570... 21:10:38 running
1793395112 nd-1793395110-45386 service acknowledged tor-haproxy restarted: 0f3ebcd3... 21:18:32 running
```
health.log: `21:13:37 action=restart-component target=tor`, four `no-op` ticks, `21:18:32 action=restart-component target=proxy`. No `unbound` entry in the journal. `podman inspect` at 21:18:36: unbound StartedAt still 21:05:27, unchanged across 7 minutes with its route probe failing; tor-haproxy 21:18:32.

## Outcome 4
> A restart does not cure it → two restarts, then one every 30 minutes, each journalled; it never stops silently.
Verdict: holds
Evidence:
mint, on both route states. tunables.tsv (mode 600, removed afterwards): STARTUP 60, GRACE 60, COOLDOWN 120, LADDER 300, RETRY 240; "every 30 minutes" appears here as every 240 s. Fault: `podman exec unbound kill -STOP 2` every 5 s in a loop, so each restart comes back frozen.

Route `cloudflare-onion` (loop started 20:55:20, state showed `route cloudflare-onion`):
```
1793393895 nd-...-45366 unbound requested / 1793393906 acknowledged  restarted 20:58:26
1793394076 nd-...-45369 unbound requested / 1793394088 acknowledged  restarted 21:01:27  (181 s later: restart 2)
1793394316 nd-...-45373 unbound requested / 1793394327 acknowledged  restarted 21:05:27  (240 s later: the long interval)
```
Between them health.log shows `TICK ... action=no-op` every minute; state `unbound_fail 3`, `unbound_restarts 2`, then 3.

Route `cloudflare-exit`, promotion to the onion due while frozen (a proxy restart put the host on the exit at 20:31:29; loop started 20:32:00 with `streak cloudflare-onion 2`):
```
1793392456 unbound requested / 1793392467 acknowledged  restarted 20:34:27
1793392514 route:cloudflare-onion requested switch ... promote cloudflare-onion after 6 healthy observations
1793392575 route:cloudflare-onion not-acknowledged apply_route exit 3
...(two more promotion tries, 60 s each)
1793392661 route:cloudflare-onion requested ... Unbound failed 3 checks in a row after 2 restarts; next restart 240 s after the last (206 s so far); promote cloudflare-onion after 8 healthy observations
1793392736 unbound requested / 1793392747 acknowledged  restarted 20:39:07
1793393046 unbound requested / 1793393058 acknowledged  restarted 20:44:17
```
Passes keep ending: health.log TICK lines 20:40:12, 20:41:26, 20:42:40, 20:43:53, 20:44:18, 20:45:32, 20:46:45 (`switch-route target=cloudflare-onion result=escalate` and `restart-component`); each bad promotion gives up after 60 s and the route stays `cloudflare-exit`.
The counter on this run was already 1 from Outcome 1's cured fault, because the first tick under the short RETRY already saw Unbound failing, so only the later interval shows here; the onion run above starts from no counter and shows the full count.
After `kill -CONT 2` at 20:46:49: `unbound ready observed working 152s after the acknowledgement`, then `route:cloudflare-onion requested ... acknowledged reads back and resolves`, `ready`; `dig @127.0.0.1 example.org` answered.
A racing `ready` was logged on the exit run (`1793392751 unbound ready observed working 4s after the acknowledgement`): the check got in before the loop re-froze; see Minor m2.

## Outcome 5
> A full outage outlasts the ladder → the stack restarts every 30 minutes until a route answers, each journalled, and the first escalation of the outage writes one failure dump.
Verdict: holds
Evidence:
Both hosts, with short timers because the default is 30 minutes (tunables.tsv mode 600, removed afterwards): "every 30 minutes" appears as RETRY seconds below.

**mint** (STARTUP 60, GRACE 60, COOLDOWN 120, LADDER 240, RETRY 150, then RETRY 400 from 21:25). Fault: the iptables REJECT of Outcome 3 from 21:11:39 to 21:27:12.
```
1793394812 tor     requested / 1793394817 acknowledged     generation 1 -> 2
1793395110 service requested / 1793395112 acknowledged     tor-haproxy restarted 21:18:32
1793395275 stack   requested / 1793395294 acknowledged     stack restarted 21:21:32
1793395448 tor     not-ready still failing 631s after the acknowledgement
1793395448 stack   requested / 1793395457 acknowledged     stack restarted 21:24:15  (163 s later; RETRY 150 on minute ticks)
1793395568 controller escalated Unbound failed 8 checks in a row; the stack restart covers it; full outage persists after 4 restarts (tor, then proxy); next stack restart 400 s after the last (120 s so far)
1793395631 controller escalated Unbound failed 9 checks ...
```
health.log: `21:26:25 ESCALATED first of this outage -> .../failure-20261030-212608.log`, next tick `action=escalate result=exit-0` with no new dump; count of `failure-*` files went 2 -> 3 and stayed. (The two stack restarts came before the first `escalated` entry only because RETRY 150 is shorter than the ladder; at the default 30 minutes the mac order below applies.)
Lifted 21:27:12 (1793395632): `1793395693 service ready`, `1793395697 stack ready observed working 396s after the acknowledgement; Unbound resolves over its route`, `1793395698 stack ready ...`; `outage_since -`, `outage_restarts 0`; `dig @127.0.0.1 example.org` answers. 61 s from lifting to working.

**mac** (STARTUP 60, GRACE 60, COOLDOWN 120, LADDER 300, RETRY 240). Fault: pf anchor `com.apple/261.nddemo`, `block drop quick from 172.31.240.248/29 to any` after passing traffic to and within the subnet, then `pfctl -k 172.31.240.248/29`, at 20:32:29. `observe`: all four routes `unhealthy no-answer`, `unbound unhealthy route: probe-route exit 1: Killed`.
```
1793392471 tor        requested / 1793392476 acknowledged  generation 1 -> 2, tor pid 28 -> 1204
1793392715 bridges    not-applied  bridge-eval exit 1; the last good set stays
1793392771 service    requested / 1793392779 acknowledged  tor-haproxy restarted 20:39:38
1793392932 controller escalated    Unbound failed 3 checks in a row; the stack restart covers it; full outage persists after 2 restarts (tor, then proxy); next stack restart 240 s aft...
1793392992 controller escalated    ...
1793393043 stack      requested / 1793393052 acknowledged  stack restarted 20:44:10
1793393172 controller escalated    ... after 3 restarts ...
1793393231 controller escalated    ...
1793393287 stack      requested / 1793393295 acknowledged  stack restarted 20:48:15
1793393412 controller escalated    Unbound failed 10 checks ... after 4 restarts ...
```
Stack restarts 245 s apart, each journalled. health.log: `20:42:21 ESCALATED first of this outage -> .../failure-20261030-204212.log`; later `action=escalate result=exit-0` wrote no new dump: `ls` shows only failure-20261030-191011.log (from before this demo) and failure-20261030-204212.log. Dump header: `Failed checks: route:cloudflare-onion route:cloudflare-exit route:quad9-exit route:cloudflare-legacy unbound`.
Block lifted 20:50:25 (1793393425): `1793393468 stack ready observed working 172s after the acknowledgement; Unbound resolves over its route`; state `outage_since -`, `outage_restarts 0`. 43 s from lifting to working.

## Outcome 6
> A stack container is missing → the missing unit itself is started and acknowledged.
Verdict: holds
Evidence:
Default timers, mint. `systemctl --user stop tor-haproxy.service` at 20:24:59 (epoch 1793391899). `observe`: `runtime unhealthy containers-missing: tor-haproxy (running: nice-dns-infra pi-hole unbound)`, `proxy indeterminate unknown: tor-haproxy generation not readable`.
Journal (requested 243 s after the stop):
```
1793392142 nd-1793392142-45337 runtime requested    repair of containers-missing: exit 0
1793392143 nd-1793392142-45337 runtime acknowledged containers-missing: the runtime answers and the stack runs
1793392287 nd-1793392142-45337 runtime ready        observed working 144s after the acknowledgement
```
health.log: `20:29:03 TICK active action=repair-runtime target=containers-missing result=acknowledged`. `podman ps` after: tor-haproxy `Up 2 minutes (healthy)`; unbound (started 20:23) and pi-hole (up 2 hours) were not touched. Only the missing unit was started. Then `switch-route target=cloudflare-exit` because the proxy is fresh; `dig @127.0.0.1 example.org` answered.
A short-lived container `vibrant_bouman` appeared at that point; it matches `20:30:02 BRIDGES outage refresh result=changed` in health.log and was gone a minute later.
Journal wording: the entry says `runtime` / `containers-missing` and does not name the unit it started (Minor finding m1).

## Outcome 7
> The user service manager cannot start containers → what Task 1.6 finds: a working repair, or an error-level log and a `nice-dns-health status` line saying a reboot is needed. Never a silent loop.
Verdict: holds (working repair)
Evidence:
mint, short timers. `systemctl --user stop tor-haproxy.service` at 21:05:52, then `mv $XDG_RUNTIME_DIR/systemd/private private.real`, python3 bound and closed a Unix socket at that path (`srwxr-xr-x ... private`), then `systemctl --user restart tor-haproxy.service`:
```
Job for tor-haproxy.service failed because the control process exited with error code.
restart=1
```
Unit log, repeating: `Error: create healthcheck: unable to get systemd connection to add healthchecks: dial unix /run/user/1000/systemd/private: conne...`, `Failed to start tor-haproxy.service`. `observe`: `runtime unhealthy containers-missing: tor-haproxy`.
Controller, unaided:
```
1793394485 nd-1793394483-45376 runtime requested    repair of containers-missing: daemon-reexec (exit 0); exit 0
1793394486 nd-1793394483-45376 runtime acknowledged containers-missing: the runtime answers and the stack runs
1793394548 nd-1793394483-45376 runtime ready        observed working 62s after the acknowledgement
```
health.log: `21:08:06 TICK active action=repair-runtime target=containers-missing result=acknowledged`. `ls` after: `private` is a new socket owned by the manager (mode srwx------, 21:08), `podman ps`: `tor-haproxy Up 2 minutes (healthy)`. A plain `systemctl --user restart tor-haproxy.service` then succeeds (rc 0). Working repair, 134 s after the fault, no reboot. So the error-level/reboot-needed branch was not needed and was not reached by this route.

## Outcome 8
> The check cannot run (a timeout, or an image without the probe) → indeterminate, no action, and the reason is in the observation.
Verdict: holds
Evidence:
Re-demo on commit f6593fe, bundle f19b76097d4833c2 on both hosts (`install.tsv`), default timers (no tunables file), 2026-10-30 22:54-23:21 UTC. Each tool was moved inside the running Unbound as root and `nice-dns-health observe` read about once a minute. In cases 1-4 `state.tsv` held no `unbound_*` line at any sample, so no failure was counted.

1. No `dig`, both hosts, about 7 minutes (mint 22:54:11-23:01:20, mac 22:54:11-23:01:12).
- Observation at every sample, both hosts: `obs unbound indeterminate 414 probe-route cannot run in the image (exit 127): nice-dns-unbound-start: dig is not in the image`.
- mint ticks 45481-45487, for example `2026-10-30T22:57:06+0000 TICK active action=no-op target=- result=none generation=45483`. mac ticks 39945-39951 are the same. No journal line on either host.
- The container was not replaced: mint fd5d759fac34 started 22:10:18 throughout; mac started 22:44:35 throughout. mint's own podman health went `unhealthy` from about 22:56:52 and nothing acted on it.
- After restoring `dig`: `obs unbound healthy ... control and route answer`, still no action.

2. No `timeout`, both hosts, about 2.5 minutes. Observation: `obs unbound indeterminate 408 probe-route cannot run in the image (exit 127): nice-dns-unbound-start: timeout is not in the image`. mint ticks 45489-45491 and mac ticks 39953-39954 all `action=no-op`, no journal line. Healthy after restoring.

3. No `unbound-control`, both hosts, about 2.5 minutes. Observation: `obs unbound indeterminate 172 no unbound-control in the image (exit 127)`. mint ticks 45493-45495 and mac ticks 39957-39958 all `action=no-op`, no journal line. Healthy after restoring.

4. Commands cannot run, mint only.
- Frozen cgroup (`echo 1 > .../libpod-payload-<id>/cgroup.freeze`, 23:10:16-23:12:58; podman still reports `status=running`): `obs unbound indeterminate 189 the runtime could not exec in unbound (exit 255): Error: OCI runtime error: crun: the container ... is paused`. Ticks 45497 and 45498 `action=no-op`, no journal line. Healthy after thawing.
- `podman pause unbound` (23:14:08-23:15:14): `obs unbound indeterminate 0 the unbound container is not running: the runtime record reports it`. The Unbound check took no action, but the separate runtime check ran and reported `obs runtime unhealthy 117 containers-missing: unbound (running: nice-dns-infra tor-haproxy pi-hole)`. Tick 45500 was `no-op`; on the next pass the controller acted: `1793402106 nd-1793402106-45501 runtime requested repair of containers-missing: exit 0` (23:15:06). The only `unpause` podman recorded was this demo's own, at 23:15:14; the journal's `acknowledged` came at 23:15:15. So the repair had not undone the pause after 8 seconds, and whether it would have was not seen.

5. A real failure is still seen, mint only (`podman exec unbound kill -STOP 2`, 23:16:29).
- Observation from the first sample: `obs unbound unhealthy 10232 control: no answer within the deadline while the container still runs commands`.
- `unbound_fail` in `state.tsv` went 1, 2, 3 over ticks 45503-45505.
- `1793402416 nd-1793402416-45506 unbound requested restart` (23:20:16, 3 minutes 47 seconds after the stop), then `acknowledged unbound restarted: 28cb4d484e2d...` (23:20:28), then `ready observed working 40s after the acknowledgement` (23:21:08). health.log: `2026-10-30T23:20:28+0000 TICK active action=restart-component target=unbound result=acknowledged generation=45506`.

Not reached: a true hang of the runtime exec until its deadline. crun refused a frozen container at once, so the "timeout" wording of this Outcome was seen only as a refusal.

## Outcome 9
> macOS → the same triggers, but the restart rebuilds the stack (BL-038) and costs a Tor bootstrap.
Verdict: holds
Evidence:
mac, default timers, routes healthy. `container exec unbound kill -STOP 2` at 20:21:26 (1793391686). `observe`: `unbound unhealthy 10000 control: no answer within the deadline while the container still runs commands`.
```
1793391857 nd-1793391857-39817 unbound requested    restart; unbound before: unbound running 2026-10-30T19:44:12Z
1793391870 nd-1793391857-39817 unbound acknowledged unbound restarted: unbound running 2026-10-30T20:24:29Z
1793391908 nd-1793391857-39817 unbound ready        observed working 38s after the acknowledgement
```
Same trigger as Linux (requested 171 s after the freeze), but `container ls` shows all three rebuilt: pi-hole 20:24:28, unbound 20:24:29, tor-haproxy 20:24:30 (all were 19:44). Proxy generation changed a1f4b14513345b19 -> 61f0fc03f339fa28. All four routes answered with `observe` at 20:25:13, seconds after the rebuild, so the Tor bootstrap cost here was under a minute, shorter than the minutes the brief warned of.
Missing container: `container stop tor-haproxy` at 20:25:27 -> at 20:30:07 (280 s) `runtime requested repair of containers-missing: exit 0`, `acknowledged`, `ready observed working 52s after the acknowledgement`; all three containers restarted at 20:30:13-14, again a rebuild.
Full outage: Outcome 5's mac block shows the same ladder triggers, with `tor` restarted in place first.
See Material finding M1: on mac a failed route promotion stops Unbound, once with no fault injected.

## Findings

**Blocking**
- B1 (Outcome 8). An image without the route probe's tool is not indeterminate. With `dig` moved out of Unbound, `observe` says `unbound unhealthy route: probe-route exit 1:` on both hosts (`timeout` removed gives the same on mint), and on mint the controller restarted Unbound (`nd-1793393407-45358`). The `unbound-control` half is correct: `indeterminate ... no unbound-control in the image (exit 127)`.

**Material**
- M1 (mac). A failed route promotion stops Unbound and DNS, and it happened once with no fault injected. Twice the same sequence ran:
  - 21:29, no fault of mine on mac, default timers, `dig` in place since the 20:56 rebuild and the mac left alone since 20:58: `1793395746 route:cloudflare-onion requested ... promote cloudflare-onion after 5 healthy observations`, `1793395762 not-acknowledged apply_route exit 3`, then `1793395805 runtime requested repair of containers-missing`, stack rebuilt at 21:30:11-13, `1793395869 runtime ready`. health.log: `21:29:22 switch-route target=cloudflare-onion result=escalate`, `21:30:14 repair-runtime target=containers-missing`. The onion had dropped out at 21:20:32 (`route cloudflare-onion is not usable; select cloudflare-exit`). `container logs` from that stop was gone after the rebuild.
  - 20:55, `dig` moved away by me at 20:54:24: `1793393707 requested`, `1793393722 not-acknowledged apply_route exit 3`; `container ls` no longer listed unbound, `dig @172.31.240.250 example-*.org` timed out, and `container logs unbound` ended `/etc/unbound/unbound.conf:144: error: cannot open include file '/etc/unbound/route/forward-route.conf': No such file or directory`. Rebuilt at 20:56:16, ready 20:57:09.
  Each time the stack recovered unaided, after about a minute or two with no DNS. It never left the stack down, so no Outcome fails on it, but a healthy mac lost DNS because of a promotion. On mint, promotions failed against a frozen daemon without stopping Unbound. Why the route file was missing I did not establish: this demo does not read source.

**Minor**
- m1. The `containers-missing` journal entry does not name the unit (`runtime requested repair of containers-missing: exit 0`); only `observe` before the repair does.
- m2. `ready` is credited across requests: a single good check marks every open earlier request ready, e.g. `1793392751 nd-1793392455-45342 unbound ready observed working 284s after the acknowledgement` alongside the later restart. In the exit-route run, that check fell in the moment before my loop re-froze Unbound, and the journal then read "ready" while the fault persisted.
- m3. One pass ran 21:30:32 to 21:34:08 with no TICK between, spanning a bridge refresh (`21:31:04 BRIDGES outage refresh`, journal 21:33:35). It did end, but it delayed the Unbound restart of Outcome 2 to 301 s after the freeze.
- m4. On mint, reasons built from podman's stderr show podman's storage warning instead of the fault: `route: probe-route exit 1: time=... level=warning msg="The storage 'driver' option...`, and `control: exit 1:` with the same text at 21:25, when the real error was `connect: No such file or directory for /run/unbound/control.sock`.
- m5. `nice-dns-health status` has no line for the current route, outage or restart count; in these runs it showed only the schedule, install, recent TICK lines and dumps. A person must read `state.tsv` or the journal.

**Not reached**
- The real 30-minute interval: Outcomes 4 and 5 ran with tunables.tsv, as briefed.
- The reboot-needed branch of Outcome 7, because the repair worked.
- A `podman exec` that hangs until its deadline in Outcome 8; crun refused at once.
- The run took about 78 minutes against the 60 asked for.

**Left behind**
- Both hosts carry bundle 5068eae4d3535ec7; faults undone and tunables removed; mint iptables and mac pf anchor rules empty.
- Failure dumps from this demo remain: mint `failure-20261030-212608.log`, mac `failure-20261030-204212.log`.

## Scope of this report

Outcomes 1-7 and 9 were demoed on build db67a47 (run of 2026-10-30 20:20-21:38). Outcome 8 did not hold on that build. It was fixed in 4dfc273 and demoed again by a fresh evaluator on f6593fe.
owner, 2026-10-30: "Third round, short re-demo". The other eight verdicts stand on db67a47.
The route code changed between the two builds (the visibility wait in `_nd_route_reload`, proven on the live Mac). The stage suite passed 238/238 on f6593fe. On the Mac, the container CLI was also upgraded to 1.6.1 by the install of f6593fe, so only Outcome 8 was seen on that CLI.
