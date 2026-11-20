# Qualification: release, compatibility and rollback notes

Sub-plan 5 of the stability, latency and security plan (measured tuning and
live qualification). Nothing here is tagged, pushed or merged: these notes
say what has to happen, in which order, when it is.

## What is qualified

The candidate is nice-dns on branch `sub05-qualification` together with two
unreleased proxy builds, tested as the targets built them from source:

| Repository | Commit | State |
|---|---|---|
| nice-dns | branch `sub05-qualification` | not merged |
| tor-haproxy | `1933059` (7 commits after the released `v2.14`, `13025d7`) | not released |
| tor-socat | `2e0623d` (6 commits after the released `v2.10`, `3ce59ab`) | not released |
| hardened-unbound | `9aaf5c6` (`v1.4.0`) | released |
| pi-hole-hardened | `4574d52` | local sibling, not published |

The evidence is a chain of receipts under
`~/.local/state/nice-dns-tests/receipts/`. The final one is written by
`tests/run.sh plan qualification --fresh-fixtures --include-slow --live
--targets tests/live/targets.env --matrix all --reuse-verified-soak` and
links the baseline, transport, controller, installers and soak receipts.
`tests/run.sh receipt qualification --require-matrix all ...` verifies it.

The report comes from that receipt only:

```sh
python3 tests/reports/qualification-report.py \
  ~/.local/state/nice-dns-tests/receipts/qualification/<run>/receipt.tsv
```

It refuses a chain that does not verify, recomputes every number from the
pinned samples and labels each proof by kind (actual host, fixture).

What stands for what (user decisions of 2026-10-06):

- The 24 h soak (run `20261005T060405Z-13de27b1`: mint 4/864 and the mac
  1/864 uncached timeouts, every sleep and network-loss event recovered, no
  manual repair) and its latency stand for their platform:
  linux/haproxy/standard and macos/socat/standard.
- Each of the eight cells (Linux and macOS, haproxy and socat, standard and
  hardened Pi-hole) is installed on its host and checked for cold start, no
  direct query and network loss.
- The soak judges timeouts and failures at no more than 1 in 100; latency
  (p95) is recorded, not gated. The frozen Sub-plan 1 limits still drive the
  Stage 1 comparisons.

## Release order

The candidate ran the proxy builds above, not the images
`release/images.lock` pins today. So:

1. Release tor-haproxy and tor-socat from those commits (their CI builds the
   multi-arch images).
2. Re-pin `release/images.lock` to the new tags. `update-images-lock.sh
   --write` refreshes only the digest of the tag a row already names, so first
   set each proxy row's `tag`, `version` and `source` commit by hand
   (docs/release-inputs.md), then run `scripts/update-images-lock.sh --write`
   and check the new digests and commits.
3. Check the released images on each platform before the merge: the
   candidate cells ran proxies built on the targets from these commits, not
   the CI builds the lock now pins. An install from the re-pinned lock with a
   cold start and a no-direct check per platform is enough (the
   `live/qualification-cells` checks).
4. Then merge nice-dns. An install from `main` before step 2 would run the
   old proxies, which lack the readiness and restart fixes below.

## Behavior changes

Installs and the controller:

- **Bridges are judged by stream success.** The daily refresh leaves out a
  bridge with at least 20 uses and under 90% success, remembers it for 30
  days, and restarts the proxy once when the running one still uses it (DNS
  fails closed for about 15 s on Linux). On macOS the restart rebuilds the
  whole stack, not only the proxy. See `health/README.md`.
- **Linux boot bridge selection really skips** when a usable set exists. Its
  skip status used to count as success, so every install and boot re-picked
  bridges over the controller's set.
- **macOS scoped DNS stays on the container bridge.** A pf anchor keeps
  interface-scoped queries for the stack's address off the LAN gateway.
- **Unbound starts on the exit route** when the proxy is fresh, and the
  controller promotes the onion route after it proves healthy.

Proxy images (the unreleased commits):

- Readiness is a working Tor stream, not only "bootstrapped".
- Tor's log is kept on the data volume (`/app/data/tor.log`, one previous
  copy).
- A proxy child (haproxy, socat or tor) that exits unrequested fails the
  container; tor-haproxy used to exit 0 in that case and no longer does.
- After a host sleep, a Tor whose streams died is restarted.

## Compatibility

- **routes/providers.tsv is unchanged** in this sub-plan, so and-hole and
  nice-dns-android, which mirror the resolver list, need no change.
- **multitor** fetches bridges the same way. The stream-success rule is new
  here and worth porting, because a bridge that bootstraps can still stall
  onion streams (Tor drops a timed-out onion stream but keeps its circuit).
  Nothing breaks if it is not ported.
- The proxy images keep their ports and environment. The data volume now
  holds `tor.log`; anything that wipes the volume loses it, nothing more.

## Rollback

- **A failed install** restores the previous generation by itself.
- **Back to the previous nice-dns** after a release: run the previous
  version's installer (its branch as the second argument). The generation it
  replaces keeps its images until the install after next. Then delete the
  controller's state file (below).
- **Back to the previous proxies:** re-pin `release/images.lock` to the
  `v2.14` / `v2.10` digests and reinstall.
- **The controller alone:** `health/nice-dns-health install` from the
  previous checkout installs that version's bundle in place. Then delete the
  controller's state file (below).
- **The controller's state file after any rollback:** a controller from
  before this release refuses the `proxy_gen` key this one writes, and does
  nothing until the file is gone (BL-036). Delete
  `~/.local/state/nice-dns/controller/state.tsv` (Linux) or
  `~/Library/Application Support/nice-dns/controller/state.tsv` (macOS); a
  controller with no state file starts from its defaults.

## Platforms

Debian 12 and Whonix 17 are not supported (user decision 2026-10-06): their
mawk (1.3.4 20200120) has no regex intervals, which the controller's state
check, its observation check, the release-lock reader and the tunables
reader use. Qualified: Linux Mint 22.3 (Ubuntu 24.04 base) and macOS 26.

## Limits lifted by this sub-plan

The receipt chain links receipts from earlier sub-plans, and their limit
rows are what was true at their own commit. Three no longer hold:

- `route-mount` (installers receipt) and `route-apply` (controller
  receipt): every deployment now mounts and seeds `/etc/unbound/route`
  (DEC-010, Task 1.2); live `route-apply` passed on both platforms (runs
  `20260928T184518Z-477abaa6`, `20260928T185705Z-7040c4bf`).
- `ready-corroboration` (controller receipt): the Unbound image has a
  `probe-route`, used for restart readiness (DEC-006, Stage 1).

## macOS per-container restart (2026-11-05, not qualified)

Restart-policy plan, Task 3.2, on the mac (container 1.6.1, macOS 27.2).
The question was whether Unbound and Pi-hole could restart alone on
macOS (`container stop <c>`, then `container start <c>`) instead of
rebuilding the stack (BL-038).

The test used `tests/live/target.sh` ops on the mac only, with the health
controller quiesced so it could not repair first: stop-container,
start-container, probe for the address, then a fresh name every 15 s for up
to 300 s.

| Step | Unbound |
|---|---|
| before | running at 172.31.240.251 |
| stop, start | both exit 0 |
| after | running at **172.31.240.253** |
| fresh name | `timeout` after 314 s |

The vmnet allocator hands out the next free address, and Apple's runtime
has no `--ip` (apple/container#282, mac/start-container.sh:16-23). Pi-hole's
upstream and the Unbound route are wired to .251, so the chain stayed down.
`nice-dns restart` (the stack rebuild) restored .250/.251/.252, and a fresh
name answered NOERROR right after. The Pi-hole leg was not run: the Unbound
result already shows that a per-container restart can move an address the
stack is wired for.

Result: not qualified. On macOS, Unbound and Pi-hole restarts keep the stack
kickstart (lib/platform/macos.sh, `nd_platform_restart_unbound` and
`nd_platform_restart_pihole`), and integration/recovery-actions asserts it.
A per-container restart needs a fixed address or a stack that follows the
address a restart gets (BL-038).

## macOS install over ssh (2026-11-19)

Backlog sweep Sub-plan 3, Task 2.3, on the mac (macOS 27.2.1, container CLI
1.7.1, FileVault off, sudo without a password for the user). The install
was run over plain ssh, outside the user's login session:
`ssh mac '~/.local/bin/nice-dns reinstall --branch sweep-macos'`.

| Run | Commit | Result |
|---|---|---|
| 15:26 UTC | b5050a8 | stopped in preparation: "Homebrew not found" (the ssh PATH held no Homebrew directory); nothing changed |
| 15:43 UTC | 8914b88 | installed; DNS answered; but the fresh-datapath restart did nothing (the apiserver kept its 15:43:57 start) |
| 17:01 UTC | 757dd8c | installed in 77 s; the apiserver restarted at 17:02:05, at the fresh-datapath step |

After the 17:01 run: `dig @172.31.240.250 cloudflare.com` answered; the
scoped-DNS anchor held its pass rules on `bridge100` and its block rules;
`container ls -a` listed no `buildkit`; the start-container agent found
the runtime ready and the stack healthy (17:02:17). Over ssh a direct
`container system status` still prints "apiserver is not running and not
registered with launchd"; the installer reaches the runtime through
`launchctl asuser` (root-ops `runtime`).

`container system df`, before the first run and after the last:

| Type | Before (15:25) | After (17:02) |
|---|---|---|
| Images | 43, 33.81 GB, 32.37 GB reclaimable | 43, 33.84 GB, 32.8 GB reclaimable |
| Containers | 4 (3 active), 2.18 GB, 1.05 GB reclaimable | 3 (3 active), 1.06 GB, 0 B reclaimable |
| Local volumes | 2, 354.9 MB | 2, 354.9 MB |

The builder's 1.05 GB went with it. The images are not pruned: the
previous generation is kept for a rollback, and a prune would also remove
the runtime's init image (README, "Disk use on macOS").

Not shown: an ssh install that has to ask for a sudo password (this mac's
user has a NOPASSWD rule), and a Mac with no one logged in (fixture case
only).

## macOS pre-login start

Backlog sweep Sub-plan 3, Task 3.1 (BL-058), on the mac (macOS 27.2.1,
container CLI 1.7.1, FileVault off, no automatic login), 2026-11-19. The
question: can Apple's container runtime, and then the stack, start before
anyone logs in?

A scratch daemon, /Library/LaunchDaemons/org.nice-dns.spike-prelogin.plist
(`UserName` the install's user, `RunAtLoad`, no `KeepAlive`), ran at boot
`container system start --disable-kernel-install --timeout 120`, then
`container system status`, then the installed
/usr/local/sbin/start-container.sh, logging to /tmp/nice-dns-spike.log. The
mac was rebooted at 17:59:18 UTC (the owner said go, OD-3); ssh answered at
17:59:54 with no user logged in.

What the daemon logged (`launchctl managername` there: `System`):

```
spike start 2026-11-19T17:59:44Z uid=501 managername=System
Launching container-apiserver...
Testing access to container-apiserver...
Error: internalError: "failed to get a response from apiserver: interrupted: "XPC connection error: Connection invalid""
system start rc=1 17:59:44
apiserver is not running and not registered with launchd
system status rc=1 17:59:44
start-container rc=1 18:00:22   (its log: "container system never came up", after 10 tries)
```

Read over ssh before login, each under a 60 s limit: `container system
status` printed "apiserver is not running and not registered with
launchd"; `container ls -a` failed ("XPC connection error: Connection
invalid"); `dig @172.31.240.250 cloudflare.com` timed out (host DNS stays
pinned to the stack, which is not up); no container-apiserver process. The
scratch daemon was then booted out and removed (no spike runtime existed to
stop), and the owner logged in; the start-container agent started the
runtime in the login session (apiserver 18:01:06), rebuilt the stack on
its addresses (18:01:15) and DNS answered again at 18:01:36.

verdict: does not start

So on this macOS the Mac has no DNS after a reboot until its user logs in,
and a system LaunchDaemon does not change that: the runtime did not start
from one. Other routes (a bootstrap into user/<uid>, say) were not tried.
Automatic login (System Settings, Users & Groups; macOS allows it only with
FileVault off) is the recommendation for DNS after an unattended reboot; it
was not tested here, and it lets anyone at the Mac into the account.

## Live pass of the backlog sweep

Backlog sweep Sub-plan 5, Stage 1: the merged sweep (Sub-plans 1 to 4),
installed from this checkout's committed HEAD on mint (Linux Mint 22.3,
podman 5.8.1) and the mac (macOS 27.2.1, container CLI 1.7.1), one cell per
platform, the proxy each target ran (tor-socat) with the standard Pi-hole.

| Group | Date | Run | Commit | Result |
|---|---|---|---|---|
| install-lifecycle | 2026-11-19 | `20261119T222036Z-80f918ba` | 0df52e8 | 6/6 on both targets |
| container-faults | 2026-11-19 | `20261119T223433Z-7180b627` | 4a0fb5c | 9/9; receipt assembled and verified by the group |
| bridges-toggle | 2026-11-19 | `20261119T232058Z-73a63573` | 4a0fb5c | 11/11, BT-ON-FEW included; receipt assembled and verified by the group |
| transport-live | 2026-11-19 | `20261119T233236Z-8f43d2c3` | 07d87a4 | 7/7; scenario rows from both targets; receipt assembled and verified by the group |

install-lifecycle: an upgrade over the older install, a reinstall that kept
the Tor, anchor and list marks, an uninstall, and a final install. During
the uninstall the host resolver was sampled every 2 s: each sample was the
stack or the state from before nice-dns, never anything else (mint 29
samples, the mac 12), and the installer's log restores DNS before it
removes the network (mint: "restored the resolver state from before
nice-dns", then `dnsnet`, then "Uninstalled."). After the final install
each target holds one generation directory (read with `ls` on the
generations directory; mint held 191 before the sweep, BL-061). Over ssh
pkexec has no authentication agent and exits 127, so each root step ran
through sudo, as `lib/root.sh` does by design.

container-faults: every recovery was the controller's own, on its real
timers. A frozen Pi-hole came back on both targets (a fresh name 299 s
after the freeze on mint, 229 s on the mac; Pi-hole working 29 s after the
restart on each). On mint a paused Unbound was repaired by the runtime in
226 s, and 4 proxy crashes 75 s apart gave one crash-loop escalation
("tor-socat restarted 3 times in 600 s ... the controller adds no restart")
and a fresh name 404 s after the first crash. On the mac a stopped Unbound
was rebuilt (containers-missing) and a fresh name answered 124 s after the
stop.

bridges-toggle: off and on came back on both targets (off 24 s and on 29 s
on mint, 22 s each on the mac, each from the command to "DNS is
answering"). BT-ON-FEW (mint only): with bridges.env cut to 2 of its 7
bridges, off then on took 139 s, over the proxy's 120 s restart bound,
which the scenario reports and does not gate. The extra time is the host's
bridge selection, which runs first with fewer than 3 bridges (the restart
was acknowledged 87 s after the request) and refilled the set: Tor came
back with 7 bridges and a fresh name answered. `nice-dns bridges on` exited
0 with "Bridges are on; the proxy restarted and DNS is answering", inside
the 1-4 min its own wait message gives. bridges.env was then put back and
the stack restarted onto it. mint ends this group with bridges on (it had
been off since Sub-plan 4).

transport-live: until this run no receipt carried a macOS transport
security proof (BL-042); run `20261119T233236Z-8f43d2c3` carries one for
each platform, on the stack each target ran (nothing installed). On both:
through Pi-hole a signed and an unsigned name answer and
dnssec-failed.org is SERVFAIL; at Unbound's listener the signed name
carries `ad` and, with checking disabled (`+cd`), dnssec-failed.org's data
arrives, so its SERVFAIL is validation. Nothing listens on TCP 8953 in the
Unbound container; its control interface is the Unix socket
/run/unbound/control.sock, and it answers. With the route's TLS name set
at runtime to `nd-wrong-name.invalid` (same address and port), three fresh
names were SERVFAIL; healed, a fresh name answered (mint on
cloudflare-exit, the mac on cloudflare-onion).

## Compat route certificate

Backlog sweep Sub-plan 5, Task 1.4 (BL-040), on mint, 2026-11-19. The
legacy `:853` route (`cloudflare-legacy` in `routes/providers.tsv`, name
`tor.cloudflare-dns.com`) was never proven live to present a certificate
that verifies for its name. From inside the pod (the Unbound container's
openssl; the proxy images carry no TLS client) a handshake to
`127.0.0.1:853` asked for that name, with verification on:
`openssl s_client -connect 127.0.0.1:853 -servername tor.cloudflare-dns.com
-verify_hostname tor.cloudflare-dns.com -CAfile
/etc/ssl/certs/ca-certificates.crt -verify_return_error`. mint ran tor-socat,
then `nice-dns switch proxy haproxy` (23:34-23:37 UTC, "Switched: the proxy
is now tor-haproxy, and DNS is answering"), then `nice-dns switch proxy
socat` put it back (23:38-23:42 UTC).

| Proxy | Time (UTC) | Subject | Names | Result |
|---|---|---|---|---|
| tor-socat | 23:34:34 | CN=cloudflare-dns.com, O=Cloudflare, Inc. | cloudflare-dns.com, *.cloudflare-dns.com, one.one.one.one, 1.1.1.1, 1.0.0.1 and six more addresses | verify=ok (return code 0, "Verification: OK") |
| tor-haproxy | 23:37:57 | CN=cloudflare-dns.com, O=Cloudflare, Inc. | the same | verify=ok (return code 0, "Verification: OK") |

`tor.cloudflare-dns.com` verifies through `*.cloudflare-dns.com`. The route
stays (decision of 2026-11-18, proven 2026-11-19, owner: "Keep, prove once"): it fails closed,
and installs seed identity routes, so it is only the image default. In
haproxy's log over the switch window: no line at error level; one
`[WARNING]`, haproxy's own "Server dns_resolvers/primary is UP".

## Update schedule firing

Backlog sweep Sub-plan 5, Task 2.1 (BL-066). Does the twice-daily update
check fire by itself on a live host? Read only, after Stage 1 had
reinstalled both targets (git-archive installs, so the check can only say
`unknown`: it needs a clean commit). Nothing was started by hand.

| Platform | Host | Slot | Fired | The scheduler's own record | What followed |
|---|---|---|---|---|---|
| linux | mint | 2026-11-20 00:24:19 UTC (the timer's slot, randomized delay) | fired=own | `LastTriggerUSec=Fri 2026-11-20 00:24:19 GMT`; journal: "systemd[1062]: Starting nice-dns-health-update.service - nice-dns update check (checks only; installs nothing)..." at 00:24:19 | checked_at 1795134259 (00:24:19 UTC); health.log "UPDATE-CHECK rc=1 unknown: the installed source was not a clean commit" (a git-archive install records no commit) |
| macos | mac | 2026-11-20 04:47 GMT (StartCalendarInterval 04:47 and 16:47) | fired=own | unified log: "UserEventAgent[706] [com.apple.xpc.activity:calendarinterval] Running StartCalendarInterval: org.nice-dns.health-update" at 04:47:04.857; `launchctl print`: runs = 1, last exit code = 0; update.out.log and update.err.log written 04:47 | checked_at 1795150025 (04:47:05 UTC); health.log "UPDATE-CHECK rc=1 unknown: the installed source was not a clean commit" |

On both platforms the schedule fired at its slot by itself, the check ran
within a second and wrote `checked_at`; its result is `unknown` only
because these installs record no commit. The Linux timer's slot moves
inside its randomized delay (12:25:35 on 2026-11-19, 00:24:19 and the next
at 12:28:19 on 2026-11-20).

## First answer after a macOS wake

Backlog sweep Sub-plan 5, Task 2.3 (BL-025, BL-039 item 3), on the mac
(macOS 27.2.1, tor-socat, standard Pi-hole), 2026-11-20 02:43-03:00 UTC,
run `20261120T024347Z-wake6832`. Ten times `target.sh collect mac
--workload wake --count 1 --after-sleep 60 --first-answer 300`: the mac
sleeps 60 s and wakes by its own alarm; fresh names are asked through
Pi-hole until one is answered, timed from the wake (the link wait
included, DEC-014's row); the route and the proxy's container are read
before the sleep and after the answer.

The first try of this run (02:28) found a harness fault: the Mac wakes on
network (`womp 1`), and target.sh's own ssh keepalive woke it after 26 s
and 4 s of a 60 s sleep (power log: "due to ... E_RX_IP_PACKET"); the
26 s nap passed as a wake. Fixed in c7a0557: the sleeping call sends no
keepalive, and a sleep more than 10 s short is refused. Every wake below
slept whole (`slept` 66-68 s, woken "due to ... rtc"). The 2026-10-01
idle/wake samples that opened BL-025 ran with the same keepalive and may
have been naps.

| Wake | Slept (s) | Link up (UTC) | first_answer (s) | rcode | Route before / after | Proxy container |
|---|---|---|---|---|---|---|
| 1 | 67 | 02:45:01 | 16.39 | NOERROR | cloudflare-onion 62 / cloudflare-onion 62 | same |
| 2 | 66 | 02:46:42 | 11.80 | NOERROR | cloudflare-onion 62 / cloudflare-onion 62 | same |
| 3 | 67 | 02:48:23 | 7.99 | NOERROR | cloudflare-exit 256 / cloudflare-exit 256 | same |
| 4 | 68 | 02:50:01 | 4.38 | NOERROR | cloudflare-exit 256 / cloudflare-exit 256 | same |
| 5 | 68 | 02:51:36 | 12.27 | NOERROR | cloudflare-exit 256 / cloudflare-exit 256 | same |
| 6 | 67 | 02:53:22 | 8.43 | NOERROR | cloudflare-exit 256 / cloudflare-exit 256 | same |
| 7 | 67 | 02:54:55 | 26.81 | NOERROR | cloudflare-exit 256 / cloudflare-exit 256 | same |
| 8 | 66 | 02:56:50 | 7.22 | NOERROR | cloudflare-exit 256 / cloudflare-exit 256 | same |
| 9 | 68 | 02:58:27 | 12.63 | NOERROR | cloudflare-exit 256 / cloudflare-exit 256 | same |
| 10 | 67 | 03:00:08 | 10.02 | NOERROR | cloudflare-exit 256 / cloudflare-exit 256 | same |

The run's ten `first_answer` rows, as written (the wake, microseconds from
the wake to the first answer, outcome, rcode, name, cap in ms). "Link up"
in the table is the harness's `woke` line, written after the link wait
(0 or 4 s after the wake):

```
first_answer	2026-11-20T02:44:57.522121Z	16392028	ok	NOERROR	42d1b0896807c631.example.com	300000
first_answer	2026-11-20T02:46:42.512495Z	11795367	ok	NOERROR	7c7c83c342ef7d54.example.com	300000
first_answer	2026-11-20T02:48:23.526983Z	7985825	ok	NOERROR	16a50bd21546d778.example.com	300000
first_answer	2026-11-20T02:50:01.432677Z	4376226	ok	NOERROR	5131790ae5441cf1.example.com	300000
first_answer	2026-11-20T02:51:36.479129Z	12269073	ok	NOERROR	f26d74155901e129.example.com	300000
first_answer	2026-11-20T02:53:18.469659Z	8432621	ok	NOERROR	22c71a4ebb116ed2.example.com	300000
first_answer	2026-11-20T02:54:55.531936Z	26812162	ok	NOERROR	22d43dc9d8d14567.example.com	300000
first_answer	2026-11-20T02:56:50.551673Z	7218526	ok	NOERROR	5780dcf328114b8c.example.com	300000
first_answer	2026-11-20T02:58:27.502728Z	12625998	ok	NOERROR	2cb1c3ca1bb036a3.example.com	300000
first_answer	2026-11-20T03:00:08.527458Z	10015889	ok	NOERROR	bd22413080ae9f35.example.com	300000
```

Median 10.91 s, maximum
26.81 s; every wake answered, none timed out. The bar (this plan): the
wake is Tor's own if the median over 10 wakes is 20 s or less.

BL-039 item 3 (a suspend respawn does not bump the generation the policy
reads): across every wake the proxy kept its container (tor-socat,
started 2026-11-19 23:26:59 UTC) and the route its generation; no wake
respawned the proxy, so there was no respawn to miss. The route moved
from cloudflare-onion to cloudflare-exit between wakes 2 and 3, a
controller switch outside any wake.

verdict: accepted

## macOS steady cold latency, interleaved

Backlog sweep Sub-plan 5, Task 2.4 (BL-035), on the mac (macOS 27.2.1,
container CLI 1.7.1), 2026-11-20 05:50-06:12 UTC, run
`20261120T055003Z-b87d457d`: `tests/run.sh live tune-transport --live
--targets tests/live/targets.env --platforms macos --proxies socat
--comparison baseline`. The group accepts only `--proxies all`, so its
option case (t_0_options) failed; with `--platforms macos` the cell is
macos/socat/standard either way, and the three measuring cases passed
(interleaved comparison, private evidence, the candidate within the frozen
limits). One cell, two arms swapped in strict alternation over 10 blocks,
the same session (DEC-013):

- baseline: b85bc9b's Unbound and Pi-hole images rebuilt on the mac, and
  tor-socat v2.9, on that release's own legacy route (it starts on its exit
  backup, tests/live/tune-transport.sh);
- candidate: the merged sweep (e7780b8's product files, equal to main's)
  with the proxy built from tor-socat 0e587fd, on the identity route
  cloudflare-exit (generations 441-459, read back in every block).

| Class | n per arm | p50 baseline | p50 candidate | p95 baseline | p95 candidate | Blocks better | Timeouts |
|---|---|---|---|---|---|---|---|
| cold (miss) | 90 | 385 ms | 86 ms | 594 ms | 194 ms | 10 of 10 | 0/90 each |
| warm (hit) | 1000 | 4.38 ms | 4.35 ms | 4.78 ms | 4.76 ms | 5 of 10 | 0/1000 each |
| after restart | 10 | 20.3 s | 17.0 s | 28.4 s | 22.6 s | 7 of 10 | 0/10 each |

Cold p50 is 300 ms faster (95% interval 264-357 ms, p_not_better 0.000),
and p95 too, against the frozen 636 ms target (pass). The candidate's p95
and p99 rest on 90 samples (the comparator marks them exploratory). The
2026-10-05 soak had macOS steady-state cold p50 297 -> 406 ms and p95
636 ms -> 1.8 s against the frozen baseline (BL-035); in the same session
with the same baseline the candidate is not slower, it is faster. The bar
(DEC-016's no-regression rule, this plan): p50 and p95 no worse than the
same-session baseline arm. Both arms ran on the exit route (the baseline
on its exit backup, the candidate on cloudflare-exit), so this compares
the exit route only; the soak's regression came while the onion route
carried about 93% of the time, and that is not measured here. The group's
result was FAIL, on its option case alone; it was not rerun with
`--proxies all`.

The mac ended on the candidate's deployment (generation
20261120T060851Z-nogit0000000, cloudflare-exit), answering.

verdict: accepted

## Fresh names while Mullvad is disconnected

Backlog sweep Sub-plan 5, Task 2.5 (BL-046). Not measured anew: on
2026-11-20 the VM's Mullvad account had expired (2026-11-11 02:43 UTC;
`mullvad status` stayed "Connecting", the daemon timing out on the relay),
so no connect could be made. nice-dns main (710031f) was installed there by
the README's line and answered. By the owner's decision (2026-11-20, "Close
on old numbers") BL-046 is closed on the numbers already taken, which are
old and short: 2026-10-12 in the same VM (nice-dns
20261011T181512Z-2a5ed555dc5c, tor-haproxy, Mullvad 2026.3, custom DNS
127.0.0.1, lockdown off), 3 cycles per arm of `mullvad disconnect`, 120 s,
`mullvad connect`, 300 s, a fresh label every 5 s with `dig +time=3
+tries=1 @127.0.0.1`. Arm a is the controller alone; arm b added the first
rung (the in-image Tor restart request) within 5 s of each transition,
connect included, not of the disconnect only. Cycle a/2 was rerun (a2r)
after a multitor test touched Tor during it.

Time to the first fresh answer (s; "none" = no answer in the window):

| Arm | Cycle | Transition | First fresh answer | Window |
|---|---|---|---|---|
| a | 1 | disconnect | none | 120 |
| a | 1 | connect | 42.2 | 300 |
| a | 2r | disconnect | 85.8 | 120 |
| a | 2r | connect | 135.9 | 300 |
| a | 3 | disconnect | none | 120 |
| a | 3 | connect | 35.9 | 300 |
| b | 1 | disconnect | 70.5 | 120 |
| b | 1 | connect | 87.1 | 300 |
| b | 2 | disconnect | 70.7 | 120 |
| b | 2 | connect | 97.4 | 300 |
| b | 3 | disconnect | 96.6 | 120 |
| b | 3 | connect | 85.8 | 300 |

Medians, disconnect: arm a over 120 s (two of three windows never
answered), arm b 70.7 s. Connect: arm a 42.2 s, arm b 87.1 s (the restart
costs a rebootstrap). On 2026-10-13/14 (anon-meta round 2, the controller
alone) 0 of 40 fresh labels answered while disconnected in every run, and
the first answer after connect came at 75-392 s. No DNS left the host in
any of these runs (BL-046: it fails closed).

The bar (this plan): a disconnect-only fast path is worth building only if
the first-rung arm's median beats the controller-alone arm's by 60 s or
more over 5 cycles. These numbers show at least 49.3 s (over 120 s against
70.7 s) on 3 cycles, a window too short to show more, and arm b's rung also
ran at each connect: the bar is neither shown met nor shown missed. The
entry is closed on these numbers by the owner's decision (Sub-plan 5 OD-8,
"Close on old numbers"), not by the bar, and no fast path is built (as the
owner decided on 2026-10-12). What stays true: while Mullvad is disconnected, fresh names mostly fail until
the tunnel is back, and fail closed.

verdict: accepted

## Onion stall lengths

mint, 2026-11-20 02:27-08:27 UTC, tor-socat, bridges on, route
cloudflare-onion. Every 10 s (start to start), one DNS-over-TLS query from
inside the pod to the onion route (`127.0.0.1:18531`, name
`tor.cloudflare-dns.com`, certificate verified, `+time=60 +tries=1`), a new
connection each time, timed end to end. A stall is a run of queries that
waited over 20 s (Sub-plan 5 OD-7). The mac is not measured: its proxy logs
before the plan's own reinstall are gone (OD-6). mint's controller had
selected cloudflare-onion at 02:25:11 and did not switch route during the
probe, so the probed route was also the one mint's clients used.

| Measure | Value |
|---|---|
| Queries | 2158 over 21600 s |
| Answered NOERROR | 2156 |
| Failed fast | 2 (471 ms and 328 ms, 05:38:35 and 07:43:32) |
| Stalls (over 20 s) | 0 |
| Stall lengths | none |
| Slowest answer | 16.0 s (06:03:27), then 9.5, 7.7, 6.7, 6.2, 6.1 s |
| Wall time p50 / p95 / p99 | 1.19 / 2.15 / 3.20 s |

The share of the measured time spent in stalls is 0 of 21600 s. The two
failures did not wait. Each matches one tor-socat journal line at the same
second, `socks: connect request rejected or failed`: Tor turned the connect
down at once, and the next query 10 s later answered. Counted as stalls,
they would be 20 s of 21600 s, a share of 0.09%. Both readings are under
the 1 in 100 bar (DEC-017), so no onion failover is filed.

verdict: accepted

## The 1.1.1.1 query

BL-059: a network-fault window on mint once recorded a query to
1.1.1.1:53 while a bridge refresh ran. Traced on mint, 2026-11-20, with a
packet capture (`target.sh capture-dns mint --count 3`, run
20261120T083627Z-capcb7a, which refreshes the bridge pool once) and a
kernel trace (bpftrace on `udp_send_skb`, `udp_v6_send_skb` and
`tcp_connect`) of the process and cgroup behind every packet to port 53
or 853.

- With the network up, no packet went to 1.1.1.1 on either port. The
  refresh (result `changed`) ran the proxy image's `bridge-eval`, which
  resolved Moat and rdsys over DNS-over-HTTPS: one TCP connect to
  1.1.1.1:443 per fetch. Its only port-53 traffic was obfs4 to a pool
  bridge that listens on port 53. The capture's canary to 9.9.9.9:53 was
  seen, so the capture worked.
- With 1.1.1.1:443 dropped on the host (a test table, lifted after 24 s),
  `bridge-eval -list-sources` sent 4 UDP queries to 1.1.1.1:53. The trace
  names the sender: process `bridge-eval` in its own `podman run`
  container, forwarded by that container's pasta. It also tried
  9.9.9.9:443 and 8.8.8.8:443, and the fetch still returned its
  candidates. The binary holds `1.1.1.1:53`, `9.9.9.9:53` and
  `8.8.8.8:53` as its fallback resolvers.

So the query of BL-059 is bridge-eval's own bootstrap resolver, used when
its DNS-over-HTTPS lookup fails, as it does under a network fault. It is
not `scripts/fetch-bridges.sh:108`, which Linux never runs. It is not
aardvark's `DNS=1.1.1.1` (`deb/quadlet/nice-dns.network:5`) either: the
sender is not on dnsnet. `release/bootstrap.tsv` (row `bridges`: "bridge-eval
resolves Moat and rdsys with its own bootstrap resolver") and
docs/workflows/dns-lifecycle.md ("Bridge fetch traffic is a declared
bootstrap exception") declare it. It carries only the Moat and rdsys
names, never a client query (DEC-001 holds). That row's phase column names
the install's bridge selection; the daily refresh runs the same fetch.

declared=yes

## Proxy and Tor errors over a day

The 24 h to 2026-11-20 08:42 UTC. Counted at level error or above: Tor
`[err]`, socat `E`/`F`, haproxy `[ALERT]` and above. Each Tor log covers
only its container's life: Tor writes `/app/data/tor.log` (and
`tor.log.prev` from the start before), not the container log.

| Target | Source | Covers | Error or above | Warnings |
|---|---|---|---|---|
| mint | tor-socat, journal | 24 h | 1 socat `E` | 161 socat `W` |
| mint | Tor, `tor.log` + `.prev` | 2026-11-19 23:30 on | 0 | 94 |
| mint | tor-haproxy, journal | 23:37-23:41 (Task 1.4) | 1 `[ALERT]` | 3 |
| mac | tor-socat, `container logs` | 08:09 on | 0 | 19 socat `W` |
| mac | Tor, `tor.log` + `.prev` | 2026-11-20 06:08 on | 0 | 6 |
| mac | the agent's log | 2026-11-19 15:45 on | 0 proxy or Tor | - |

- mint's socat `E` is one `Connection reset by peer` (02:00:15), a
  single dropped connection. Its warnings are 106 `socks: connect request
  rejected or failed` (fast refusals by Tor, as in the onion probe), 52
  `exiting on signal 15` (child stops at restarts), 2 `Resource
  temporarily unavailable` and 1 `EOF during read of socks reply`.
- mint's haproxy `[ALERT]` is `Current worker exited with code 143
  (Terminated)` at 23:41:40: the stop when Task 1.4 switched back to
  socat, not a fault. Its three warnings are the primary server UP, the
  master exiting and all workers exited. Task 1.4's own window
  (`haproxy-window.log`, 24 lines) has no error line and one warning, the
  primary server UP.
- Every Tor warning on both targets is `Proxy Client: unable to connect OR
  connection ... ("general SOCKS server failure")`: one pool bridge that
  did not answer the obfs4 handshake.
- The mac's logs are short: the plan's own reinstall replaced the
  containers at 06:08 (OD-6), and its socat container log starts at a
  restart at 08:09. The agent's log has 28 `network dnsnet already
  exists` and 9 apiserver `XPC connection error` lines. Both come from the
  runtime during the plan's install runs, not from the proxy or Tor.

BL-002's target "first post-bootstrap primary connect within 2 s"
measured the primary-and-backup `:853` design, which the controller's
route selection replaced. The 24 h soak of 2026-10-06 (run
20261005T060405Z-13de27b1, cold p50 about 0.5 s, both platforms) stands
for it. Its other open target, "no new ERROR/CRITICAL in haproxy or Tor
logs", is the table above: none in either Tor log, and no fault at
haproxy's alert level.

## Known limits

Found by the Stage 2 gate reviews and deferred (user decision 2026-10-06:
qualify what was soaked; any product fix would need a new 24 h soak):

- The restart that adopts a filtered bridge set rebuilds the whole stack on
  macOS (BL-038). (It also took no state lock, so it could overlap a restart
  the minutely tick decided, BL-030; since the 2026-11-18 sweep it runs
  under the lock.)
- Rolling the controller back to a bundle from before this sub-plan fails
  on the new `proxy_gen` state key (BL-036). Bundles from the 2026-11-18
  sweep on skip a state key they do not know, journal it once and go on;
  only a rollback to an older bundle still needs the state file deleted.
- macOS: a slow Tor at login could be read as a bad bridge set and trigger
  a rebuild (BL-037). Fixed in the 2026-11-18 sweep (Sub-plan 3, Stage 1):
  the agent waits past the proxies' own cap and leaves a proxy that reported
  its timeout to the controller.
- An outage might make a healthy bridge look weak and keep it out for 30
  days; plausible, not observed (BL-031).
- macOS: the root helper's `post` could stop early with no route to the
  stack, before the scoped-DNS pf anchor was in place (BL-032). Fixed in the
  2026-11-18 sweep (Sub-plan 3, Stage 1). The agent's fast path did already
  run `post`, so every agent run reasserts the anchor; a pf flush with the
  stack up stays open until the next agent run (BL-033).

Also:

- Latency, two comparisons that disagree and are both stated:
  - Stage 1's interleaved, same-session runs: Linux showed no class
    improved beyond measured variability (DEC-016); macOS cold improved
    after a restart, measured on the exit route (p50 320 -> 103 ms, 10 of
    10 blocks better; run `20261001T074919Z-32225d7a` at nice-dns 50a1c90,
    `tune-transport/*/compare.tsv`). No receipt pins this run.
  - The 24 h soak against the frozen baseline (different days, the onion
    route about 93% of the time): Linux cold p50 2934 -> 492 ms and
    timeouts 7/30 -> 4/864; macOS steady-state cold p50 297 -> 406 ms and
    p95 636 ms -> 1.8 s, slower (BL-035). Warm is unchanged on both. The
    same-session comparison of 2026-11-20 found the macOS candidate faster
    on the exit route ("macOS steady cold latency, interleaved"); the
    onion route's share of the soak's regression was not measured again.
- Onion stalls of about a minute are not failed over: the controller probes
  once a minute. They are the soak's remaining timeouts. A 6 h probe of the
  onion route on mint on 2026-11-20 found no stall over 20 s ("Onion stall
  lengths"), so BL-027 is closed under the 1 in 100 bar.
- The restart that adopts a filtered bridge set was proven live on Linux
  only. On macOS the refreshes left out weak bridges that were not running,
  so no restart was needed.
- Latency is judged per platform, on the representative cell.
- `nice-dns-health --help` still says a refreshed set waits for the proxy's
  next start (BL-029).
- Evidence privacy: the live privacy cases fail a report that holds bridge
  material, a session or a full 40-character fingerprint, and fail a run
  that left no report to scan (BL-057). A 12-character fingerprint prefix
  is allowed in evidence, because the product's own journal writes them
  (its `bridges weak` row names each bridge it leaves out by that prefix,
  `lib/recovery.sh`); the scans do not look for it (BL-034).
