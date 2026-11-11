# Close-out demo — 2026-11-10-app-switches-autocheck-plan

Finished build: product files at f1cbc1b (HEAD ebeb708 changes only tests and proof records); both targets run it.

Evaluator: close-out demo, 2026-11-11 11:38Z–12:35Z. No source and no diff read. Read only: docs/cli-contract.md (the user contract), gui/share/actions.tsv, release/assets.lock, the Stage 3 demo record and the kept receipt.
Routes used:
- Terminal: `ssh mint` / `ssh mac`, `export PATH=$HOME/.local/bin:$PATH`, then `nice-dns ...` / `nice-dns-health ...`. On mint, user-bus commands with `XDG_RUNTIME_DIR=/run/user/1000`. On the mac, commands that need the container runtime ran in the gui domain (`sudo launchctl asuser 501 sudo -u user ...`).
- Linux app, as a person: the installed `nice-dns-gui` (v1.4.0 bytes) in normal mode in an Xvfb display on mint (`GSK_RENDERER=cairo GDK_BACKEND=x11`), window resized to 900x1950 so the Installed section shows. Driven with real pointer and keyboard events (`xdotool`), captured with `xwd`. Not a hook. Screens are under `shots/mint-x-*.png`.
- Linux app hooks, where marked: `--probe`, `--check`, `--screenshot`.
- macOS app: `NiceDNSGUI --run-action <id> --exit`, `--screenshot`, `--check`, `--version` in the gui domain. This is a hook, not a click. The menu cannot be opened from here: `osascript` has no assistive access ("osascript is not allowed assistive access") and `screencapture` gets "could not create image from display". Nobody is at the mac.
Failures caused: /etc/hosts entries for one command each, backed up and restored every time (`0.0.0.0` for the image registries; `10.255.255.1`, a black hole, for github.com); an empty HOME; the kept source moved aside for one command; the app's status command replaced (Stage 2 Outcome 7 only).
Reinstalls: mac 4 (2 by the app's action, 2 from the CLI) plus 1 failed. mint 4 switches that finished (2 from the app by clicks; 1 of them unplanned, see Stage 2 Outcome 5) plus 2 failed.

# Stage 1

## Outcome 1
> Works: `nice-dns switch proxy socat` (or `haproxy`) and `nice-dns switch pihole hardened` (or `standard`) reinstall the kept source with that one choice changed; the last line says what now runs and that DNS answers; `nice-dns status` shows the new `variant` or `pihole`, and the same `source_commit` as before
Verdict: holds
Evidence:
- mac, `nice-dns switch pihole hardened` (gui domain), 11:46:38→11:49:08, rc 0.
  - Last line: `Switched: Pi-hole is now the hardened one, and DNS is answering.`
  - status: generation 20261111T114432Z → 20261111T114638Z-f1cbc1b37037, `pihole hardened`, `variant haproxy` kept, `source_commit f1cbc1b3703772c55934c18e790c27a862e0b558` unchanged.
  - `dig @172.31.240.250 cloudflare.com` → 104.16.133.229, 104.16.132.229.
- mac, `nice-dns switch proxy socat`, 11:54:30→11:55:59, rc 0.
  - Last line: `Switched: the proxy is now tor-socat, and DNS is answering.`
  - status: `variant socat`, same source_commit.
  - `container ls` → tor-socat running at .252. dig answered.
- mint, `nice-dns switch proxy socat` (from haproxy), rc 0 after 490 s. Tor took long to bootstrap: mint's onion routes were already unhealthy at dispatch, so the slowness is the network.
  - Last line: `Switched: the proxy is now tor-socat, and DNS is answering.`
  - status: generation 20261111T115431Z, `variant socat`, `pihole standard`, same source_commit.
  - `podman ps` → tor-socat, unbound, pi-hole. `dig @127.0.0.1 cloudflare.com` answered.
- The app actions run the same commands: mac `--run-action proxy-haproxy` and `pihole-standard`, and mint by clicks (Stage 2). Each ended with the same last line, and status agreed.

## Outcome 2
> Works: a switch to hardened builds the base from the nice-dns tree on a machine that has no pi-hole-hardened checkout
Verdict: holds
Evidence:
- mac switch to hardened (Outcome 1). Before: `find ~ -maxdepth 4 -type d -name 'pi-hole-hardened*'` → nothing.
- The installer printed:
  - `▸ Preparing generation 20261111T114638Z-f1cbc1b37037 (source checkout, commit f1cbc1b…)`
  - `▸ Preparing the hardened base (built from the nice-dns tree after the stack stops)…`
  - `• Building the hardened base from pihole-hardened/base.`
  - `docker.io/library/pi-hole-hardened-base:20261111T114638Z-f1cbc1b37037`
  - `All done. DNS is set to 172.31.240.250 (pi-hole, hardened base).`
- The window then showed Pi-hole [hardened] (`shots/mac-M2-after-hardened.png`).
- mint: I did not repeat the hardened switch (each mint reinstall took 3–8 min today). The kept receipt at f1cbc1b has `SA-HARDENED linux/socat/standard pass`, and `run.sh receipt` verifies it. mint has no `~/pi-hole-hardened` or `~/dev/pi-hole-hardened`.

## Outcome 3
> Works: twice a day the controller runs the check; `nice-dns status` shows its result and time in the `update` rows, and `update auto loaded`
Verdict: holds
Evidence:
- mint, a real calendar firing, not started by hand:
  - Timer: `OnCalendar=*-*-* 00/12:00:00`, `RandomizedDelaySec=30m`, `Persistent=true`.
  - Journal: `12:00:12 Starting nice-dns-health-update.service - nice-dns update check (checks only; installs nothing)…` / `12:00:22 Finished …`.
  - `list-timers` then: LAST 12:00:12, NEXT Thu 00:08:59.
  - status: `update result unknown`, `checked_at 1794398422` (12:00:22Z), `remote_commit -`, `auto loaded`.
  - health.log: `UPDATE-CHECK rc=1 unknown: could not reach https://github.com/sureserverman/nice-dns.git (offline, or DNS down?)`. A switch had the stack's DNS down at that moment, so this is Outcome 9's case, met for real.
  - The receipt's limit `schedule-by-hand` ("its 12-hour calendar firing was not waited for") is now covered on Linux.
- mac: agent `org.nice-dns.health-update` with calendar Hour 4/16, Minute 47. status `auto loaded`. No calendar slot fell inside my session (next one 16:47), so the mac check was started by hand: `launchctl kickstart`, runs=2, last exit 0, `checked_at 1794398317 → 1794398320`, `result available`, health.log `UPDATE-CHECK rc=10 available 671d95031d6b`.

## Outcome 4
> The choice asked for is the one installed → `Already <choice>; nothing changed.`, exit 0, nothing is reinstalled
Verdict: holds
Evidence: On mint and on the mac, on socat/standard:
- `nice-dns switch proxy socat` → stdout `Already socat; nothing changed.`, stderr empty, rc 0.
- `nice-dns switch pihole standard` → `Already standard; nothing changed.`, rc 0.
- The generation was the same before and after: mint 20261111T110944Z, mac 20261111T105436Z.

## Outcome 5
> Nothing is installed → `nice-dns is not installed; run nice-dns install` on stderr, exit 1
Verdict: holds
Evidence: On both hosts I used an empty HOME (`mktemp -d`) and ran `env HOME=$E PATH=... ~/.local/bin/nice-dns switch proxy haproxy` and `... switch pihole hardened`. Each gave stdout empty, stderr ``nice-dns: nice-dns is not installed; run `nice-dns install` ``, rc 1.

## Outcome 6
> No kept source (an install older than the kept source) → stderr names the missing directory and `nice-dns reinstall`; exit 1; the stack is untouched
Verdict: holds
Evidence: On both hosts I ran `mv ~/.local/share/nice-dns/source{,.closeout-aside}`, then `nice-dns switch proxy haproxy` and `nice-dns switch pihole hardened`, then moved the source back (15 entries).
- Each run: stdout empty, rc 1, stderr ``nice-dns: no kept source at /home/user/.local/share/nice-dns/source (an install older than the kept source). Run `nice-dns reinstall` to install from the branch; the stack is untouched.`` (mac: /Users/user/…).
- Generation, variant and pihole were unchanged on both.

## Outcome 7
> The install fails (a build or pull fails, DNS does not come back) → the installer restores the running stack; stderr says the switch did not happen and the old choice still runs; exit 3
Verdict: holds (the pull-failure case; "DNS does not come back" not caused)
Evidence: I blocked the image registries in /etc/hosts (registry-1.docker.io, auth/index.docker.io, docker.io, production.cloudflare.docker.com, dl-cdn.alpinelinux.org → 0.0.0.0) for one `nice-dns switch proxy socat` on each host, from haproxy, then restored the file.
- mint: rc 3 after 25 s.
  - stderr: podman's `unable to copy from source docker://pihole/pihole@sha256:30f803… dial tcp 0.0.0.0:443: connect: connection refused`, then `nice-dns: the switch did not happen (installer exit 1); the installer keeps or restores the running stack, so tor-haproxy still runs.`
  - After: generation 20261111T114906Z unchanged, `variant haproxy`, `podman ps` → tor-haproxy unbound pi-hole, dig answers.
- mac: rc 3 after 58 s.
  - stderr: `Error: POSIXErrorCode(rawValue: 61): Connection refused` / `nice-dns: the switch did not happen (installer exit 1); …so tor-haproxy still runs.`
  - After: generation 20261111T115121Z unchanged, `container ls` → tor-haproxy pi-hole unbound running, dig answers.
- From the app on mint, the same failure came later in the run, after a pull that was retried (about 3.5 min). The stack came back on the old generation (Stage 2 Outcome 5).

## Outcome 8
> A wrong or missing word (`switch proxy nginx`, `switch`) → a usage line on stderr, exit 2, nothing runs
Verdict: holds
Evidence: On both hosts, each of these gave stdout empty and rc 2, with the generation unchanged:
- `switch proxy nginx` → `nice-dns: switch proxy takes haproxy or socat`
- `switch` → `nice-dns: switch takes proxy or pihole`
- `switch pihole` → `nice-dns: switch pihole takes standard or hardened`
- `switch proxy socat extra` → `nice-dns: switch takes two words: proxy haproxy|socat, or pihole standard|hardened`
- `switch tor socat` → `switch takes proxy or pihole`
Each reason line was followed by the full 40-line `Usage:` text (Minor m2).

## Outcome 9
> The scheduled check cannot reach GitHub or runs past 60 s → the cache says `unknown`, with the time; nothing else changes; the next slot tries again
Verdict: holds
Evidence: I added `10.255.255.1 github.com` (a black hole: the connection hangs) to /etc/hosts for one run of the scheduled job, then restored the file.
- mint: `systemctl --user start nice-dns-health-update.service` returned after 56 s.
  - status: `result unknown`, `checked_at 1794398793`, `remote_commit -`, `auto loaded`.
  - health.log: `UPDATE-CHECK rc=1 unknown: could not reach https://github.com/… (offline, or DNS down?)`.
  - The next run with the network back gave `result available`, `checked_at 1794398802`.
  - The app's Update row followed: "unknown (checked just now)" with the banner gone, then "available: 671d95031d6b (checked just now)" with the banner back (`shots/mint-x-12-schedule-unknown-then-available.png`).
- mac: `launchctl kickstart -p gui/501/org.nice-dns.health-update`; the job ended after 57 s, under the 60 s bound.
  - status: `result unknown`, `checked_at 1794398317`, `remote_commit -`.
  - health.log has the same unknown line.
  - The next run gave `available`, `checked_at 1794398320`.
- Generation, variant and pihole stayed the same through each check, and the schedule stayed loaded.
- The 12:00 calendar firing on mint (Outcome 3) is the same case met for real, with DNS down during a switch.

## Outcome 10
> The schedules were stopped with `nice-dns-health stop` → `update auto stopped`; no check runs until `start`
Verdict: holds
Evidence:
- mint, with the user bus: `nice-dns-health stop` → `Timers stopped.`, rc 0.
  - status: `controller schedule stopped`, `update auto stopped`.
  - `systemctl --user list-timers 'nice-dns*'` → `0 timers listed.`
  - `nice-dns-health start` → `Timers started.`. Then `auto loaded`, and the update timer was back, NEXT 12:01:31.
- mac: `nice-dns-health stop` → `LaunchAgents unloaded.`, `controller schedule stopped`, `update auto stopped`. `start` → `LaunchAgents loaded.`, `auto loaded`.
- "No check runs" rests on the unloaded timer and agent. No slot fell inside the stopped minute.
- From plain ssh, with no user bus, mint's stop printed `Failed to connect to bus: No medium found` three times, then `Timers stopped.` with rc 0. Nothing had stopped: status still said `loaded` (Minor m1).

# Stage 2

## Outcome 1
> Works: the Installed section shows a Proxy selector (haproxy, socat) and a Pi-hole selector (standard, hardened) set to what `status` says; on macOS the menu has the same two choices as submenus with a check mark
Verdict: holds on Linux and in the macOS window; the macOS menu's submenus with a check mark: cannot reach by the user's route
Evidence:
- mint, a person's view (real window, real clicks):
  - The Installed section shows Generation, Source commit, Proxy [socat ▾], Pi-hole [standard ▾], Update and Helper (`shots/mint-x-1-open.png`).
  - Clicking Proxy opens a list "haproxy / socat ✓" (`shots/mint-x-2-proxy-open.png`).
  - The selectors followed status through every switch: haproxy, then socat (`mint-x-7`, `mint-x-17`).
  - `--probe` agrees: `proxy=socat pihole=standard`.
- mac `--screenshot`: an "Installed" box with Proxy [socat ⌃⌄] and Pi-hole [standard ⌃⌄], which then showed haproxy, then hardened, then socat/standard after each switch (`shots/mac-installed.png`, `mac-M1-after-haproxy.png`, `mac-M2-after-hardened.png`, `mac-end.png`).
- The menu-bar menu could not be opened. I launched the app with `open ~/Applications/nice-dns.app` in the gui session, but System Events refused ("osascript is not allowed assistive access") and screencapture failed. I quit the app afterwards; it had not been running. No hook draws the menu.

## Outcome 2
> Works: picking the other value asks first ("Switch the proxy to socat? The stack is reinstalled from the kept source. This takes a few minutes and DNS stops briefly."); on Switch the action runs with its output in the log pane, the selector shows the new value while it runs, and the next status read confirms it
Verdict: holds (Linux by clicks; macOS by the app's action hook only)
Evidence:
- mint, real clicks, from socat:
  - Picking haproxy opened "Switch the proxy to haproxy? / The stack is reinstalled from the kept source. This takes a few minutes and DNS stops briefly. / Not now | Switch" (`mint-x-3-switch-question.png`).
  - From haproxy, picking socat showed exactly the quoted text: "Switch the proxy to socat?" (`mint-x-14-question-socat.png`).
  - On Switch (11:49:05), the log pane read "Switch the proxy to haproxy … running…" with the installer's lines. The selectors were greyed, Proxy showing haproxy (`mint-x-6-switch-running.png`).
  - At 11:52:14 it ended `Switched: the proxy is now tor-haproxy, and DNS is answering.` / `finished (exit 0)`. The generation became 20261111T114906Z, Proxy [haproxy], and the window header said haproxy (`mint-x-7-switch-finished.png`).
  - `podman ps` → tor-haproxy. dig answered.
- On mint the root steps did not go through polkit. The log pane shows `Error creating textual authentication agent … /dev/tty` and `nice-dns-helper could not run 'dns' (exit 127); running it through sudo`, so they ran through sudo, which is passwordless on mint (see M2).
- mac (hook):
  - `--run-action proxy-haproxy --exit`, 11:44:32→11:46:02: output ends `Switched: the proxy is now tor-haproxy, and DNS is answering.` / `finished (exit 0)`. `container ls` → tor-haproxy at .252, and the picker showed haproxy.
  - `--run-action pihole-standard --exit` (11:51:20→11:52:31) → `Switched: Pi-hole is now the standard one…`, `finished (exit 0)`.
  - The mac's question dialog and its picker while running were not seen: there is no click route and no probe hook.

## Outcome 3
> Works: the Check for an update button and the update banner behave as before; the Update row's "checked ... ago" now also moves when the schedule ran
Verdict: holds
Evidence:
- mint, by clicks: "Check for an update" ran `nice-dns update --check`. The log said `available 671d95031d6b` / `a different version is available (exit 10)`, and the banner "A different version is available: 671d95031d6b [Apply]" came back.
  - The app then opened "Install the update? The branch's commit 671d95031d6b is installed like a reinstall, with the recorded choices. The stack restarts. [Not now | Install]" by itself. I dismissed it each time and nothing was installed (`mint-x-11-check-button-asks-install.png`).
  - I could not compare this with the pre-plan app (m3).
- The Update row moved with the schedule:
  - After the 12:00 calendar firing: "unknown (checked 2 min ago)" (`mint-x-8`).
  - After the scheduled job I started: "unknown (checked just now)", then "available … (checked just now)" (`mint-x-12`).
  - A scheduled check did not open the install dialog.
- mac: the Update row read "available: 671d95031d6b (checked 51 min ago)" before the scheduled job ran, and "(checked 21 min ago)" at 12:20, which is the 11:58:40 run. The banner reads "A different version is available: 671d95031d6b [Install it…]".

## Outcome 4
> Not now or the dialog dismissed → the selector goes back to the installed value; nothing runs
Verdict: holds (Linux by clicks)
Evidence:
- mint: picked haproxy, then clicked "Not now". Proxy went back to [socat], the log pane still said "No action run yet", no child process ran, and the generation was unchanged (`mint-x-4-notnow.png`).
- Picked haproxy again and pressed Escape: Proxy back to [socat] (`mint-x-5-escape.png`).
- `--probe proxy-haproxy` / `pihole-hardened` with `NICE_DNS_GUI_PROBE_ANSWER=cancel` printed `after: … proxy=socat pihole=standard`, `log:` empty.
- macOS: not reachable (no dialog without a click).

## Outcome 5
> The switch fails (exit 3, or a root step not authorised) → the selector goes back to the installed value; the log pane shows the command's stderr and the named exit; a toast says the switch did not happen
Verdict: holds (exit 3 case, Linux by clicks; the not-authorised case was not caused)
Evidence:
- mint on haproxy: picked socat, then blocked the registries and clicked Switch.
  - While running, the selectors were greyed with Proxy on socat (`mint-x-15`).
  - After about 3.5 min the log pane showed podman's `unable to copy from source docker://pihole/pihole@sha256:30f803…: … connection refused` and `nice-dns: the switch did not happen (installer exit 1); the installer keeps or restores the running stack, so tor-haproxy still runs.`, then `failed (exit 3)` in red.
  - The header said "failed (exit 3)", a toast said "The switch did not happen: failed (exit 3)", and Proxy was back on [haproxy] (`mint-x-16-failed-switch-toast.png`, `mint-x-17`).
  - status: generation 20261111T120943Z unchanged, `variant haproxy`. `podman ps` → tor-haproxy, dig answered.
- Not-authorised case: the run that should have shown it went to sudo instead. With no polkit agent, the CLI's sudo fallback ran, and mint's sudo is passwordless. My first failure attempt also restored /etc/hosts 3 s in, because I waited on the wrong process. That run finished a real switch to haproxy (generation 20261111T120943Z), so it added one reinstall. The Stage 3 record saw the polkit refusal from the app on mint: "authorisation cancelled (exit 3)", and nothing changed.

## Outcome 6
> Another action is running → both selectors are disabled until it ends, like every button
Verdict: holds (Linux by clicks)
Evidence:
- mint: clicked "Run a health check now". While `nice-dns-health run` ran ("running…"), Proxy, Pi-hole, the bridges switch and every button were greyed (`mint-x-9-other-action-running.png`).
- When it ended ("failed (exit 1)": the controller was still warming up after a switch, see m4), both selectors were active again (`mint-x-10`).
- The same was seen during each switch (`mint-x-6`, `mint-x-15`).

## Outcome 7
> `status` does not name the variant or the flavour, or names a value outside the two → that selector is disabled and shows `unknown`
Verdict: holds (by the documented status-command override; an installed stack always names both, so the condition cannot be met on a current install)
Evidence:
- `NICE_DNS_GUI_STATUS_CMD=/tmp/cl-status-odd.sh` printed the real `status --tsv` with the `install variant` row dropped and `install pihole` set to `extra-hardened`.
- `--probe proxy-haproxy` (cancel) printed `before: controls=13 disabled=2 … proxy=unknown pihole=unknown greyed=2 … dialog=none`. Nothing was asked and nothing ran.
- The window's header followed the odd status: "extra-hardened Pi-hole", no proxy (`shots/mint-odd-status.png`; the selectors are below that shot's fold).
- Probing the disabled Pi-hole selector printed `pihole=none` after the probe's own click. No dialog, nothing ran; this is a hook-only artifact (m9).

## Outcome 8
> Nothing is installed → the not-installed page, as before; no selectors
Verdict: holds
Evidence:
- mint with an empty HOME: `nice-dns-gui --check` → `not installed; install with: curl -fsSL https://raw.githubusercontent.com/sureserverman/nice-dns/main/install-deb.sh -o install-deb.sh && bash install-deb.sh`, rc 1.
- `--probe proxy-haproxy` → `controls=0 … proxy=none pihole=none … page=not-installed`.
- The screenshot shows "nice-dns is not installed / Install it with this line in a terminal:" and the curl line, with no Installed section (`shots/mint-notinstalled.png`).

# Stage 3

## Outcome 1
> Works: an install or `nice-dns update` on Linux and macOS lands the v1.4.0 apps with the selectors, and the controller's third schedule
Verdict: holds
Evidence:
- Bytes, checked on each host against the v1.4.0 release:
  - mint `~/.local/bin/nice-dns-gui` sha256 134fa40e…7b912 = the binary in `nice-dns-gui-linux-amd64.tar.gz`. The tarball's sha256 8ec5f149… equals `release/assets.lock`.
  - mint `/usr/libexec/nice-dns-helper` e905d418… = lock.
  - mac `NiceDNSGUI` 19f82cd9…77c65 = the binary in `nice-dns-gui-macos-arm64.zip`. The zip's sha256 4b022562… equals the lock. `--version` → `nice-dns-gui 1.4.0`.
  - mac `/usr/local/libexec/nice-dns-helper` a5c8a61d… = lock.
- Every lock row is a v1.4.0 URL.
- My reinstalls (switches) re-landed them, and each printed `Schedule: … nice-dns-health-update.timer … (every minute: …; daily: bridges-refresh; twice a day: update-check)`, or on the mac `org.nice-dns.health-update.plist`.
- The selectors are in both apps (Stage 2 Outcome 1).
- `nice-dns update` itself was not run, because it would install main (671d950) over this build. The switches stand in as the install route, as in the Stage 3 record.

## Outcome 2
> Works: on mint and on the mac, the proxy switch run from the app's own action changes the running proxy container and `status`; the hardened switch builds from the tree with no checkout on the host; DNS answers after each; the scheduled check, started by hand, updates `checked_at`
Verdict: holds
Evidence:
- mac, app action: `--run-action proxy-haproxy` → `container ls` tor-haproxy, `status` haproxy, and dig answered.
- mint, by clicks in the app: tor-haproxy, `status` haproxy, and dig answered. Its root steps went through the sudo fallback, not polkit (M2).
- Hardened from the tree with no checkout: seen on the mac (Stage 1 Outcome 2). On mint, the kept receipt covers it.
- DNS answered after every switch, by `dig @172.31.240.250` on the mac and `dig @127.0.0.1` on mint.
- `checked_at` moved when the check was started by hand: mint 1794398793 → 1794398802, mac 1794398317 → 1794398320. On mint it also moved on the calendar at 12:00:12.
- This agrees with the Stage 3 record.

## Outcome 3
> A release asset cannot be fetched or its sha256 differs → the install goes on without the GUI, as today; the stack and the command are installed
Verdict: holds (fetch failure); sha256-mismatch half not caused
Evidence:
- My last mint switch (`nice-dns switch proxy socat`, from haproxy) ran with github.com, api.github.com, objects/release-assets.githubusercontent.com and codeload.github.com set to 0.0.0.0 in /etc/hosts. I restored the file afterwards.
  - Output: `! The nice-dns-gui download failed (curl exit 7): GUI not installed; reinstall with network to add it.` on stdout and stderr, then `Switched: the proxy is now tor-socat, and DNS is answering.`, rc 0 after 349 s.
  - New generation 20261111T122007Z, `variant socat`, dig answered.
  - The installed GUI kept its v1.4.0 bytes (134fa40e…, mtime 12:15:00, unchanged across the switch) and its launcher.
- This matches the Stage 3 record.
- The sha256-mismatch half was not caused (M3).
- Side note: the failed app switch at 12:15 had already re-landed the same GUI bytes (mtime 12:15:00) before it failed at the pull.

## Outcome 4
> A live cell fails → its receipt row names the cell and the step; only that cell is rerun (DEC-009); the target is put back on its recorded choices
Verdict: holds (per the Stage 3 record at f1cbc1b; not re-run)
Evidence:
- Cheapest re-check: `bash tests/run.sh receipt switch-autocheck` (laptop, read-only) → `receipt=switch-autocheck cells=2 scenarios=12 errors=0 limits=4 reused=1`, rc 0.
- The kept receipt 20261111T105714Z-dd1bef02 is at product f1cbc1b. It has the fresh linux cell and `reuse macos/socat/standard 20261111T103616Z-8a709d2a f1cbc1b…`, as the record says.
- I did not cause a new failed cell, because that costs a full live cell. Nothing I saw disagrees with the record's re-demo 2.

## Outcome 5
> A live target is offline → the cell is not run and the gate is not ticked; the owner is asked to wake it
Verdict: holds (per the Stage 3 record at f1cbc1b; not re-run)
Evidence:
- The record's re-demos 1 and 2 saw `OFFLINE: mac does not answer (ssh: connect to host 192.0.2.1 port 22: Connection timed out). The cell is not run. Ask the owner to wake mac …`, with only a probe sent and the receipt check failing (cells=0).
- Product files are unchanged since re-demo 2 (f1cbc1b).
- I did not repeat it. Both targets answered throughout my session.

# Findings

Blocking:
- B1 (Stage 2 Outcome 1, macOS menu clause): this clause could not be checked by the user's route. Nobody was at the mac, osascript has no assistive access, screencapture is refused, and no hook draws the menu. Nothing seen says it is broken. The owner can clear it by opening the menu once at the mac and checking the two submenus and the check mark.

Material:
- M1 (Linux app, selectors): an open selector list closes by itself when the window refreshes its status. Measured: closed after 1.5 s once and after 23 s once. A person picking slowly loses the list, and their click lands on the row underneath (it opened the Pi-hole list once). Also, while the "Switch the proxy to …?" question is open, a refresh puts the selector back to the installed value behind the dialog. The dialog still names the picked value and Switch still switches. Screens: `mint-x-13-dialog-selector-reverts-on-refresh.png`. The goal is met: picking quickly works every time.
- M2 (carried from Stage 3 M1/M3, sharper): on mint the app's switch never used polkit. In a session with no polkit agent, the helper exits 127 and the command falls back to sudo, which is passwordless on mint, so the switch went through. On a machine where sudo asks for a password this route ends "not authorised". A person-authorised polkit switch from the app is still unseen. Every Linux switch, app or CLI, prints yellow `Error creating textual authentication agent … /dev/tty` and `nice-dns-helper could not run '<verb>' (exit 127); running it through sudo` lines that read like failures.
- M3 (carried): the sha256-mismatch half of Stage 3 Outcome 3 was not caused. It needs a tampered asset at the real release URL.
- M4 (coverage, not a defect): on macOS the question dialog, the revert on Not now or on failure, and the disabled selectors during an action were not seen. The mac app has no probe hook and no click route here. Those Outcomes hold on Linux by clicks.

Minor:
- m1: from a shell with no user bus (plain ssh on mint), `nice-dns-health stop` / `start` print `Failed to connect to bus: No medium found`, then `Timers stopped.` / `Timers started.` with exit 0, though nothing changed.
- m2: a usage error prints the reason line, then the whole 40-line help. The Outcome says "a usage line".
- m3: in the Linux app, "Check for an update" that finds a different commit opens "Install the update?" at once. Not now dismisses it. I could not compare with the pre-plan app. The scheduled check does not open it.
- m4: "Run a health check now" during the post-switch warm-up shows only `failed (exit 1)` in the log pane, with no reason (the controller verdict was FAIL). This predates the plan.
- m5: the failure toast covers the last lines of the log pane (`mint-x-16`).
- m6: the mac's pull failure says only `Error: POSIXErrorCode(rawValue: 61): Connection refused`, without naming the image. mint names the image and the registry.
- m7 (carried): after a switch, Containers keeps the old proxy name until the next controller pass. The mac glyph was red for a moment after the hardened switch (`mac-M2-after-hardened.png`).
- m8: a calendar check that lands during a switch records `unknown` (12:00 on mint, DNS down mid-switch). This follows the contract, and the next slot retries, but the Update row can then read "unknown" for up to 12 h unless someone checks by hand.
- m9: `--probe` on a disabled selector reports `pihole=none` after its own click. This is hook-only.
- m10: a window opened before an update keeps running the old binary. mint has had a `nice-dns-gui` on its real display since 2026-11-10 20:36, before v1.4.0. Reopening it gets v1.4.0.
- m11 (carried): the Linux GUI reports 0.2.0, the mac app 1.4.0. The Linux window opens with the selectors below the fold at its default size.

End state, checked 12:20–12:27Z:
- mint:
  - Generation 20261111T122007Z-f1cbc1b37037, `variant socat`, `pihole standard`, controller OK, schedule loaded.
  - The update timer's next run is Thu 00:21:54. `update auto loaded`, result available.
  - Containers: tor-socat, unbound and pi-hole, all healthy.
  - `dig @127.0.0.1 cloudflare.com` → 104.16.132.229 / 104.16.133.229.
  - GUI 134fa40e… (v1.4.0 bytes; `--version` 0.2.0) and helper e905d418… = lock.
  - /etc/hosts has no added lines and no backup is left. The kept source is in place. No polkit rule was added.
  - My Xvfb and test window are stopped. The owner's pre-existing window (pid 94772) was left alone.
- mac:
  - Generation 20261111T115431Z-f1cbc1b37037, `variant socat`, `pihole standard`, controller OK, `auto loaded`.
  - `container ls`: tor-socat, pi-hole and unbound running at .252/.250/.251.
  - `dig @172.31.240.250 cloudflare.com` answers.
  - App v1.4.0 (19f82cd9…) and helper a5c8a61d… = lock.
  - /etc/hosts has no added lines and no backup. The app instance I launched is quit.
- Background work: all finished, every one waited on by its own pid or task notification. None running.
