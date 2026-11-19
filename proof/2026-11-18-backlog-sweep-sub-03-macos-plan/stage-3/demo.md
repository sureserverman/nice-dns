# Plan demo — 2026-11-18-backlog-sweep-sub-03-macos-plan

Environment: the mac (`ssh mac`; macOS 27.2.1 build 26B131, arm64, container CLI 1.7.1, FileVault off, no automatic login), read 2026-11-19 18:06–18:12 UTC. The install there is generation `20261119T170103Z-757dd8cd8be9`, branch `sweep-macos`, source commit 757dd8c, variant socat, Pi-hole standard. The repo HEAD is 74f8082, read with `git show HEAD:`. The mac was rebooted at 17:59 UTC for the Task 3.1 spike, and the owner logged in at the console at 18:00. Nothing was changed on the mac or here: only read commands, plus `nice-dns status`.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

# Stage 1

## Outcome 1
> Works: the agent's run while the Mac is offline finishes its DNS pin and cache flush; the block is in place when the network returns
Verdict: not shown here
Evidence:
- Showing it needs the mac taken offline while the agent runs, then the network brought back and the anchor read. That is a network change, which this evaluation may not make.
- Recorded instead: nothing live. The Stage 1 handoff in the plan says: "Outcome 1's offline case rests on the mac's connected route on bridge100, inferred and not run offline".
- Fixture guard (read, not run): `git grep -n BL-032 HEAD -- tests/integration` finds tests/integration/dns-transaction.sh:144-156. Those cases check that `post exits 0 when '$f' fails`, that "the pin is made", that "the cache is flushed", that "mDNSResponder is reset", and that a pf token write failure still flushes and "says so".
- Live state today, after a reboot (not an offline run): the anchor is loaded. See Outcome 8.

## Outcome 2
> Works: every run of the agent loads the scoped-DNS block for the bridge that leads to Pi-hole now, also when the stack was healthy and nothing was rebuilt
Verdict: not shown here
Evidence:
- The part this Outcome adds is a healthy-stack (fast-path) run that reloads the block. Showing it needs the anchor flushed, or the bridge renamed, and then an agent run. Both are forbidden here.
- What the live mac does show is the rebuild path after the reboot:
  - `ssh mac 'sudo -n pfctl -a com.apple/260.nice-dns-scoped -s rules'` returns 4 `pass out quick on bridge100 ... to 172.31.240.248/29 port = 53|853` rules and 4 `block drop out quick ... to 172.31.240.248/29 port = 53|853` rules (rc 0).
  - `ifconfig` puts `inet 172.31.240.249 netmask 0xfffffff8` on bridge100, which is the bridge that leads to Pi-hole at .250.
  - The agent log (~/Library/Logs/nice-dns.log) shows the run after login: `18:01:12 addresses not as configured; rebuilding stack` … `18:01:15 stack rebuilt on expected addresses` … `18:01:20 done`.
- The agent's healthy fast-path runs today are `15:45:09` and `17:02:24 stack already healthy (variant=socat) — reusing existing state`. No pf flush came before them, so they do not tell whether the block was reloaded.
- Fixture guard (read, not run): tests/integration/dns-transaction.sh:161-192 (BL-033).
  - "a healthy stack's run calls the helper's post once".
  - "the full path's last helper call is post".
  - The bridge100 → bridge101 case.

## Outcome 3
> Works: a Tor that needs up to 5 minutes at login is waited for; the bridge set is kept and the stack is not rebuilt
Verdict: not shown here
Evidence:
- Showing it needs a Tor that is slow at login, or a restart of the stack. Neither may be done here.
- Today's live login run is the fast case only: `18:01:06 reusing existing bridge set (bootstrapped cleanly last run)` … `18:01:20 tor bootstrapped`.
- `nice-dns status --tsv` gives `bridges count 7` and `bridges last_refresh 1795061861`. The set was kept, but Tor took 5 s, so nothing was tested here.
- Fixture guard (read, not run): tests/integration/recovery-actions.sh:891-940 (BL-037).
  - "a Tor that bootstraps at try 65 arms no sentinel".
  - "and is waited for".
  - "and the stack is not rebuilt".

## Outcome 4
> Works: a link-local DNS server such as `fe80::1%en0` set before nice-dns is recorded and comes back at uninstall
Verdict: not shown here
Evidence:
- Showing it needs a DNS setting changed to `fe80::1%en0` before an install, then an uninstall. Both are forbidden here. The mac's services today all use 172.31.240.250, per `obs dns-owner`.
- Nothing is recorded live in docs/qualification.md.
- Fixture guard (read, not run): tests/integration/dns-transaction.sh:221-251 (BL-043 item 3).
  - "the scoped server is recorded as it is".
  - "and it comes back at uninstall".
  - A value holding a space or `;` "is still refused".

## Outcome 5
> The proxy itself reports that Tor did not bootstrap in time → the agent logs that line and leaves the bridges alone; the controller's own recovery takes over
Verdict: not shown here
Evidence:
- Showing it needs a proxy whose Tor times out (300 s), at an agent run. That cannot be done without restarting the stack.
- `grep -c 'Tor did not bootstrap in' ~/Library/Logs/nice-dns.log` returns no such line, so it has not happened live.
- Fixture guard (read, not run): tests/integration/recovery-actions.sh:939-940 (BL-037).
  - For each proxy's timeout line: "the proxy's own warning arms no sentinel".
  - "the agent logs the proxy's line".

# Stage 2

## Outcome 6
> Works: `nice-dns install` or `reinstall` over ssh starts the container runtime where the login agent sees it; DNS answers when the install ends
Verdict: not shown here
Evidence:
- Showing it needs a reinstall, which is forbidden. What follows is recorded, not re-run.
- docs/qualification.md "macOS install over ssh (2026-11-19)" records the run `ssh mac '~/.local/bin/nice-dns reinstall --branch sweep-macos'`:
  - The 17:01 UTC run at 757dd8c: "installed in 77 s; the apiserver restarted at 17:02:05, at the fresh-datapath step".
  - After it, "`dig @172.31.240.250 cloudflare.com` answered".
  - "the start-container agent found the runtime ready and the stack healthy (17:02:17)".
  - The earlier 15:43 run at 8914b88 is recorded as a defect: its fresh-datapath restart did nothing. 757dd8c fixed it.
- The mac backs this up (read today). `~/Library/Logs/nice-dns.log` holds `17:02:17 container system ready` and `17:02:24 stack already healthy (variant=socat)`. `ls -l /usr/local/sbin/start-container*.sh` shows both files dated `Nov 19 17:02`. `nice-dns status --tsv` gives `install generation 20261119T170103Z-757dd8cd8be9`, `install branch sweep-macos`.
- The runtime the login agent uses is the user's GUI-domain one.
  - `sudo -n launchctl asuser $(id -u) sudo -n -u $USER /opt/homebrew/bin/container system status` returns `status running`, `server.version 1.7.1`, `containers.running 3`.
  - A direct `container system status` over ssh still prints "apiserver is not running and not registered with launchd".
- Caveat: 825ee71 came after this live run. It changed lib/install.sh, install-mac.sh, install-mac-hardened.sh and mac/start-container.sh (the up-front sudo check of an ssh install). The ssh install at HEAD has not been run live (see Findings).

## Outcome 7
> Works: after a successful install no builder container is left; the README says how to see disk use and what `container image prune -a` also removes
Verdict: shown
Evidence:
- `ssh mac '/opt/homebrew/bin/container ls -a'` lists only `unbound`, `tor-socat` and `pi-hole`, all running. `... | grep -c buildkit` returns `0`.
- The plan's dry run of 2026-11-18 saw "a stopped `buildkit`" on this mac. It is gone.
- `container system df` (through `launchctl asuser`) returns `Containers 3 3 1.06 GB 0 B (0%)`. qualification.md records `4 (3 active), 2.18 GB, 1.05 GB reclaimable` before the install.
- `git show HEAD:README.md`, section "Disk use on macOS", lines 196-205:
  - "`container system df` shows what images, containers and volumes take. An install deletes the image builder when it is done."
  - "`container image prune -a` removes every image no container uses: the older generation kept for a rollback, and the runtime's init image, which every container start needs."
  - It also says how to pull the vminit image back.

## Outcome 8
> Works: the mac, reinstalled over plain ssh from the branch, answers DNS, has the scoped-DNS block loaded and lists no `buildkit` container
Verdict: shown
Evidence:
- The mac's install is the one recorded as reinstalled over plain ssh. `nice-dns status --tsv` gives `install installed yes`, `install branch sweep-macos`, `install generation 20261119T170103Z-757dd8cd8be9` and `install source_commit 757dd8c…`. That matches qualification.md's 17:01 UTC ssh run.
- `ssh mac 'dig @172.31.240.250 +time=5 +tries=2 +short cloudflare.com'` returns `104.16.132.229` and `104.16.133.229`.
- `dig +short example.com` through the host resolver also answers. `obs dns-owner healthy … all 3 active services use 172.31.240.250`.
- `sudo -n pfctl -a com.apple/260.nice-dns-scoped -s rules` holds `pass out quick on bridge100 …` and `block drop out quick inet proto udp|tcp … to 172.31.240.248/29 port = 53|853`.
- `container ls -a | grep -c buildkit` returns `0`.
- Every `obs` row in `status --tsv` is `healthy`. The controller verdict is `OK`.
- Note: this state comes after today's 17:59 reboot. The agent rebuilt the stack at 18:01, so the block now loaded came from the agent's run, not from the install. qualification.md records the same three checks right after the 17:01 install. That record also matches the Task 2.3 Test command.

## Outcome 9
> The Mac has no login session at all → the install stops before any change and says a user must be logged in at the Mac
Verdict: not shown here
Evidence:
- Showing it needs an install run while no one is logged in. That means a reinstall and a logout, both forbidden. The owner is logged in now (`who` gives `user console Nov 19 18:00`).
- qualification.md says: "Not shown: … a Mac with no one logged in (fixture case only)".
- Fixture guard (read, not run): tests/integration/install-prepare.sh:1421-1426 (BL-052).
  - "says a user must be logged in at the Mac" (`must be logged in at the Mac`).
  - "no generation is prepared".

## Outcome 10
> `container builder delete` fails → the install still succeeds and says the builder was left
Verdict: not shown here
Evidence:
- Showing it needs an install where the builder delete fails, which is a reinstall. Nothing is recorded live.
- Fixture guard (read, not run): tests/integration/install-prepare.sh:1458-1459 (BL-024).
  - "a builder that cannot be deleted does not fail the install".
  - "the install says the builder was left" (`builder could not be deleted and was left`).

# Stage 3

## Outcome 11
> Works: the README and the workflow document say that after a reboot the Mac has no DNS until its user logs in, and recommend automatic login
Verdict: shown
Evidence:
- `git show HEAD:README.md | sed -n 81-86`, "## Install": "On a Mac the stack runs in your login session, so after a reboot the Mac has no DNS until you log in (a test on macOS 27.2: the runtime does not start before login). Turn on automatic login if it must have DNS after an unattended reboot."
- `git show HEAD:docs/workflows/dns-lifecycle.md | sed -n 1266-1276`, WF-DNS-003 macOS persistence: "after a reboot the Mac has no DNS until its user logs in: host DNS stays pinned to the stack. Apple's runtime does not start before a login either … Automatic login is the recommendation for a Mac that must have DNS after an unattended reboot (README, DEC-032; BL-058)."
- Neither says that automatic login needs FileVault off. qualification.md does (Minor).

## Outcome 12
> Works: `docs/qualification.md` says, with the commands and their output, whether the runtime and the stack came up before login on macOS 27.2.1
Verdict: shown (from the record, corroborated read-only on the mac; the reboot itself was not re-run)
Evidence:
- What I relied on, first: `git show HEAD:docs/qualification.md`, section "## macOS pre-login start" (2026-11-19, macOS 27.2.1, CLI 1.7.1, FileVault off, no automatic login). It names:
  - the scratch daemon and what it ran;
  - the reboot at 17:59:18 UTC "(the owner said go, OD-3)";
  - the daemon's output: `managername=System`, `system start rc=1` with "XPC connection error: Connection invalid", `system status rc=1` with "apiserver is not running and not registered with launchd", and `start-container rc=1 18:00:22` with "container system never came up";
  - the pre-login reads over ssh: `container system status`, `container ls -a` (failed), and `dig @172.31.240.250 cloudflare.com` (timed out);
  - the recovery after the owner's login;
  - the line `verdict: does not start`.
- So it says that neither the runtime nor the stack came up before login.
- Corroborated on the mac today (read only):
  - `sysctl -n kern.boottime` returns `Thu Nov 19 17:59:36 2026`. `last` gives `reboot time Thu Nov 19 17:59` and `user console Thu Nov 19 18:00 still logged in`.
  - `cat /tmp/nice-dns-spike.log` (477 bytes, 18:00) matches the quoted output line for line: `spike start 2026-11-19T17:59:44Z uid=501 managername=System` … `system start rc=1 17:59:44` … `system status rc=1 17:59:44` … `start-container rc=1 18:00:22`.
  - ~/Library/Logs/nice-dns.log holds `17:59:45 container system not ready, retry 1/10` through `retry 9/10`, then `18:00:22 container system never came up`. Then after login: `18:01:05 starting nice-dns runtime (variant=socat)`, `18:01:12 container system ready`, `18:01:15 stack rebuilt on expected addresses`, `18:01:20 done`.
  - `test -e /Library/LaunchDaemons/org.nice-dns.spike-prelogin.plist` is false. `launchctl print system/org.nice-dns.spike-prelogin` is not loaded. The scratch daemon is gone.
  - `fdesetup status` returns "FileVault is Off.". `defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser` finds no key.
- The person-at-the-mac part (the go before the reboot, the login after it) rests on the record and on the console login at 18:00. I did not see it happen.

## Outcome 13
> Works: the decisions register says that ad-hoc signing is accepted and why, and the backlog marks the fixed-address limit as parked on Apple
Verdict: shown
Evidence:
- /mnt/vault/Portfolio/containers/nice-dns/decisions.md, line 22, "## DEC-031 — macOS release assets stay ad-hoc signed; integrity rests on the pinned sha256":
  - `Decided: 2026-11-18 (owner … "Accept ad-hoc (Recommended)")` and `Status: accepted`.
  - The reason: a Developer ID signature and notarisation need an Apple developer account and CI secrets the project does not have. "The installer accepts an asset only when its sha256 matches the one release/assets.lock pins". It names BL-062 and BL-065, and it gives the rejected option and the costs accepted.
- The same file, line 8: DEC-032, the before-login decision (BL-058).
- /mnt/vault/Portfolio/containers/nice-dns/backlog.md:109-118, "## BL-038 — macOS: the bridge-adoption restart rebuilds the whole stack". It ends with `- **Parked:** 2026-11-18 — waits on apple/container issue 282 (no fixed address for a container)`.

## Final-gate checks read here (not the gate itself)

- Guards and records:
  - `git grep -q BL-0NN HEAD -- tests/integration tests/unit` finds each of BL-024, 032, 033, 037, 043 and 052 (cases cited above).
  - `grep BL-058`, `BL-062` and `BL-065` each match in decisions.md (DEC-031, DEC-032).
- The mac:
  - `nice-dns status --tsv` holds `install	installed	yes`.
  - The anchor holds `block drop` rules after the owner's 18:00 login.
- Not run: shellcheck, the plan-scope test pass, and the decision-conformance reading over the diff. They are outside this evaluation, which reads no diff and runs no tests/run.sh.

## Findings

**Blocking**
- None. No Outcome failed. Every Outcome shown here was met. The ones not shown on the real system have fixture guards, and Outcome 6 also has a recorded live run.

**Material**
- M1: the mac's live evidence is for 757dd8c, not the tree being merged.
  - 825ee71 came after the live ssh install. It changed lib/install.sh, install-mac.sh, install-mac-hardened.sh and mac/start-container.sh, to add the up-front sudo check of an ssh install (`git log --name-only 757dd8c..HEAD`).
  - So the ssh install at HEAD, and the agent at HEAD, have never run on the mac. The Stage 2 handoff says so too ("round 1's sudo check (825ee71) was not run live there").
  - One `ssh mac '~/.local/bin/nice-dns reinstall --branch sweep-macos'` from HEAD, then Outcome 8's three checks, would close this.
- M2: 8 of 13 Outcomes (1–6, 9, 10) are not shown on the real system by this evaluation.
  - Stage 1's evidence claim is synthetic by design. Outcome 1's offline case is "inferred and not run offline" (Stage 1 handoff). No pf flush or bridge change was ever exercised live.
  - The plan records the owner's answer "an Outcome the session cannot show holds the merge". The caller should confirm that this applies only to the `needs:`-tagged Outcome 12. That one is now shown from the record.

**Minor**
- m1: the README says "a test on macOS 27.2". The spike ran on 27.2.1, per qualification.md and `sw_vers`.
- m2: the README and WF-DNS-003 recommend automatic login. Neither says it needs FileVault off, which qualification.md does say. Neither says it lets anyone at the Mac into the account.
- m3: the spike daemon ran /usr/local/sbin/start-container.sh with no argument, so the agent logged `17:59:45 starting nice-dns runtime (variant=haproxy)` on a socat install (`VARIANT="${1:-haproxy}"`). The verdict is not affected: the runtime never came up, so the variant never mattered.
- m4: over plain ssh, `container system status` still prints "apiserver is not running and not registered with launchd" while the GUI-domain runtime runs. qualification.md documents this, but an operator over ssh is misled unless they know the `launchctl asuser` route.

Overall: PASS
