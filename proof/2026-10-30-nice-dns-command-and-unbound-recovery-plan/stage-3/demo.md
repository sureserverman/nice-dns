# Stage 3 demo — 2026-10-30-nice-dns-command-and-unbound-recovery-plan

Environment: run 2026-10-31 about 05:12-05:20 UTC from /home/user/dev/containers/nice-dns on branch command-recovery at 5b9ea96. That commit differs from the receipt's e07fb59 by one proof file (`git diff --stat e07fb59 HEAD`). Hosts `mint` and `mac` were only read. No fault, install, uninstall, reinstall or restart was run on them. Receipt probes and unreachable-target runs used a scratch `NICE_DNS_TEST_ARTIFACTS` and a scratch targets file, both deleted after. `tests/live/targets.env` was not edited.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: a receipt per platform shows recovery from both injected faults with no human action, and all four subcommands doing their job.
Verdict: holds
Evidence:

Command and result:
```
$ bash tests/run.sh receipt command-recovery
receipt: ~/.local/state/nice-dns-tests/receipts/command-recovery/20261031T043538Z-4b138c58/receipt.tsv
receipt=command-recovery cells=2 scenarios=12 errors=0 limits=0 reused=0 ...
exit 0
```
The receipt has one observed cell per platform (`macos` on `mac`, `linux` on `mint`), `product nice-dns e07fb59`, and all sources `clean`. All 12 scenario rows read `pass`.

Faults, read from `cells/<cell>/fault-*.tsv` (times are UTC, converted from the epoch values):

| Platform, fault | Injected | Name during fault | Container replaced | Journal `ready` | Fresh name after | Elapsed |
|---|---|---|---|---|---|---|
| mint, freeze-unbound | 04:48:52 | timeout | 04:51:28 | 04:52:08 | NOERROR | 244 s |
| mint, stop-proxy | 04:57:42 | SERVFAIL | 04:58:05 | 04:59:06 | NOERROR | 122 s |
| mac, freeze-unbound | 04:46:35 | timeout | 04:49:30 | 04:50:08 | NOERROR | 226 s |
| mac, stop-proxy | 05:00:38 | timeout | 05:01:27 | 05:02:08 | NOERROR | 97 s |

Each has `generation_changed yes` and journal rows `requested`, `acknowledged`, `ready`, inside the plan's 10 minutes. Sample row: `journal 1793422276 nd-1793422276-27 unbound requested restart; unbound before: 4d8f46ee...`.

No human action: `grep '^== ' ops.log` for each host (under `~/.local/state/nice-dns-tests/runs/20261031T043538Z-4b138c58/command-recovery/<alias>/`) shows only `controller-report` and `fresh-name` between injection and recovery. The one other operation, `thaw-unbound`, ran after `ready` (mint 04:52:51, mac 04:50:19). It acted after the frozen container had already been replaced.

Subcommands, from `cmd-*.tsv` and the run's logs:
- `restart`: all three container starts changed on both hosts; fresh name NOERROR; log ends `nice-dns restarted; DNS is answering.` exit 0.
- `reinstall`: new generation on both (`043551Z` to `050303Z` mac, `050314Z` mint); `admin_secret`, `anchor`, `tor_data`, `lists` all `kept`. The run's `after-reinstall.tsv` shows the planted markers still there and the admin login still valid.
- `uninstall`: `command absent`, `source absent`, `result pass`. The run's `report-uninstall.tsv` has empty `images`, `quadlets`, `agents` and `units` sections on both. `mac`'s `org.nice-dns.debug-monitor` was running in `marked.tsv` and is gone after. `after-uninstall.tsv`: mint back to `/run/systemd/resolve/stub-resolv.conf` with `systemd-resolved active`; mac's services back to no DNS set (`restored the DNS servers recorded before nice-dns`); both `resolves yes`.
- `install`: `install_over_stack` and `install_after_uninstall` both `pass`; logs show `Generation 20261031T050806Z-nogit0000000 is active (previous: none)` exit 0.

Checked against the hosts now:
```
$ bash tests/live/target.sh command-report mint --targets tests/live/targets.env   # exit 0
image localhost/pi-hole:20261031T050806Z-nogit0000000 ...  (mac the same generation)
start pi-hole ... 05:10:09 / start unbound ... 05:10:08 / start tor-haproxy ... 05:10:07   (mac 05:09:20-21)
command present / source present; units active (mint); 3 org.nice-dns.* agents loaded (mac)
$ bash tests/live/target.sh fresh-name mint|mac --targets tests/live/targets.env
fresh_name nd-cr-1793423606-2105784.example.com NOERROR    (exit 0)
fresh_name nd-cr-1793423607-20805.example.com   NOERROR    (exit 0)
```
- The source on both hosts matches the receipt's commit: SHA-256 of `nice-dns`, `lib/install.sh`, `install-deb.sh`, `install-mac.sh` under `~/.local/share/nice-dns/source`, and of `~/.local/bin/nice-dns`, equal those of `git show e07fb59:<file>`. The receipt's commit claim is therefore confirmed on the hosts.
- `dig @127.0.0.1 cloudflare.com` on mint and `@172.31.240.250` on mac answer. `/etc/resolv.conf` on mint is `127.0.0.1`; mac's Wi-Fi DNS is `172.31.240.250`; three containers run on each.

The verifier does more than check hashes. With a scratch copy of the receipts and the cell's hash fixed up, it refused (exit 1): a removed `ready` row, `generation_changed no`, a SERVFAIL fresh name, a name answered during the fault, `result fail` on uninstall or reinstall. Also refused: changed bytes without a new hash, removed macos rows, removed CR-PROXY rows, a `fail` scenario. With the newest receipt removed, it picks the older failed one and refuses. With no receipts: `nothing verified (this is not a pass)`. Limits of this are finding 2.

## Outcome 2
> A target is unreachable → that check is marked `[~]` with the reason, and the plan cannot close as completed without a `Blocked-accepted` line.
Verdict: holds
Evidence:

Unreachable target, using a scratch targets file with `ghostlin` and `ghostmac` at `nd-demo-ghost*.invalid`:
```
$ bash tests/live/target.sh probe ghostlin --targets <tmp>            # same for command-report, fresh-name
target.sh: host key for nd-demo-ghost.invalid is not in known_hosts; verify it out of band and add it (no trust on first use)
exit 2

$ bash tests/run.sh live command-recovery --targets <tmp> --platforms linux,macos
NOT RUN: live/command-recovery is tier live; pass --live --targets FILE to run it. Nothing was executed; this is not a pass.
exit 3

$ NICE_DNS_TEST_ARTIFACTS=<tmp> bash tests/run.sh live command-recovery --live --targets <tmp> --platforms linux,macos
FAIL  t_01_before ... ASSERT FAIL: snapshot ghostlin ... ASSERT FAIL: snapshot ghostmac
FAIL  t_02_install ... ghostlin: no cell recorded (t_1_before failed); cr_install not run
...
PASS  t_09_privacy
collected=10 passed=1 failed=9
result=fail ...
exit 1

$ NICE_DNS_TEST_ARTIFACTS=<tmp> bash tests/run.sh receipt command-recovery
... no observed linux cell / no observed macos cell
receipt=command-recovery cells=0 scenarios=0 errors=2 ...
exit 1
```
The check cannot go green. Nothing writes `[~]`: the executor marks it by hand, under the planning rule. The cause is in `ops.log` only, not on screen (finding 1).

Closing the plan, using a scratch copy of this plan and the planning plugin's own status bar (`plan-progress.py`, as installed, 1.4.0), with the receipt check set to `[~]`:
```
open gate                        ... 14/14 (100%) · S3/3 ◆ S3 gate
[~] + **Completed:**, no accept  ... 14/14 (100%) ⊘ GATE BLOCKED · S3/3 ◆ S3 gate
[~] + **Completed:** + **Blocked-accepted:**  ... 14/14 (100%) · S3/3 ◆ S3 gate
```
The plugin's parser also reports `plan_blocked` True when the acceptance line is indented, because only column 0 counts. So `**Completed:**` alone does not retire the plan.

Not reached: a host that is pinned in `known_hosts` but down. The pin check refuses a nonexistent host first, and adding a pin means changing `~/.ssh/known_hosts`. The real connection-failure path was not watched. The live plan has no `[~]` today (`grep -c '^- \[~\]'` gives 0), because both targets were reachable.

## Findings

Blocking: none.

Material:
1. An unreachable target is not named on screen. The `--live` run printed 56 lines with 0 mentioning the cause. It says `ASSERT FAIL: snapshot ghostlin`, and the case log it points to says the same. The reason is only in `command-recovery/<alias>/ops.log`. A down target and a broken product both read as `FAIL` exit 1, so whoever marks `[~]` must dig to find the reason the Outcome wants recorded. No false green results.
2. The receipt gate checks the subcommand cells only for a `result pass` line. With the hash fixed up, these scratch copies still verified, exit 0: uninstall `command present`, restart fresh name SERVFAIL, restart starts unchanged, reinstall `admin_secret changed`, install with one of its two results `fail`, fault `elapsed_s 900`. The live run did check these at run time, and the run's evidence is good. But the gate re-reads less than the receipt appears to prove.
3. The receipt alone does not show uninstall's whole job. `cmd-uninstall.tsv` has command, source and left images. Quadlets, agents, units and host DNS are only in the run directory, while this Outcome's reader is "the owner, reading the receipts". `cmd-install.tsv` likewise holds only generation ids and `pass`.
4. `limits=0` is printed for a receipt carrying two `# limit:` lines: Mac commands ran in the GUI context (BL-052, plain ssh unproven), and reinstall ran with `--local` (a clone is unproven). An owner reading only the summary line is told there are none.

Minor:
5. Every scenario row carries `generation=20261031T050806Z-nogit0000000`, the final install. The faults, restart and uninstall ran on earlier generations (`043551Z`, then `0503xxZ` for uninstall). All are the same source, so nothing false results about the code.
6. On hosts, `source_commit` is `unknown` and generation names are `nogit`, so a host cannot name its commit. A file hash comparison is needed, as done above.
7. `PASS t_09_privacy` prints on a run where nothing reached a host, so it passes having measured nothing. The overall result is still `fail`.
8. `left_image` lists 58 images on mint with `result pass`, including `localhost/nice-dns_pi-hole:latest` (created 2025-07), `docker.io/sureserver/hardened-unbound:latest` and `docker.io/pihole/pihole:latest`. These appear to predate this install: this install's digests were untagged in the log, and the last two share digests with `nd-arm-*:baseline` tags. The receipt does not say so, and `nice-dns_pi-hole` reads like a product leftover. mac left only 7 non-product images.
9. The final fresh-name in each `freeze-unbound` scenario runs just after `thaw-unbound` (2 s on mint, 1 s on mac), so that row alone cannot exclude the thaw. The earlier `ready` row and the replaced container do.

Note on the first gate criterion (not run by me, not a finding of this demo):
- The literal command cannot pass. `tests/manifests/plans.tsv` lists live rows under both names: `controller-shadow`, `controller-active`, `controller-wake`, `controller-receipt`, `install-lifecycle`, `install-hardened`, `installers-receipt`.
- Without `--live` it refuses, exit 3 `NOT RUN`, which correctly is not a pass.
- This bears on Outcome 2: if those rows do not run, the honest record is `[~]` with the reason plus a `Blocked-accepted` line, or an owner-worded change to the command. It must not be `[x]`.
- A local-only run on mint from a copy covers fewer rows than the gate names, so it cannot tick the box by itself.

The third gate criterion, seen in passing: DEC-007 reads `superseded by DEC-021`, and DEC-021 reads `Supersedes: DEC-007`. BL-001 is off the backlog, and the `local-service` entry is on it.
