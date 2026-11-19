# Stage 2 premises — 2026-11-18-backlog-sweep-sub-04-harness-plan

Goal: For the person who runs Sub-plan 5: a suspend on mint cannot lose the cell, a wake is timed to its first answer, and transport security has live scenarios with a fixture twin.
Risk: LOW — harness code only. The Wi-Fi recovery runs `nmcli` on a target only after a bounded wait found no route; the fixture proves both branches.

Outcomes:
- After a suspend on a Linux target with no default route, the harness brings the Wi-Fi back once and notes `wifi-recovered`, or fails the cell with `no default route after the wake`.
- `target.sh collect --after-sleep SECS --first-answer CAP` prints a `first_answer` row and the route and proxy generation before the sleep and after the answer; the frozen one-query wake sample is unchanged.
- `tests/run.sh live transport-live` exists with a fixture twin, and its three scenarios fail on a target that does not validate DNSSEC, listens on TCP 8953, or answers under a wrong TLS name.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: on mint after a wake, the harness can read the default route and the active Wi-Fi profile, and can bring that profile up again from an ssh session.
Checked: `ssh mint 'ip route show default; nmcli -t -f NAME,TYPE,DEVICE connection show --active; nmcli general permissions; sudo -n -l'` (read-only), 2026-11-19.
Result: `default via 192.168.0.1 dev wlp12s0`; active `Auto Vodafone7EB0BF:802-11-wireless:wlp12s0` (the name has a space); network-control and wifi.scan are `auth` for the ssh session; sudo has `NOPASSWD: ALL`.
Verdict: holds, with two design consequences: the recovery runs `sudo -n nmcli` (plain nmcli would prompt), and it keys the profile by UUID, not by name.

## Premise 2
Assumption: the harness already has a first-answer sampler to reuse for the wake class (DEC-014's row).
Checked: `grep -n 'first_answer()' tests/live/target.sh`
Result: line 1184, remote side; row `first_answer<TAB>t0<TAB>us<TAB>ok|nxdomain|timeout<TAB>rcode<TAB>name<TAB>cap_ms`.
Verdict: holds

## Premise 3
Assumption: a target that validates DNSSEC shows it through the client resolver, an Unbound with remote control has no TCP 8953 listener, and a route carries a TLS name a fault can change.
Checked: on mint, `dig @127.0.0.1 [+adflag|+dnssec] cloudflare.com`, `dig @127.0.0.1 dnssec-failed.org`, `podman exec pi-hole dig @127.0.0.1 -p 5335 cloudflare.com`, listening sockets from `/proc/net/tcp*` inside the pod, Unbound's `control-interface`; on mac, the same digs at 172.31.240.250 and 172.31.240.251#5335 and `nc -z 172.31.240.251 8953`; `unbound/route/forward-route.conf`. 2026-11-19, read-only.
Result: dnssec-failed.org is SERVFAIL through Pi-hole on both; cloudflare.com is NOERROR but Pi-hole never sets `ad` (not even with +adflag); Unbound on 5335 sets `ad` on both; no 8953 listener (mint ports 53, 80, 443, 853, 5335, 9050, 18531-18533; mac closed); `control-interface: /run/unbound/control.sock`; the route is `forward-addr: 127.0.0.1@853#tor.cloudflare-dns.com`.
Verdict: holds, with one design consequence: TL-DNSSEC reads `ad` at Unbound's own listener (Pi-hole strips it), and validation through the client resolver is shown by the SERVFAIL. The wrong-TLS-name SERVFAIL itself is not checkable here without changing a live target — Sub-plan 5's live run checks it.
