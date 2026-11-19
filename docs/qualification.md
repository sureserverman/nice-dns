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
    p95 636 ms -> 1.8 s, slower (BL-035). Warm is unchanged on both.
- Onion stalls of about a minute are not failed over: the controller probes
  once a minute (backlog BL-027). They are the soak's remaining timeouts.
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
