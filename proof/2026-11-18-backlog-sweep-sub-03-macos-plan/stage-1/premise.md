# Stage 1 premises — 2026-11-18-backlog-sweep-sub-03-macos-plan

Goal: A person on a Mac keeps the block on DNS that tries to leave beside the stack, also offline, after a pf flush and after the container bridge changes, and a slow Tor at login does not throw their bridges away.
Risk: MEDIUM — root-run pf code on the path that pins host DNS. Fixtures with fake `route`, `pfctl` and `networksetup` cover each branch; Task 2.3 checks the loaded anchor on the mac.

Outcomes:
- Works: the agent's run while the Mac is offline finishes its DNS pin and cache flush; the block is in place when the network returns
- Works: every run of the agent loads the scoped-DNS block for the bridge that leads to Pi-hole now, also when the stack was healthy and nothing was rebuilt
- Works: a Tor that needs up to 5 minutes at login is waited for; the bridge set is kept and the stack is not rebuilt
- Works: a link-local DNS server such as `fe80::1%en0` set before nice-dns is recorded and comes back at uninstall
- The proxy itself reports that Tor did not bootstrap in time → the agent logs that line and leaves the bridges alone; the controller's own recovery takes over

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: macOS's /bin/bash (the root helper's shell) ends a `set -euo pipefail` script at an assignment whose command substitution pipeline fails, so a failing `route` ends `post` before its cache flush (BL-032).
Checked: on the mac, 2026-11-19: `/bin/bash -c 'set -euo pipefail; x="$(false | cat)"; echo survived'; echo "assign rc=$?"`; `/bin/bash --version`.
Result: `assign rc=1`, "survived" never printed; GNU bash 3.2.57(1)-release (arm64-apple-darwin26).
Verdict: holds

## Premise 2
Assumption: `pfctl -s info | grep -q 'Status: Enabled'` can read an enabled pf as disabled (grep exits on the first line, pfctl dies of SIGPIPE, pipefail fails the pipeline).
Checked: on the mac: `sudo -n pfctl -s info | head -1`; `sudo -n pfctl -s info | wc -c`.
Result: `Status: Enabled for 2 days 14:24:25 ...`; 1388 bytes, far below a pipe buffer, so pfctl finishes its write before grep exits.
Verdict: holds as a mechanism, not reached at today's output size; the fix is hardening, tested with a fake whose output exceeds a pipe buffer.

## Premise 3
Assumption: the agent's `route -n get 172.31.240.250` names the container bridge while the stack is up.
Checked: on the mac: `route -n get 172.31.240.250 | grep interface`.
Result: `interface: bridge100`. Whether `route` exits non-zero when the Mac is offline was not checked: it needs the mac's network taken down, and ssh is the only path to it.
Verdict: holds (online); offline exit status not checkable here — the fixture fakes it, as the plan's Evidence claim says.
Added at the Stage 1 gate (Tier-2 I1, 2026-11-19): `ssh mac 'netstat -rn -f inet | grep -E "^Destination|172\.31\.240|^default"'` printed `172.31.240.248/29  link#25  UC  bridge100` — the stack's subnet is a connected route on the container bridge, not one through the default gateway (`default 192.168.0.1 UGScg en1`). So an offline Mac with the stack up still routes to Pi-hole and `post` loads the block; `route` fails only with no bridge, where nothing is loaded by design. Outcome 1 holds on that reading; BL-032's "no route (offline)" names the no-bridge case.

## Premise 4
Assumption: the agent's fast path calls the root helper (the plan said it never does; OD-5).
Checked: `git blame -L 688,692 mac/start-container.sh`; on the mac: `grep -n "stack already healthy|post-start helper" ~/Library/Logs/nice-dns.log | tail`; `grep -c "run_root_helper post" /usr/local/sbin/start-container.sh`.
Result: line 689 `run_root_helper post` since d21b0a8 (2026-04-23); the installed agent holds 2 `post` calls; fast-path runs of 2026-11-11 (10:48, 10:54, 11:46, 11:49, 11:52) log no helper failure and no "no container bridge" line.
Verdict: false as the plan wrote it — the owner re-scoped Task 1.2 to a guard (OD-5, 2026-11-19: "Guard only (Recommended)"); the Outcome it serves holds today.

## Premise 5
Assumption: the proxies print a timeout line at their own 300 s cap that the agent can read (BL-037; Task 1.3).
Checked: on the mac: `container exec tor-socat sh -c 'grep -n -B3 -A3 "bootstrap in time" /bin/start.sh'`; here: `grep -n 'did not bootstrap' ../tor-socat/start.sh ../tor-haproxy/start.sh` (tor-haproxy at 0de8144, the v2.17 commit release/images.lock pins); the caps `grep -n -- '-lt 300' ...`.
Result: tor-socat prints `WARNING: Tor did not bootstrap in time, starting socat anyway.` (start.sh:354); tor-haproxy prints `WARNING: Tor did not bootstrap in 5 minutes.` (start.sh:367); both caps are 300 s (tor-socat start.sh:305, :318).
Verdict: holds with a correction — the two images print different lines, so Task 1.3 matches `Tor did not bootstrap in`, not the socat text only.

## Premise 6 (early premise)
Assumption: `bash tests/run.sh integration dns-transaction` runs mac/start-container-root.sh against a fake `networksetup`, `route` and `pfctl` under ND_DNS_TEST_ROOT.
Checked: the baseline run 20261119T105307Z-2313783e (43/43); case names `t_helper_blocks_scoped_dns_off_the_container_bridge`, `t_helper_flushes_the_macos_cache_after_each_change`; tests/fixtures/install-fakes.sh `pfctl)` and `route)` stubs.
Result: the helper runs with `env -i ... ND_DNS_TEST_ROOT="$FAKE_ROOT" bash "$h" "$2"` (dt_helper), fakes log every call to $FAKE_LOG, and `$FAKE/fail` makes a matching call exit 1.
Verdict: holds

## Premise 7
Assumption: `networksetup -getdnsservers` reports a scoped link-local server as `fe80::1%en0` (Task 1.4).
Checked: not run — it needs a service's DNS set to a link-local address on the mac, a change to the host's own DNS during the run.
Result: none.
Verdict: not checkable here — changing the mac's DNS would cut the session's own checks; the fixture uses the form the backlog entry (BL-043 item 3) records.
