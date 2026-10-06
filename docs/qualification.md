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
2. Re-pin `release/images.lock` to the new digests with
   `scripts/update-images-lock.sh --write`, and check the new entries name
   those commits.
3. Then merge nice-dns. An install from `main` before step 2 would run the
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
  replaces keeps its images until the install after next.
- **Back to the previous proxies:** re-pin `release/images.lock` to the
  `v2.14` / `v2.10` digests and reinstall.
- **The controller alone:** `health/nice-dns-health install` from the
  previous checkout installs that version's bundle in place.

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

## Known limits

Found by the Stage 2 gate reviews and deferred (user decision 2026-10-06:
qualify what was soaked; any product fix would need a new 24 h soak):

- The restart that adopts a filtered bridge set takes no state lock, so it
  can overlap a restart the minutely tick decides (BL-030), and on macOS it
  rebuilds the whole stack (BL-038).
- Rolling the controller back to a bundle from before this sub-plan fails
  on the new `proxy_gen` state key (BL-036).
- macOS: a slow Tor at login can be read as a bad bridge set and trigger a
  rebuild (BL-037).
- An outage might make a healthy bridge look weak and keep it out for 30
  days; plausible, not observed (BL-031).
- macOS: the root helper's `post` can stop early when the machine is
  offline, before the scoped-DNS pf anchor is in place, and the agent's fast
  path does not reassert the anchor, so a pf flush with the stack up
  reopens the scoped leak until the next rebuild (BL-032, BL-033).

Also:

- Latency, two comparisons that disagree and are both stated:
  - Stage 1's interleaved, same-session runs: Linux showed no class
    improved beyond measured variability (DEC-016); macOS cold improved
    after a restart, measured on the exit route.
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
- The Linux installer prints "Bridges selected" also when the selection was
  skipped (BL-028), and `nice-dns-health --help` still says a refreshed set
  waits for the proxy's next start (BL-029).
