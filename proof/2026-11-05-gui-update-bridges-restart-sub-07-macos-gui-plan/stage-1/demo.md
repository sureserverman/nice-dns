# Stage 1 demo — 2026-11-05-gui-update-bridges-restart-sub-07-macos-gui-plan

Environment: target `mac` (macOS 27.2 build 26B123, Apple silicon, owner's logged-in session), reached only by `ssh mac`.
Stack installed and running there (socat, standard Pi-hole, generation 20261109T180318Z-nogit0000000).
App built as it ships in this stage, from the repo root on the laptop (branch gui-mac, HEAD e126a19):
`rsync -a --delete gui/ mac:~/nice-dns-gui-check/gui/ && rsync -a docs/images/ mac:~/nice-dns-gui-check/docs/images/ && ssh mac 'cd ~/nice-dns-gui-check/gui/mac && make'`
gives `build/nice-dns.app` (`Identifier=org.nice-dns.gui`, `Signature=adhoc`, `LSUIElement` true, `nice-dns-gui 0.0.0`).
Every GUI command ran in the owner's graphical session through `sudo -n launchctl asuser $(id -u) sudo -n -u $(whoami) env HOME="$HOME" <cmd>` (DEC-024).
Demo run 2026-11-10, 11:45–11:57 GMT.

What these tools cannot do, and why:
- See the menu bar. `screencapture -x -R0,0,1920,30` in the owner's session gives `could not create image from rect` (rc 1). ssh has no Screen Recording permission, and TCC was not changed.
- Click the menu bar or read its items. `osascript ... menu bar 2 of process "NiceDNSGUI"` gives `osascript is not allowed assistive access. (-1719)`. ssh has no Accessibility permission, and it was not granted.
- Find the status item another way. The CoreGraphics window list (`CGWindowListCopyWindowInfo`, run in the owner's session) shows no windows owned by the NiceDNSGUI pid. On this macOS no app lists layer-25 status-item windows; only `MenuBarAgent` has one layer-24 window. So this shows nothing either way.
- So the glyph, its colour, the menu and the "Open window" item cannot be seen or clicked here. The window's content was seen only through the app's own `--screenshot <png>` **test hook**. The hook draws the window off screen. Actions ran only through the `--run-action <id> --exit` **test hook**. Both are named wherever they were used.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: a menu-bar glyph (green, amber or red from the observations), a menu with the actions and Open window; the window shows the same sections as the Linux app and a log pane.
Verdict: cannot reach by the user's route. The glyph, the menu and "Open window" need Screen Recording or Accessibility, and this demo may not use either. The window's content was seen only through the `--screenshot` test hook.
Evidence:
- Launched as the owner does: `open ~/nice-dns-gui-check/gui/mac/build/nice-dns.app` in the owner's session gave `open=0`. pid 30207 started with ppid 1. `lsappinfo` shows `"nice-dns" bundleID="org.nice-dns.gui" type="UIElement"`. There was no Dock icon (LSUIElement), which is as intended.
- A second `open` of the running app showed no window in the CG window list. That list cannot see status items or windows here (see above), so this proves nothing either way.
- The app ran for 10 min 04 s through every step below without a crash: `nice-dns` moved aside, the controller stale, a restart, bridges off and on. It quit cleanly on `tell application id "org.nice-dns.gui" to quit`.
- `NiceDNSGUI --check` gave `installed: generation 20261109T180318Z-nogit0000000; controller OK, fresh` with exit 0.
- `NiceDNSGUI --screenshot /tmp/ndeval/o1.png` (test hook) drew these parts:
  - The header: a **green dot**, `nice-dns  socat, Pi-hole standard, branch main` and `generation 20261109T180318Z-nogit0000000`.
  - **Containers**: pi-hole, unbound and tor-socat, each `running: health none restarts 0`, `healthy` in green.
  - **Observations**: runtime, proxy, dns-owner, local-service, filtering, local-cache, the four `route:*` rows and unbound, all `healthy`. These match `nice-dns status --tsv` row for row.
  - **Bridges**: a `Tor bridges` switch (on), `Bridges known 7`, `Last refresh 10/11/2026, 04:17:46`.
  - **Controller**: Verdict OK, Last pass 11:48:06, Freshness fresh, Schedule loaded, Route cloudflare-onion, Helper installed (0.1.1).
  - **Recent actions**: the heading only. The drawing is clipped right below it (see M1).
  - A separate **Output** pane at the bottom: `The output of an action shows here.`
- Against the Linux app (`docs/images/gui-linux.png` and the README's "The window (Linux)"):
  - Present on both: Containers, Bridges, the health controller, Recent actions, and the output pane ("No action run yet" on Linux).
  - The Mac window adds an Observations section.
  - No "Update" section was visible in the drawn area (see M1).
- Actions, run through the `--run-action <id> --exit` test hook rather than the menu. Each printed the command, its output and an exit line:
  - `health-stop`: `$ /Users/user/.local/bin/nice-dns-health stop` / `LaunchAgent unloaded.` / `finished (exit 0)`
  - `health-start`: `LaunchAgent loaded.` / `finished (exit 0)`
  - `health-run`: `finished (exit 0)`
  - `failures`: `No failure dumps in /Users/user/Library/Logs/nice-dns-health` / `finished (exit 0)`
  - `restart`, 11:55:22 to 11:55:38: `nice-dns restarted; DNS is answering.` / `finished (exit 0)`. dig returned 104.16.132.229 and 104.16.133.229.
  - `bridges-off`, 11:55:38 to 11:56:02: `Bridges are off; the proxy restarted and DNS is answering.` / `finished (exit 0)`. dig answered.
  - `bridges-on`, 11:56:02 to 11:56:17: `Bridges are on; the proxy restarted and DNS is answering.` / `finished (exit 0)`. dig answered. `nice-dns bridges status` then gave `mode on`, `count 7`.
  - `update-check`: see Outcome 4.
  - Not run, because the environment forbids them: install, reinstall, uninstall and update. open-admin was not run either.


## Outcome 2
> Not installed → the glyph is grey and the window says so with the README curl line.
Verdict: cannot reach by the user's route. The only route to "not installed" is uninstalling the stack, and the environment forbids uninstall and reinstall on `mac`. Even with the stack missing, the glyph could not be seen (no Screen Recording or Accessibility). This is a scope limit of this demo. Stage 2's live run installs and uninstalls.
Evidence:
- Nothing was run for this Outcome. The stack stayed installed throughout: `install installed yes` in `nice-dns status --tsv`.


## Outcome 3
> The controller is stale → amber glyph, `stale <seconds>` in the window.
Verdict: cannot reach by the user's route (the glyph). The menu-bar glyph could not be seen. The window part was seen through the `--screenshot` test hook, and it showed an amber dot and `stale 353s`.
Evidence:
- Caused the failure:
  - 11:49:19: `--run-action health-stop --exit` (test hook) gave `LaunchAgent unloaded.` / `finished (exit 0)`.
  - `launchctl print gui/501` no longer listed a running `org.nice-dns.health`.
  - Waited 300 s with `ssh mac 'sleep 300; nice-dns status'`. This was a background job, waited on until it finished.
- `nice-dns status` then showed `last_pass 1794311344`, `stale 345` and `schedule loaded` (now=1794311689).
- `NiceDNSGUI --check` at 1794311696 gave `installed: generation 20261109T180318Z-nogit0000000; controller OK, stale 352s` with exit 0.
- `NiceDNSGUI --screenshot /tmp/ndeval/o3.png` (test hook) showed:
  - The header dot was **amber/orange**, where it had been green in Outcome 1.
  - Top right, in orange: `stale 353s`.
  - Controller: `Freshness stale 353s`, `Last pass 10/11/2026, 11:49:04`.
  - All status rows were dimmed grey: "healthy" in grey, the bridges switch greyed.
- Restored:
  - `--run-action health-start --exit` gave `LaunchAgent loaded.` / `finished (exit 0)`.
  - `health-run` gave `finished (exit 0)`.
  - `nice-dns status --tsv` then gave `stale no`, `last_pass 1794311712`.


## Outcome 4
> An action fails → output and exit stay in the pane.
Verdict: cannot reach by the user's route. Running an action means clicking the menu, which needs Accessibility, and the pane could not be seen after an action. The test hook shows the right output and exit text for a failing action. It cannot show that the text *stays* in the pane: `--run-action ... --exit` quits right after, and `--run-action` cannot be combined with `--screenshot` (`rc=2`, usage line).
Evidence:
- A naturally failing allowed action: `~/.local/bin/nice-dns update --check` gives `unknown: the installed source was not a clean commit` with rc 1. The cause is the generation `-nogit0000000`.
- `NiceDNSGUI --run-action update-check --exit` (test hook) printed the following and exited 1:
  ```
  $ /Users/user/.local/bin/nice-dns update --check
  unknown: the installed source was not a clean commit
  unknown (exit 1)
  ```
- `NiceDNSGUI --run-action update-check --screenshot /tmp/ndeval/o4.png` gave rc 2 and `usage: NiceDNSGUI [--check | --version | --screenshot <png> | --run-action <id> --exit]`.
- With `nice-dns` moved aside (Outcome 5), `--run-action restart --exit` printed the following and exited 1:
  `Restart the stack` / `nice-dns is not installed: looked for /Users/user/.local/bin/nice-dns` / `could not run: nice-dns is not installed: looked for /Users/user/.local/bin/nice-dns`


## Outcome 5
> `~/.local/bin/nice-dns` is missing → one error page naming the path; `--check` exits 1.
Verdict: holds for `--check`, run as a user runs it from a shell. For the error page in the window: cannot reach by the user's route. The page was seen only through the `--screenshot` test hook, because the window cannot be opened from the menu here.
Evidence:
- `mv ~/.local/bin/nice-dns ~/.local/bin/nice-dns.evalaside`
- `NiceDNSGUI --check` gave `nice-dns command not found: looked for /Users/user/.local/bin/nice-dns` with exit **1**.
- `NiceDNSGUI --screenshot /tmp/ndeval/o5.png` (test hook) drew one page. It has a red warning triangle and `nice-dns is not installed where the app looks`, then `nice-dns command not found: looked for /Users/user/.local/bin/nice-dns`. There are no status sections. Only the Output pane remains below: `The output of an action shows here.`
- An action tried meanwhile, `--run-action restart --exit`, failed cleanly with exit 1 and named the path (see Outcome 4).
- The running app (pid 30207) survived the missing file. It was still running afterwards.
- Restored with `mv ~/.local/bin/nice-dns.evalaside ~/.local/bin/nice-dns`. `NiceDNSGUI --check` then gave `installed: generation ...; controller OK, fresh` with exit 0.


## Findings

No Blocking product defect was seen. Outcome 2 and the menu-bar parts of Outcomes 1, 3, 4 and 5 are "cannot reach by the user's route". The reason is the demo's own limits: no Screen Recording, no Accessibility, no uninstall on `mac`. Per the environment rules this is a scope limit, not an app defect. Stage 2's live run must cover the glyph colours, the menu, "Open window", the pane keeping failed output, and the not-installed page with the curl line.

- **M1 (Minor, unverified):** The `--screenshot` hook draws a fixed-height window, and the content is cut off right below the "Recent actions" heading. `nice-dns status --tsv` had five `recent` rows, and none were drawn. It is not known whether they are below the cut or missing. An Update section (the Linux README lists "whether an update is waiting") was not visible either. Check both in Stage 2's live window.
- **M2 (Minor, the CLI's data shown by the app):**
  - After `nice-dns-health stop` printed `LaunchAgent unloaded.`, `nice-dns status` still reported `schedule loaded`.
  - `launchctl print gui/501` showed no running `org.nice-dns.health`.
  - The window passes this on as `Schedule loaded` while the controller is stopped.
  - The stale indicator still caught the stop after 300 s.
- **M3 (Minor, hook only):** `--run-action show-password-path --exit` prints `nice-dns-gui: 'show-password-path' is not an action that runs a command`. That action is in `gui/share/actions.tsv`. It is a test-hook limit, not the user's route.

Overall: PASS with residuals. Most of what the Outcomes ask could not be reached by the user's route in this environment. What the test hooks show matches the Outcomes.

## End state (11:56:31 GMT)

- `~/.local/bin/nice-dns` is back in place (29427 bytes, as before).
- `nice-dns status --tsv`: `controller verdict OK`, `stale no`, `last_pass 1794311781`, `schedule loaded`, `bridges mode on`.
- `dig +short @172.31.240.250 cloudflare.com` returned 104.16.132.229 and 104.16.133.229.
- `pgrep -fl NiceDNSGUI` found no NiceDNSGUI process.
- The evaluator's helper files (`/tmp/ndeval` on mac) were removed. The build tree `~/nice-dns-gui-check` is left as the build step made it.
- All background jobs (the 300 s wait and its sentinel waits) finished on their own.

## Owner decision (2026-11-10)

The owner chose option 3 on the gate's ACTION NEEDED block ("3"): accept
the screenshot-hook evidence for Stage 1, record the menu-bar Outcomes as
not demonstrated, and go on to Stage 2.

Not demonstrated by the user's route:
- Outcome 1: the menu-bar glyph and its colours, the menu, and Open window.
- Outcome 2: the grey glyph and the not-installed page (no uninstall was
  allowed on mac).
- Outcome 3: the amber glyph.
- Outcome 4: a failed action's output staying in the pane.
- Outcome 5: the window's error page, opened from the menu.

The verdicts above are left as the evaluator wrote them. Nothing in this
record claims these Outcomes hold.
