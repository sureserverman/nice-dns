# Close-out demo: Project Plan: macOS GUI (Sub-plan 7)

## Environment

Run 2026-11-10 15:14–15:34 UTC by the close-out evaluator, who did not build this plan and did not read its source or diff. Laptop repo at HEAD 6e01a7c (branch gui-mac, clean). The Mac was reached only by `ssh mac` (macOS 27.2 build 26B123, Apple silicon). GUI work ran in the owner's gui domain through `sudo -n launchctl asuser $(id -u) sudo -n -u $(whoami) env HOME=… PATH=… <cmd>`. Starting state: stack installed (socat, Pi-hole standard, generation 20261110T145506Z-2fb4573cfde9), `~/Applications/nice-dns.app` v1.2.1 present, app **not** running, controller fresh, bridges on, DNS answering.

What I could not do, and why:
- **The menu bar was not seen.** The known limit still holds over ssh. `screencapture -x` returned `could not create image from display`. `osascript … System Events … menu bar 2 of process "NiceDNSGUI"` returned `osascript is not allowed assistive access. (-1719)`. I did not change TCC settings. So the menu-bar glyph, its colour and its menu could not be seen or clicked.
- **Window evidence comes from the app's hooks.** The window was captured with the `--screenshot <png>` hook. Actions ran through the `--run-action <id> --exit` hook, and install state was read with the `--check` hook. These hooks are named as hooks wherever they are used below. No hook shows the window's Output pane after an action. `--run-action` and `--screenshot` cannot be combined (usage error, exit 2).
- **No live harness run.** Following the rules, I did not run `tests/run.sh` live groups. S2-3 was judged from `tests/live/gui-mac.sh --dry-run` and the newest receipt.

PNGs were fetched to the laptop scratchpad, not the repo: `/tmp/claude-1000/-home-user-dev-containers-nice-dns/bfd03c9a-e1c6-4b54-969f-6feb8f1d9cf3/scratchpad/png/` (`nd-s1-1.png`, `nd-s1-3.png`, `nd-s1-5.png`, `nd-s1-2.png`, `nd-s2-1.png`). Each one was opened and read.

## Outcome S1-1

> Works: a menu-bar glyph (green, amber or red from the observations), a menu with the actions and Open window; the window shows the same sections as the Linux app and a log pane.

Verdict: **menu-bar glyph and menu: cannot reach by the user's route. Window: holds (seen through the `--screenshot` hook). Actions run (through the `--run-action` hook).**

Evidence:
- The user's launch works: `open ~/Applications/nice-dns.app` returned rc 0. `ps` then showed `68938 /Users/user/Applications/nice-dns.app/Contents/MacOS/NiceDNSGUI`, and it stayed running. `Info.plist` has `LSUIElement => true`, so it runs as a menu-bar app.
- Quit works: `osascript -e 'tell application id "org.nice-dns.gui" to quit'` returned rc 0, and the process was gone 2 s later.
- The menu bar could not be seen (see Environment). The menu's action list was read from the table bundled inside the installed app, `Contents/Resources/NiceDNS_NiceDNSKit.bundle/actions.tsv`. It has 14 rows: install, reinstall, restart, uninstall, update-check, update, bridges-on/off, health-start/stop/run, open-admin, show-password-path, failures.
- `--version` hook: `nice-dns-gui 1.2.1`. `--check` hook: `installed: generation 20261110T145506Z-2fb4573cfde9; controller OK, fresh`, rc 0.
- `--screenshot` hook (`nd-s1-1.png`): a green dot, `nice-dns  socat, Pi-hole standard, branch main`, and the generation. Then the sections Containers (3 rows healthy), Observations (11 rows healthy), Bridges (switch, `Bridges known 7`, `Last refresh never`), Controller (Verdict OK, Last pass, Freshness fresh, Schedule loaded, Route cloudflare-onion, Helper installed (0.1.1)) and Recent actions (header only; cut off at the capture edge). Below them is an Output pane reading `The output of an action shows here.`
- Red was seen too. Right after the final reinstall, `nd-s2-1.png` showed a red dot, `unbound  route: probe-route exit 1: Killed  unhealthy`, and `Verdict FAIL [unbound]`. Amber is shown under S1-3. The colour therefore follows the observations, at least in the window header.
- Parity with the Linux window (`docs/images/gui-linux.png`): both have Containers, Bridges (switch, count, last refresh), a health controller block, recent actions, an update banner and an output pane. The Mac window also lists Observations. Its Controller block has no `Mode` row, which Linux has. Linux calls the block "Health controller" and Mac calls it "Controller". These are naming and row differences, not missing sections.
- Actions run through the `--run-action <id> --exit` hook, each followed by `dig @172.31.240.250 cloudflare.com`:
  - `update-check`: `$ …/nice-dns update --check` / `available 93ab745a6419` / `a different version is available (exit 10)`, rc 10.
  - `failures`: `No failure dumps in …/nice-dns-health` / `finished (exit 0)`.
  - `health-stop`: `LaunchAgent unloaded.` / `finished (exit 0)`. `health-start`: `LaunchAgent loaded.` (exit 0). `health-run`: `finished (exit 0)`.
  - `restart`: `nice-dns restarted; DNS is answering.` / `finished (exit 0)`. DNS answered.
  - `bridges-off`: `Bridges are off; the proxy restarted and DNS is answering.` (exit 0). DNS answered.
  - `bridges-on`: `Bridges are on; the proxy restarted and DNS is answering.` (exit 0). DNS answered.
  - `bridges-on` while bridges were already on: `Bridges are already on; nothing restarted.` (exit 0).
  - An unknown id gave `nice-dns-gui: 'bogus' is not an action that runs a command`, rc 2. `show-password-path` gives the same reply; it does not run a command, so this is expected.
- Also tried, quitting twice while an action runs:
  - The user's route is to click Quit in the running app's menu. The menu cannot be clicked over ssh, and no action can be started inside the running app without it. **Cannot reach by the user's route.**
  - Partial try A: two Apple-event quits (`osascript … to quit`, 0.5 s apart) sent while the `--run-action health-run --exit` hook ran. The hook ignored both and finished normally (`finished (exit 0)`, rc 0). The hook process does not take the app's quit path.
  - Partial try B: SIGTERM sent to the hook process 1.5 s into `health-run`. The hook died at once (rc 143) and printed nothing: no "stopped", no "cut off". Its child `bash …/nice-dns-health run` (pid 5606) kept running as an orphan and finished on its own a few seconds later.
  - So with a signal the command is neither cut off nor reported. Whether the app's real Quit path does better was not observable.

## Outcome S1-2

> Not installed → the glyph is grey and the window says so with the README curl line.

Verdict: **window: holds (seen through the `--screenshot` hook, in a state I had to construct). Grey glyph: cannot reach by the user's route.**

Evidence:
- `nice-dns uninstall` (the user's route, gui domain) printed `Uninstalled.` / `restored the DNS servers recorded before nice-dns` / `nice-dns uninstalled.`, exit 0.
- That uninstall removes `~/Applications/nice-dns.app` and `~/.local/bin/nice-dns*` too. So after a real uninstall the app is gone. A kept copy of the app (made with `ditto` before uninstalling) showed the S1-5 page instead: `--check` printed `nice-dns command not found: looked for /Users/user/.local/bin/nice-dns`, rc 1.
- To reach this outcome's state (command present, stack absent), I put the HEAD copy's `nice-dns` at `~/.local/bin/nice-dns` and ran the kept app. `~/nd-close/nice-dns status --tsv` reported `install installed no` plus the curl hint.
  - `--check` hook: `not installed; install with: curl -fsSL https://raw.githubusercontent.com/sureserverman/nice-dns/main/install-mac.sh -o install-mac.sh && bash install-mac.sh`, rc 1.
  - `--screenshot` hook (`nd-s1-2.png`): a grey dashed-circle icon, `nice-dns is not installed on this Mac`, `Install it from a terminal with the line in the README:`, then the README curl line in a code box (README line 85, character for character). The Output pane sits below.
  - In that state, `--run-action restart --exit` gave `$ …/nice-dns restart` / `nice-dns: nice-dns is not installed; run \`nice-dns install\`` / `failed (exit 1)`, rc 1.
- The temporary command was removed before the reinstall.

## Outcome S1-3

> The controller is stale → amber glyph, `stale <seconds>` in the window.

Verdict: **window: holds (seen through the `--screenshot` hook). Amber menu-bar glyph: cannot reach by the user's route.**

Evidence:
- I stopped the controller with the app's own action (`--run-action health-stop --exit` hook): `LaunchAgent unloaded.` (exit 0).
- I polled `nice-dns status --tsv` every 15 s. The controller stayed `stale no` until 15:20:24, then reported `controller stale 315` (last pass 15:15:09).
- `--check` hook: `installed: generation 20261110T145506Z-2fb4573cfde9; controller OK, stale 324s`, rc 0.
- `--screenshot` hook (`nd-s1-3.png`):
  - The header has an amber dot and `stale 324s` in amber at the top right. The Controller block reads `Freshness stale 324s`.
  - Every observation is drawn dimmed, as old data. An update banner shows (`A different version is available: 93ab745a6419`, `Install it…`), left from my earlier update-check.
  - **But the Controller block still read `Schedule loaded`.** Meanwhile `launchctl print gui/501/org.nice-dns.health` returned `Could not find service "org.nice-dns.health" in domain for user gui: 501` (finding M1).
- Restore: `health-start` (hook) printed `LaunchAgent loaded.`, then `health-run` (hook) ran. `--check` then read `controller OK, fresh`.

## Outcome S1-4

> An action fails → output and exit stay in the pane.

Verdict: **cannot reach by the user's route.** The pane after an action cannot be observed. The hook evidence below is consistent with the outcome.

Evidence:
- A failing action could only be started through the `--run-action` hook, because the menu cannot be clicked. No hook shows the Output pane after an action, so I could not observe "stays in the pane".
- What the hook prints, in the pane's format:
  - `update-check`: `$ /Users/user/.local/bin/nice-dns update --check` / `available 93ab745a6419` / `a different version is available (exit 10)`, hook rc 10.
  - `restart` with the stack not installed: `$ …/nice-dns restart` / `nice-dns: nice-dns is not installed; run \`nice-dns install\`` / `failed (exit 1)`, rc 1.
  - `failures` with nice-dns-health absent: `Show recent failures` / `could not run: nice-dns-health is not installed: looked for /Users/user/.local/bin/nice-dns-health`, rc 1.
  - In every case the command's output and its exit reach the caller, and the exit code is propagated.

## Outcome S1-5

> `~/.local/bin/nice-dns` is missing → one error page naming the path; `--check` exits 1.

Verdict: **holds.** The window was seen through the `--screenshot` hook; `--check` is itself named in the outcome.

Evidence (with `~/.local/bin/nice-dns` moved aside, then restored by a trap):
- `--check`: `nice-dns command not found: looked for /Users/user/.local/bin/nice-dns`, **exit 1**.
- `--screenshot` hook (`nd-s1-5.png`): one page with a red warning triangle, `nice-dns is not installed where the app looks`, and `nice-dns command not found: looked for /Users/user/.local/bin/nice-dns`. No sections are drawn. The Output pane sits below.
- `--run-action restart --exit`: `could not run: nice-dns is not installed: looked for /Users/user/.local/bin/nice-dns`, exit 1.
- `open ~/Applications/nice-dns.app` in this state: the app started (pid 7867) and did not crash. Apple-event quit then ended it.
- Restore: `RESTORED nice-dns`. `ls -la ~/.local/bin/nice-dns` showed it back (29427 bytes).

## Outcome S2-1

> Works: after `nice-dns install` on macOS, `~/Applications/nice-dns.app` exists without quarantine and launches; uninstall removes it.

Verdict: **holds.**

Evidence:
- Uninstall (`nice-dns uninstall` in the gui domain): exit 0. Afterwards `ls ~/Applications` had no nice-dns.app, and `~/.local/bin` had no `nice-dns*`. `~/Library/LaunchAgents` had no nice-dns agents. `scutil --dns` showed `192.168.0.1` again, and `dig cloudflare.com` still answered.
- Install (`./nice-dns install socat` from a checkout of HEAD, gui domain): exit 0. The output had `▸ Fetching nice-dns-gui (macos/arm64)`, then `▸ Generation 20261110T152829Z-6e01a7c3e760 is active`, then `All done. DNS is set to 172.31.240.250 (pi-hole).`, then `The nice-dns menu-bar app: open /Users/user/Applications/nice-dns.app`.
- After the install:
  - `~/Applications/nice-dns.app` was present. `xattr -lr` printed nothing (no quarantine). `codesign -v` passed (ad-hoc signature). The version was `1.2.1`.
  - The `NiceDNSGUI` sha256 was `e9f5b9e1…ab8db7`, the same as `gui_program_sha256` in the gui-mac receipt.
  - `open ~/Applications/nice-dns.app` left pid 23709 running. `--check` hook: `installed: generation 20261110T152829Z-6e01a7c3e760; …`. Apple-event quit ended the app.

## Outcome S2-2

> The download fails or the sha256 differs → the install continues and says `GUI not installed`.

Verdict: **holds for the sha256 case.** The download-failure case was not caused: there was one install budget for faults.

Evidence:
- I changed the gui/macos/arm64 sha256 in `~/nd-close/release/assets.lock` (the Mac copy only) to 64 zeros. Then I ran `./nice-dns install socat` (gui domain).
- Exit 0. The stack came up: generation `20261110T152604Z-nogit0000000` active, `All done. DNS is set to 172.31.240.250 (pi-hole).`, and `dig` answered.
- The warning was printed twice, at line 7 and again just before the last line: `! The nice-dns-gui download's sha256 is not the one release/assets.lock pins; it was not installed: GUI not installed; reinstall with network to add it.`
- `ls ~/Applications` had no nice-dns.app. The helper was installed normally.
- Restore: the lock was copied back from `/tmp/nd-assets.lock.orig` (the gui line shows `0e471b47…77166` again). The S2-1 install followed.

## Outcome S2-3

> A target is unreachable → that check is `[~]` with the reason.

Verdict: **cannot reach by the user's route.** I was not allowed to run `tests/run.sh live gui-mac`, and only a live run with an unreachable target produces this output. I do not consider this blocking for the plan goal: it concerns test-harness output, not what the owner gets from the app.

Evidence:
- `bash tests/live/gui-mac.sh --dry-run` (rc 0) listed gm_before … gm_receipt with what each proves, then `dry run: the operations, modes, group, manifest and the pinned asset are in place`. It shows no unreachable-target behaviour.
- `bash tests/run.sh receipt gui-mac` gave `receipt=gui-mac cells=1 scenarios=7 errors=0 limits=1 reused=0`, rc 0.
- The receipt `…/receipts/gui-mac/20261110T144912Z-e270d97a/receipt.tsv` has 7 scenarios at `pass` and one row `limit no-person-clicked … the menu bar was not seen (no Screen Recording or Accessibility grant over ssh); the opened app was quit by SIGTERM`. So a limit does get a row with its reason.
- No receipt or output I could produce shows an unreachable target. The `[~]` mark is not something the product or harness prints in anything I saw.

## Findings

Blocking:
- None.
- The menu-bar glyph and menu (part of S1-1, S1-2 and S1-3), the Output pane after an action (S1-4) and quit-twice could not be reached by the user's route over ssh. I do not grade this blocking. The app launches via `open` and stays up as an `LSUIElement` app. The window behind Open window shows every state, with the right header colour (green, amber, red, grey). Every action runs and reports its output and exit through the app's own runner.
- Still, no one has yet looked at the shield in the menu bar or clicked its menu. One look by the owner at the Mac would close this.

Material:
- **M1. "Schedule loaded" is shown while the controller's LaunchAgent is not loaded.**
  - After `nice-dns-health stop` (run as the app's own `health-stop` action), `nice-dns status --tsv` kept reporting `controller schedule loaded` and `controller mode active`. The window shows the same (`Schedule loaded` in `nd-s1-3.png`).
  - Meanwhile `launchctl print gui/501/org.nice-dns.health` said `Could not find service`, and `launchctl list` (gui domain) did not list it.
  - The owner is told the schedule is running when it is not. Only `stale <seconds>` gives it away, and only after ~5 minutes.
  - The fault is in the status contract the GUI renders, not in the Swift app.

Minor:
- m1. The sha256-mismatch message ends `reinstall with network to add it`. The network was fine; the bytes did not match the pin. That remedy is wrong for this cause.
- m2. After a real `nice-dns uninstall`, a kept copy of the app shows the "not installed where the app looks / looked for …/nice-dns" page, not the S1-2 page with the README curl line. The S1-2 page appears only when the command is present but the stack is not. The S1-5 page offers no way to install.
- m3. Quitting with SIGTERM during an action leaves the command running orphaned and prints nothing about it (rc 143, child pid 5606 finished alone). The real Quit path was not observable.
- m4. `nice-dns-health stop` when already stopped prints `Unload failed: 5: Input/output error` and then `LaunchAgent unloaded.` with exit 0. The two lines contradict each other in the pane. This is the controller CLI's output, not the GUI's.
- m5. In the hook screenshots, the Bridges switch has a grey track with the knob on the right while bridges are on. Linux shows it blue. On-or-off reads ambiguously, though this is likely the inactive-window rendering.
- m6. The `--screenshot` hook captures only the top of the scroll view. Recent actions is cut off, so I could not check its rows or anything below it.
- m7. `--check` exits 0 while the controller verdict is `FAIL [unbound]` (`…; controller FAIL [unbound], fresh`). This is presumably by design (`--check` reports install state), but the line can be misread as a health check.
- m8. Informational, about the stack rather than the GUI. Right after a fresh install, the first two controller passes reported `FAIL [unbound]` (`route: probe-route exit 1: Killed`), so the header turned red. The next pass, about 1 minute later at 15:33:35, was OK.
- m9. Informational. The app is ad-hoc signed and `spctl -a` rejects it. It launches only because the installer strips quarantine, as designed. A hand-downloaded copy would be blocked by Gatekeeper.

## Mac state at the end

Proved at 15:33:42 UTC:
- `nice-dns status --tsv`:
  - `install installed yes`, `generation 20261110T152829Z-6e01a7c3e760`, `source_commit 6e01a7c3e760e8931874d5b59d2d7ac9f6983b51` (= HEAD), `branch main`, `variant socat`, `pihole standard`.
  - `controller verdict OK`, `controller stale no`, `controller schedule loaded`, `bridges mode on`.
- `~/.config/nice-dns/bridges-mode.env` reads `TOR_BRIDGES=on`.
- `dig +short @172.31.240.250 cloudflare.com` returned `104.16.133.229` and `104.16.132.229`.
- `~/.local/bin/nice-dns` and `~/.local/bin/nice-dns-health` are present. `~/Applications/nice-dns.app` is present (v1.2.1, no quarantine, binary sha256 matches the receipt).
- `pgrep -fl NiceDNSGUI` gives `app not running`, as at the start. `launchctl list` shows org.nice-dns.health, org.nice-dns.start-container and org.nice-dns.health-bridges.

Differences from the starting state:
- The installed generation is now from HEAD 6e01a7c, not from 2fb4573. The two commits have the same product files.
- The final install ran from a git clone of HEAD (branch set to `main`), so the record keeps a source commit. The archive copy recorded `source_commit unknown` / `nogit`.
- The temporary dirs `~/nd-close-keep` and `~/nd-close-git` were removed. `~/nd-close` (the HEAD archive, with its lock restored) is left in place.
- `/tmp/nd-*` files from the demo remain on the Mac.

No restore failed. Laptop repo: no file changed except this one. No commit was made. All background jobs (stale poll, two installs, their waiters) ended on their own completion.
