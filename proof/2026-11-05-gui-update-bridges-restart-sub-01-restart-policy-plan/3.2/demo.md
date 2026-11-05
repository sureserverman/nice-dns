# Task 3.2 — macOS per-container restart qualification (2026-11-05, mac, container 1.6.1, macOS 27.2)

Question: does `container stop <c>` then `container start <c>` keep the
container's address and leave the chain resolving, so Unbound and Pi-hole
could restart alone (per-container) instead of the stack kickstart?

Procedure: `tests/live/target.sh` ops on `mac` only: snapshot,
quiesce-agents (the health controller booted out so it could not repair
first), stop-container, start-container, probe (address), fresh-name every
15 s for up to 300 s; resume-agents. Script: q32.sh (session scratchpad).

## Result: not qualified — the kickstart stays

```
quiesce	quiesced	org.nice-dns.health	rc=0
quiesce	absent	org.nice-dns.bridge-eval
quiesce	quiesced	org.nice-dns.health-bridges	rc=0
quiesce	loaded	org.nice-dns.start-container
container	unbound	want	172.31.240.251
before	unbound	running	172.31.240.251/29	started	2026-11-01T11:51:17Z
stop	unbound	rc=0
stopped	unbound	stopped	-
start	unbound	rc=0
after	unbound	running	172.31.240.253/29	started	2026-11-05T17:33:22Z
address_kept	unbound	no (172.31.240.253)
fresh_name	unbound	timeout	after_s	314
repair	nice-dns restart (the stack is rebuilt)
restart	rc=0
resume	loaded	org.nice-dns.health
resume	absent	org.nice-dns.bridge-eval
resume	loaded	org.nice-dns.health-bridges
qualified	no
```

Unbound came back from `container start` at 172.31.240.253, not .251. The
vmnet allocator hands out the next free address, and Apple's runtime has
no `--ip` flag (apple/container#282, mac/start-container.sh:16-23). Pi-hole's
upstream and the route include hardcode .251, so no fresh name answered
for 314 s. The Pi-hole leg was not run: the Unbound result already shows a
per-container restart can move an address the stack is wired for.

Repair: `nice-dns restart` (the stack kickstart) at 17:39Z restored
.250/.251/.252, and a fresh name answered NOERROR right after.

Decision under the plan: `nd_platform_restart_unbound` and
`nd_platform_restart_pihole` on macOS keep the stack kickstart, and
`tests/integration/recovery-actions.sh` keeps asserting it
(t_pihole_restart_journals_requested_acknowledged_ready, the Unbound case).
The finding is recorded on BL-038. A per-container restart would need a
fixed address (apple/container#282) or rewiring Pi-hole and the route to
the address the restart actually got.
