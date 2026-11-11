# Stage 3 demo — 2026-11-10-app-switches-autocheck-plan

Environment: (see below)

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: an install or `nice-dns update` on Linux and macOS lands the v1.4.0 apps with the selectors, and the controller's third schedule
Verdict: holds
Evidence: Evaluator 1 (2026-11-11 ~09:30Z): both installed apps are byte for byte the v1.4.0 release binaries (mint nice-dns-gui sha256 134fa40e…, the mac's NiceDNSGUI 19f82cd9…, --version 1.4.0); the mac screenshot shows the Proxy [socat] and Pi-hole [standard] selectors (mint's are below the default window's fold; labels in the binary, --check passes); the third schedule on both (mint timer 00/12:00:00, 30 min spread, Persistent; mac agent org.nice-dns.health-update 04:47/16:47). `nice-dns update` itself not run (it would install main over the branch); five reinstalls stood in for the install route.


## Outcome 2
> Works: on mint and on the mac, the proxy switch run from the app's own action changes the running proxy container and `status`; the hardened switch builds from the tree with no checkout on the host; DNS answers after each; the scheduled check, started by hand, updates `checked_at`
Verdict: holds (mint's app route under the run's polkit test rule)
Evidence: Evaluator 1: on the mac the app's --run-action proxy-haproxy exited 0 ("Switched: the proxy is now tor-haproxy, and DNS is answering."), container ls and status agreed, dig answered, and back to socat the same way. On mint the app's switch asked polkit and, with nobody at the machine, was refused ("authorisation cancelled (exit 3)"; nothing changed); the command-line switch held both ways. The live receipts (20261111T085255Z-71eb1196 at 652f00e; 20261111T105714Z-dd1bef02 at f1cbc1b) carry the app route on mint under the run's temporary polkit rule (a receipt limit), the hardened build from the tree with no checkout on either host, and checked_at moving; evaluator 1 saw checked_at move on both by hand (mint 1794387887 -> 1794389210, mac 1794387888 -> 1794389227). Residual: no person-authorised app switch on mint seen (Material M1).


## Outcome 3
> A release asset cannot be fetched or its sha256 differs → the install goes on without the GUI, as today; the stack and the command are installed
Verdict: holds (fetch failure); sha256-mismatch half not caused
Evidence: Evaluator 1 blocked GitHub in mint's /etc/hosts and ran nice-dns reinstall --local: "! The nice-dns-gui download failed (curl exit 7): GUI not installed; reinstall with network to add it.", rc 0, a new generation, DNS answering, the earlier GUI kept; /etc/hosts restored. The same thing happened for real in live run 20261111T103616Z-8a709d2a (curl exit 7 at install). The sha256-mismatch half was not caused (Material M2; release-inputs covers the refusal by fixture).


## Outcome 4
> A live cell fails → its receipt row names the cell and the step; only that cell is rerun (DEC-009); the target is put back on its recorded choices
Verdict: holds
Evidence: Re-demo 2 (after round 2): run 20261111T103616Z-8a709d2a's failed mint cell is `cell linux … failed` with `scenario SA-INSTALL linux/socat/standard fail`, and the console printed "Rerun only those: --platforms linux with NICE_DNS_CELL_REUSE_RUNS=<that run>"; following it, run 20261111T105714Z-dd1bef02 passed 8/8 with the mac cell carried (`reuse macos/socat/standard 20261111T103616Z-8a709d2a f1cbc1b…`, receipt cells=2 errors=0 reused=1); the failed cell's restore put mint back (socat/standard, resolves yes, polkit rule absent). A refused carry now says why ("the product files changed since 652f00ea7016 (…)"). The first demo and re-demo 1 had found the step unnamed and the refusal silent (fixed in 53f3e87, f1cbc1b, aa6464e).


## Outcome 5
> A live target is offline → the cell is not run and the gate is not ticked; the owner is asked to wake it
Verdict: holds
Evidence: Re-demo 1 (after round 1): with mint and the mac sent to 192.0.2.1 by a PATH ssh wrapper, the live command said "OFFLINE: mac does not answer (…) The cell is not run. Ask the owner to wake mac (mint: its Wi-Fi after a suspend), then rerun only this platform: --platforms macos"; nothing was installed; the receipt check failed (cells=0), so no gate tick. Re-demo 2 saw the reason filled in ("ssh: … Connection timed out").


## Findings carried (graded by the evaluators)

Blocking: none left (first demo B1 step unnamed and B2 no wake request, fixed in round 1; re-demo 1 B1 silent reuse refusal, fixed in round 2).
Material residuals: no person-authorised app switch on mint seen; the sha256-mismatch half of Outcome 3 not caused; ssh installs on mint print textual-authentication-agent lines before falling back to sudo (pre-existing). Re-demo 2's M1 (an offline target hid a refused carry) and M2 (a snapshot failure after the probe gave no rerun line) fixed in aa6464e.
Minor: Linux GUI version 0.2.0 vs the app's 1.4.0 (by design); mint's selectors below the window's fold; status lags a switch by one controller pass; a refused polkit prompt also prints the ownership-check exit 126; "GUI not installed" while an earlier GUI stays; the receipt has no offline row; repeated verifier lines on a failed receipt; limit rows on a run where nothing ran; an untracked proof file marks the source dirty.

---

# Appendix: evaluator report stage3-demo.md

> # Stage 3 demo — app switches and 12-hour update check (evaluator, 2026-11-11)

> Overall: FAIL. Two Outcomes (4, 5) do not hold as written. Outcomes 1–3 hold (3 only for the fetch-failure half).
> No background work left running. Both machines end on proxy socat + Pi-hole standard, DNS answering, v1.4.0 apps in place.

> ## Outcome 1
> > Works: an install or `nice-dns update` on Linux and macOS lands the v1.4.0 apps with the selectors, and the controller's third schedule

> Verdict: holds

> Evidence:
> - `gh release view v1.4.0`: published 2026-11-11 08:00Z, GUI + helper assets for linux amd64/arm64 and macos arm64, each with a .sha256.
> - mint: `~/.local/bin/nice-dns-gui` sha256 `134fa40e…7b912` = the binary inside the downloaded `nice-dns-gui-linux-amd64.tar.gz` (tarball sha matches its .sha256). Re-landed by my switch reinstall (mtime 09:25:11, same hash).
> - mac: `NiceDNSGUI` sha256 `19f82cd9…77c65` = the binary inside `nice-dns-gui-macos-arm64.zip` (zip sha matches its .sha256). `--version` → `nice-dns-gui 1.4.0`, ad-hoc signed, no quarantine xattr.
> - Selectors: mac `--screenshot` shows an "Installed" box with Proxy [socat ▾] and Pi-hole [standard ▾] pop-ups. mint `--screenshot` (default window size) shows Containers, Bridges, Health controller. The selectors are below the fold and not in the shot. The binary carries the Installed/proxy/Pi-hole selector strings and the "Switch" confirmation text. `--check` → `installed: generation …; controller OK, fresh`.
> - Third schedule: every install printed `Schedule: … nice-dns-health-update.timer … (every minute: …; daily: bridges-refresh; twice a day: update-check)`. mint: timer `OnCalendar=*-*-* 00/12:00:00`, `RandomizedDelaySec=30m`, `Persistent=true`, listed by `list-timers`. mac: `org.nice-dns.health-update` loaded in gui/501 with calendar 04:47 and 16:47. `status` → `Update … auto loaded` on both.
> - I did not run `nice-dns update`: it would install main 671d950 over the branch build. Four reinstalls stood in for it as the "install" route: two switches on mint, two through the mac app, and one mint `reinstall --local`.

> ## Outcome 2
> > Works: on mint and on the mac, the proxy switch run from the app's own action changes the running proxy container and `status`; the hardened switch builds from the tree with no checkout on the host; DNS answers after each; the scheduled check, started by hand, updates `checked_at`

> Verdict: holds on the mac. On mint, the app-action route cannot be reached without a person at polkit. The same switch from the command line holds there.

> Evidence:
> - mac, from the app: `NiceDNSGUI --run-action proxy-haproxy --exit` (GUI context) took 09:22:15→09:26:33. It ended `Switched: the proxy is now tor-haproxy, and DNS is answering.` / `finished (exit 0)`. `container ls` → tor-haproxy running at .252. `status` → `variant haproxy`, Containers `tor-haproxy healthy`. `dig @172.31.240.250 cloudflare.com` answered. Back with `--run-action proxy-socat --exit` (09:27:25→09:30:00): `Switched: the proxy is now tor-socat…`, exit 0, `container ls` → tor-socat, status socat/standard, dig answers.
> - mint, from the app: `nice-dns-gui --run-action proxy-haproxy --exit` (systemd-run, cairo) → `Error executing command as another user: Request dismissed` / `nice-dns: authorisation cancelled` / `the switch did not happen (installer exit 1)… so tor-socat still runs.` / `authorisation cancelled (exit 3)`. That is expected: nobody is at mint to authorise polkit. Afterwards status still showed socat, the same generation, and dig answered. **A switch from the app on mint needs a person to authorise polkit at the machine (or the stage's temporary polkit rule).** The receipt's limit row `polkit-test-rule` says the stage's own run used that rule.
> - mint, from the command line: `nice-dns switch proxy haproxy` (09:22:06→09:25:11) → `Switched: the proxy is now tor-haproxy, and DNS is answering.` rc 0. `podman ps` → tor-haproxy. `status` Install → `variant haproxy` at once. Containers showed `tor-socat` until the next controller pass a minute later, then `tor-haproxy`. Back with `nice-dns switch proxy socat` → rc 0, `Switched: … tor-socat`.
> - Hardened switch: not repeated (per the brief). Receipt `sa-hardened.tsv` on both hosts: `Switched: Pi-hole is now the hardened one, and DNS is answering.`, `pihole_running hardened`, source commit unchanged, the four checkout paths `absent`. I checked myself that neither host has a `pi-hole-hardened` directory anywhere within 4 levels of ~ (the mac has `~/dev/hardened-unbound`, a different repo). The kept source `~/.local/share/nice-dns/source` is not a git checkout and carries `pihole-hardened/`.
> - Scheduled check by hand: mint `systemctl --user start nice-dns-health-update.service` → `Finished … update check (checks only; installs nothing)`, `checked_at` 1794387887 → 1794389210. mac `launchctl kickstart -p gui/501/org.nice-dns.health-update` → runs=1, last exit 0, `checked_at` 1794387888 → 1794389227. Result on both: `available 671d95031d6b`. The GUI banners show "A different version is available: 671d95031d6b" with Apply / "Install it…".

> ## Outcome 3
> > A release asset cannot be fetched or its sha256 differs → the install goes on without the GUI, as today; the stack and the command are installed

> Verdict: holds for "cannot be fetched". The "sha256 differs" case was not caused: I could not get a tampered asset onto the real release URL by the user's route without a man-in-the-middle setup.

> Evidence:
> - mint: appended `0.0.0.0` entries for github.com, objects/release-assets.githubusercontent.com and api.github.com to /etc/hosts. A probe curl failed (exit 7). Then `nice-dns reinstall --local` (09:30:33→09:34:07) printed `! The nice-dns-gui download failed (curl exit 7): GUI not installed; reinstall with network to add it.` and exited rc 0. New generation `20261111T093033Z`, socat/standard. `nice-dns` (mtime 09:34:07) and `nice-dns-health` were rewritten, and dig answered. /etc/hosts was then restored (no github lines, backup removed).
> - The previously installed v1.4.0 GUI stayed in place (same hash, launcher kept). "As today" holds: no stack failure, and the old app is not removed.

> ## Outcome 4
> > A live cell fails → its receipt row names the cell and the step; only that cell is rerun (DEC-009); the target is put back on its recorded choices

> Verdict: does not hold (the receipt does not name the step)

> Evidence (from the stage's own failed runs; I did not cause a new mid-cell failure, which would cost a full live run):
> - Run 20261111T081051Z-77a532b4: SA-PROXY failed on both cells (`ASSERT FAIL: the switch kept the installed commit: expected [56ade75…] got [unknown]`). Its receipt has only `cell macos socat standard mac generation=… failed` and `cell linux … failed`. There is no scenario row and no step name. `cells/*/cell.tsv` carries no step either. The step is named only in the console and case logs (`t_03_proxy/case.log`, `sa_proxy passed on every platform (failed: linux macos)`).
> - My offline run (Outcome 5) also wrote a receipt with no cell rows at all.
> - "Only that cell is rerun": not shown either way. Both cells failed in 77a532b4, and the next run (085255Z) reran the whole group on both. `tests/run.sh` offers `--platforms`, but no single-cell rerun was exercised.
> - "Put back on recorded choices": holds. In 77a532b4, `sa-restore.tsv` on mint and mac → `reinstalled yes, variant socat, pihole standard, resolves yes` (mint also `polkit_test_rule absent`).

> ## Outcome 5
> > A live target is offline → the cell is not run and the gate is not ticked; the owner is asked to wake it

> Verdict: does not hold as written (no wake request). The cell is not run and the gate is not ticked.

> Evidence:
> - Route: `NICE_DNS_TEST_ARTIFACTS=<scratch> bash tests/run.sh live switch-autocheck --live --targets tests/live/targets.env`, with a PATH `ssh`/`scp` shim. The shim passes `ssh -G` through and sends real connections for `mint`/`mac` to 192.0.2.1, so they time out like a sleeping host. Artifacts went to my scratchpad so the suite's newest receipt is untouched, and `git status` of the tree was unchanged. The shim log shows only `-G` lookups and one `NICE_DNS_OP=snapshot` connect per host. Nothing reached either machine.
> - Output: `ASSERT FAIL: could not reach mint to snapshot it: ssh: connect to host 192.0.2.1 port 29123: Connection timed out` (same for mac). Every later step said `no cell recorded (t_1_before failed); sa_install not run`. `t_08_receipt` → `at least one fully passed cell` not found. `result=fail`, rc 1. The receipt has no cell rows.
> - Missing: nothing in the console, the case logs or the receipt asks the owner to wake the host (I searched for wake/offline/asleep). It is reported as 7 ordinary FAILs, not as "not run: target offline". If the plan means the gate's operator, not the harness, to ask the owner, this Outcome holds. If it means the harness, the message is missing.
> - My first attempt, with a shim that also rewrote `ssh -G`, failed instead on the host-key check: `host key for 192.0.2.1 is not in known_hosts…`. That is my shim's artifact, not a product defect.

> ## Other findings

> Blocking
> - B1 (Outcome 4): a failed cell's receipt row says only `failed`. It does not name the step (e.g. SA-PROXY). The close-out reader must open the case logs to find it.
> - B2 (Outcome 5): an unreachable target is reported as generic FAILs across all 7 steps. No request to wake the host appears in the output or the receipt. Downgrade to Material if the wake request is the operator's job, not the harness's.

> Material
> - M1: on mint, the app's switch cannot complete without a person at the machine for polkit. The only app-route proof on Linux rests on the stage's temporary polkit rule (the receipt says so). This is a stated limit, not a defect, but no person-authorised switch from the app on mint has been seen.
> - M2: the sha256-mismatch half of Outcome 3 was not exercised by a user route in this demo.
> - M3: a CLI install over ssh on mint prints four `Error creating textual authentication agent … /dev/tty` lines and `nice-dns-helper could not run 'pin'/'dns'/… (exit 127); running it through sudo`. It works, but reads like failures to an operator.

> Minor
> - m1: the Linux GUI reports `nice-dns-gui 0.2.0` while the mac app reports `1.4.0` for the same v1.4.0 release.
> - m2: on mint the selectors are below the fold of the default window. The first screen shows Containers, Bridges and Controller, not the switches.
> - m3: right after a switch, `status` Install shows the new variant but Containers keeps the old proxy name until the next controller pass (~1 min).
> - m4: a refused polkit prompt also prints `nice-dns install: the DNS ownership check failed (exit 126); nothing was changed.` The real cause is the cancelled authorisation.
> - m5: the blocked-asset message says "GUI not installed" while the previous GUI is still installed and works.
> - m6: the mac (before) and mint (after reinstall) controllers show `verdict FAIL [route:cloudflare-onion …]` while the selected route answers. This looks like onion-route warm-up and is outside this stage.

> ## End state
> - mint: generation 20261111T093033Z-652f00ea7016, socat/standard, containers pi-hole/unbound/tor-socat, `dig @127.0.0.1 cloudflare.com` → 104.16.132.229/133.229, GUI v1.4.0 hash, /etc/hosts restored.
> - mac: generation 20261111T092726Z-652f00ea7016, socat/standard, `container ls` pi-hole/unbound/tor-socat, `dig @172.31.240.250 cloudflare.com` answers, app v1.4.0.
> - Background jobs: all finished (switches, waiter, blocked-asset reinstall, two offline harness runs). None running.

---

# Appendix: evaluator report stage3-redemo.md

> # Stage 3 re-demo: Outcomes 4 and 5 (nice-dns, app-switches-autocheck @ bfcdd21)

> Route used for every run: from the repo, with `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` set,
> `systemd-run --user --wait --pipe --quiet --same-dir -E PATH -E HOME -E NICE_DNS_TEST_ARTIFACTS [-E NICE_DNS_CELL_REUSE_RUNS] bash tests/run.sh live switch-autocheck --live --targets tests/live/targets.env [--platforms macos]`,
> then `bash tests/run.sh receipt switch-autocheck`. Artifacts went under `$SP/redemo/art*` ($SP = this scratchpad), never the stage's state dir.
> I read no source and no diff. The only repo files I read were `tests/live/targets.env`, the `--help` text and the stage premise. I also read DEC-009 in the vault.

> Start state (10:08Z): mint and mac both on socat/standard, DNS answering. mint generation 20261111T093033Z-652f00ea7016. mac generation 20261111T092726Z-652f00ea7016. mint's controller already showed `verdict FAIL [route:cloudflare-onion]` before I ran anything.

> ## Outcome 4
> > A live cell fails → its receipt row names the cell and the step; only that cell is rerun (DEC-009); the target is put back on its recorded choices

> Verdict: does not hold

> Evidence:
> - Failure caused: `ssh mac 'mkdir ~/pi-hole-hardened'`, then the live command with `--platforms macos` (run 20261111T100938Z-5521361b, 8 s, rc 1), then `rmdir`.
> - **Names the cell and the step: holds.** Console: `ASSERT FAIL: before: no pi-hole-hardened checkout on the host the old sibling lookup could use: expected [] got [/Users/user/pi-hole-hardened]`. Each later step says `sa_before did not pass on mac; this step does not run`. The kept receipt has these rows:
>   - `cell	macos	socat	standard	mac	generation=	failed`
>   - `scenario	SA-BEFORE	macos/socat/standard	fail	-	-	generation=`
>   - `run.sh receipt` → `cell macos/socat/standard failed (a failed cell is never green)`, `scenario SA-BEFORE (macos/socat/standard) is fail`, rc 1.
>   - The same holds with both cells failing (runs 101131Z-5e18a59d and 101248Z-9d18920e): one `cell` row and one `scenario SA-BEFORE` row per platform.
> - **Only that cell is rerun: half.** `--platforms macos` executes only the mac cell. In run 101320Z-8e9c7816 an ssh shim logged every call: 0 calls to mint, and only probe/snapshot/lifecycle-report/command/switch-report ops to mac. But the passed mint cell is never carried, and nothing says why.
>   - I set `NICE_DNS_CELL_REUSE_RUNS` three ways:
>     - (a) the state-dir run `/home/user/.local/state/nice-dns-tests/runs/20261111T085255Z-71eb1196`, which holds passed `linux` and `macos` cells at 652f00e;
>     - (b) a copy of that run and its kept receipt inside my artifact root;
>     - (c) (b) plus `--platforms macos`.
>   - Every receipt says `reused=0` with no `reuse` row. No run output, case log or artifact mentions reuse or a refusal (`grep -ri reuse` over the run dirs is empty).
>   - The rerun's receipt then fails `no observed linux cell`. So rerunning only the failed cell can never produce a receipt that verifies. The owner is not told whether reuse was refused (the brief expects that, since files changed since 652f00e) or ignored.
>   - DEC-009 says reuse is "visible, never silent".
> - **Put back on recorded choices: the target is fine, but the harness says it is not.** After every run the mac and mint kept the same generation, socat/standard, and DNS answering (checked with `nice-dns status` and `dig`). But `t_06_restore` prints `ASSERT FAIL: no recorded choices (sa_before did not finish)` and `ASSERT FAIL: mac is not back on its recorded choices (above)`. The same appears for mint in the two-cell runs.
>   - The choices were in fact recorded: `switch-autocheck/mac/status-before.tsv` has `variant socat` and `pihole standard`.
>   - The restore op never reached the target (no restore op in `ops.log`).
>   - Restore after a failure midway through a cell, once the target has been changed, was not exercised. That needs most of a full cell, which is over the cost limit.

> ## Outcome 5
> > A live target is offline → the cell is not run and the gate is not ticked; the owner is asked to wake it

> Verdict: holds

> Evidence:
> - Offline faked with a PATH `ssh`/`scp` shim. It passes `ssh -G` through and sends mint/mac to 192.0.2.1 (ConnectTimeout 5), so they look asleep.
> - Run 20261111T100829Z-c8b0d631 (`--platforms macos`, 16 s, rc 1):
>   - `ASSERT FAIL: OFFLINE: mac does not answer (). The cell is not run. Ask the owner to wake mac (mint: its Wi-Fi after a suspend), then rerun only this platform: --platforms macos`
>   - Every later step: `mac: no cell recorded (t_1_before failed); sa_<step> not run`.
>   - `t_08_receipt`: `every selected target answered (offline: macos ask the owner to wake it, then rerun only that platform)`.
> - Shim log: only `ssh -G mac` and one `NICE_DNS_OP=probe` connection. No snapshot, install or other op was attempted. `ops.log` has `probe` only. `offline.tsv` has `offline	macos`.
> - Gate not ticked: `run.sh receipt` → `no observed linux cell`, `no observed macos cell`, `cells=0 errors=2`, rc 1. The receipt has no cell rows.
> - Both offline, with no `--platforms` (run 100907Z-f0e186bf): one OFFLINE/wake line per host, each with its own `--platforms linux|macos` rerun hint. Only probes were sent. rc 1.

> ## Other findings

> Blocking
> - B1 (Outcome 4, DEC-009): `NICE_DNS_CELL_REUSE_RUNS` is silently ignored. It was tried three ways, including a single-platform rerun. Every receipt shows `reused=0` with no reuse row, and nothing says why. A run with `--platforms` alone can never verify (`no observed linux cell`). So "only that cell is rerun" cannot close the gate, and the owner gets no reason.

> Material
> - M1: on a cell that failed in SA-BEFORE, `t_06_restore` says `<host> is not back on its recorded choices` and `no recorded choices`. In fact nothing changed and the choices were captured in `status-before.tsv`. The owner is told a healthy machine is off its choices, and the target is never checked.
> - M2: a failed (online) cell prints no rerun hint. The offline path prints `rerun only this platform: --platforms <p>`; the failure path does not. It also does not mention carrying the other cell.

> Minor
> - m1: the offline message has an empty reason: `mac does not answer ()`. The probe log has the real cause (`Connection timed out`).
> - m2: `run.sh receipt` on an offline run says only `no observed <p> cell`. The receipt keeps no offline row, so the wake request lives only in the console and case logs.
> - m3: verifier messages contradict each other on a failed cell: `scenario SA-BEFORE names macos/socat/standard, which is not an observed cell`, while the receipt has that `cell` row. It also says `artifact '-' is not a regular file inside the receipt dir`.
> - m4: receipts of runs where nothing ran still carry `limit` rows that describe things done (for example, "the helper was authorised by a temporary polkit rule").
> - m5: runs record `git_dirty yes` and `source nice-dns … dirty` because of the untracked `proof/.../stage-3/demo.md`. The live command did not refuse. That is fine for untracked files, but the receipt then labels the source dirty.
> - Observation (not caused by me): mint's controller showed `verdict FAIL [route:cloudflare-onion]` at the start. DNS answered throughout.

> Overall: FAIL. B1 is Blocking.

> End state (10:14Z): mint has generation 20261111T093033Z-652f00ea7016, socat/standard, `dig @127.0.0.1 cloudflare.com` answers, no `~/pi-hole-hardened`, polkit test rule absent. The mac has generation 20261111T092726Z-652f00ea7016, socat/standard, `dig @172.31.240.250 cloudflare.com` answers, no `~/pi-hole-hardened`. Repo is at bfcdd21 with no change from me. No background jobs were started.

---

# Appendix: evaluator report stage3-redemo2.md

> # Stage 3 re-demo 2: Outcome 4 (nice-dns, app-switches-autocheck @ f1cbc1b)

> I read no source and no diff. My runs went through the owner's command:
> `systemd-run --user --wait --pipe --quiet --same-dir -E PATH -E HOME -E NICE_DNS_TEST_ARTIFACTS -E NICE_DNS_CELL_REUSE_RUNS bash tests/run.sh live switch-autocheck --live --targets tests/live/targets.env --platforms macos`.
> Before it I set `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`. Then I ran `bash tests/run.sh receipt switch-autocheck` with the same artifact root.

> - Artifacts: `$R/art1..art4`, where `$R` = `/tmp/claude-1000/-home-user-dev-containers-nice-dns/c4bdc364-2d43-4631-b08b-d2c9a861224d/scratchpad/redemo2`.
> - Console output: `$R/run1.log`..`$R/run4.log`.
> - Two PATH shims:
>   - `$R/bin`: host `mac` goes to 192.0.2.1, so it looks asleep.
>   - `$R/bin2`: `mac` answers the read-only `probe` op, and every later connection times out. So the target answers, then the cell fails at its first step.
> - `ssh -G` passes through both shims, and mint is never redirected. Neither shim sent a single op to mint.

> Start state (11:15Z): mint was on generation 20261111T110944Z-f1cbc1b37037, socat/standard, and answering. The mac was on 20261111T105436Z-f1cbc1b37037, socat/standard, and answering. No test run was in progress.

> ## Outcome 4
> > A live cell fails → its receipt row names the cell and the step; only that cell is rerun (DEC-009); the target is put back on its recorded choices

> Verdict: holds

> Evidence:
> - **Receipt names the cell and the step (owner's run 20261111T103616Z-8a709d2a, `live-sa4.log`).**
>   - The mint install failed on `nice-dns-gui download failed (curl exit 7)`.
>   - The kept receipt has `cell linux socat standard mint generation= failed` and `scenario SA-INSTALL linux/socat/standard fail`.
>   - The console's last line is: `cell(s) failed on: linux (the receipt names each one's step). Rerun only those: --platforms linux with NICE_DNS_CELL_REUSE_RUNS=/home/user/.local/state/nice-dns-tests/runs/20261111T103616Z-8a709d2a`.
> - **Only that cell is rerun, and the rerun passes (owner's run 20261111T105714Z-dd1bef02, `live-sa5.log`).**
>   - The owner followed that line exactly. The run passed 8/8 at rc 0.
>   - The receipt has a fresh linux cell (generation 20261111T105740Z-f1cbc1b37037, six scenarios pass).
>   - It also has the mac cell carried with `reuse macos/socat/standard 20261111T103616Z-8a709d2a f1cbc1b…`.
>   - `run.sh receipt switch-autocheck` (state dir) prints `cells=2 scenarios=12 errors=0 limits=4 reused=1`.
>   - The rerun clause the last re-demo found broken now works on the owner's route.
> - **A refused carry says why, when the target answers.** I ran run 4 twice, as run 2 and run 4, each in about 16 s at rc 1. The bin2 shim was on, so the mac cell failed at its snapshot.
>   - Run 20261111T111829Z-bdc6c317, with the 652f00e run as `NICE_DNS_CELL_REUSE_RUNS`. `t_08_receipt` prints: `no cell for: linux. NICE_DNS_CELL_REUSE_RUNS=/home/user/.local/state/nice-dns-tests/runs/20261111T085255Z-71eb1196 carried none: linux: the product files changed since 652f00ea7016 (lib/install.sh proof/…/3.3/claim-1.json proof/…/3.4/claim-1.json ); Run that platform too, or name a run whose cell passed at this product and scenario`.
>   - Run 20261111T111945Z-0e0018f4, with the 103616Z run (whose linux cell failed). It prints: `carried none: linux: the cell did not pass: sa_install sa_proxy sa_hardened sa_update; Run that platform too, …`.
> - **A refused carry is silent when the selected target is offline. This is what the brief asked me to check.** Run 20261111T111634Z-43a06d2b used the bin shim, `--platforms macos` and the 652f00e run. It took 15 s, rc 1.
>   - The console shows `OFFLINE: mac does not answer (ssh: connect to host 192.0.2.1 port 22: Connection timed out). The cell is not run. Ask the owner to wake mac …, then rerun only this platform: --platforms macos`.
>   - `t_08_receipt` says only `every selected target answered (offline: macos …)`.
>   - The console never mentions the Linux carry. Neither do `t_08_receipt/case.log`, the receipt (no `reuse` row, no refusal row) or `run.sh receipt`, which says only `no observed linux cell` and `no observed macos cell` with `reused=0`.
>   - The reason exists only in an internal file, `cases/live-switch-autocheck/t_08_receipt/reuse-refused.tsv` (`linux … the product files changed since 652f00ea7016 (…)`).
>   - See M1.
> - **An accepted carry while the selected target is offline.** Run 20261111T111929Z-4b97656a, with the 105714Z run as reuse and mac offline.
>   - The receipt has the carried linux cell and its `reuse linux/socat/standard 20261111T105714Z-dd1bef02 f1cbc1b…` row.
>   - `run.sh receipt` prints `cells=1 … reused=1` and fails only on the missing macos cell.
>   - Only one op (`probe`) went to mac. None went to mint.
> - **The target is put back on its recorded choices (owner's run 103616Z, mint failed at install).** The restore still ran, as these files under `switch-autocheck/mint/` show:
>   - `restore-choices.tsv` has `variant socat`, `pihole standard`, `resolves yes`.
>   - `status-restore.tsv` has socat/standard.
>   - `sa-restore.tsv` has `result pass` and `polkit_test_rule absent`.
>   - `polkit-remove.tsv` has `absent`.
>   - `ops.log` ends in `polkit-test-rule --mode remove`.
>   - `t_06_restore` passed. The mac in the same run also passed SA-RESTORE.
>   - After my four runs both machines kept the same generations, choices and DNS, since only probe and snapshot ops were sent to mac.
> - **Earlier findings now fixed.**
>   - The offline reason is no longer empty (was m1).
>   - A failed online cell prints a rerun line (was M2).
>   - A cell that failed early prints `sa_restore not run`, not the false `not back on its recorded choices` (was M1).

> ## Other findings

> Blocking
> - None.

> Material
> - **M1: a refused carry is not reported when the selected target is offline.** Run 111634Z says nothing about the Linux cell it could not carry, and its advice is "rerun only this platform: --platforms macos". If the owner wakes the mac and follows that advice with the same `NICE_DNS_CELL_REUSE_RUNS`, a full mac cell runs (about 20 minutes). Only then does `t_08_receipt` say that Linux was not carried and must be run too. The reason is already computed in `reuse-refused.tsv`, but it is never printed, and it is not in the receipt or in `run.sh receipt`. This goes against DEC-009's "visible, never silent". It is not Blocking: the refusal does reach the owner, with the reason, in the first run that executes a cell.
> - **M2: a cell that fails at its first step after the target answered leaves no row in the receipt.**
>   - In runs 111829Z and 111945Z, mac answered the probe and its snapshot then timed out. The console names the host and step: `could not reach mac to snapshot it: ssh: connect to host 192.0.2.1 …`.
>   - But the kept receipt has no `cell macos … failed` row and no `scenario SA-BEFORE … fail` row. `t_08_receipt` names only the missing Linux carry, not the failed mac cell, and gives no rerun line for it. `run.sh receipt` says only `no observed macos cell`.
>   - This is not classed as offline either, so there is no wake request.
>   - The owner's own failure (at SA-INSTALL) and the last re-demo's SA-BEFORE assertion failure did get rows. This gap is the "connection lost between probe and snapshot" case.

> Minor
> - **m1: proof files count as product files in a refusal reason.** The list in "the product files changed since 652f00ea7016 (…)" includes `proof/…/claim-1.json`. Here `lib/install.sh` also changed, so the refusal is right. But the list suggests proof churn alone would block a carry.
> - **m2: an accepted carry is not mentioned on the console.** It shows only in the receipt's `reuse` row and in `run.sh receipt`'s `reused=1`. This holds for the owner's passing rerun and for my run 111929Z. That is DEC-009's chosen place for it, so this is a nit.
> - **m3 (carried over): the receipt calls the source dirty.** Receipts still record `source nice-dns … dirty` and `git_dirty yes` because of the untracked `proof/…/stage-3/demo.md`.

> Overall: PASS with residuals (M1, M2, m1–m3). Outcome 4 holds on the owner's route: a cell fails, the receipt and console name the cell and step, the one-platform rerun passes with the other cell carried, and the failed target is restored with the polkit rule removed.

> End state (11:20Z):
> - mint: generation 20261111T110944Z-f1cbc1b37037, socat/standard. `dig +short @127.0.0.1 cloudflare.com` returned 104.16.132.229 and 104.16.133.229. The polkit test rule is `absent`.
> - mac: generation 20261111T105436Z-f1cbc1b37037, socat/standard. `dig +short @172.31.240.250 cloudflare.com` returned 104.16.133.229 and 104.16.132.229.
> - Repo: still at f1cbc1b. The only untracked file is the pre-existing `proof/…/stage-3/demo.md`, and I made no edits.
> - No test runs are in progress. I started no background jobs. Every run was in the foreground and finished.
