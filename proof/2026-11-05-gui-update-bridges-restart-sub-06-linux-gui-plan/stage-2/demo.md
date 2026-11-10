# Stage 2 demo — 2026-11-05-gui-update-bridges-restart-sub-06-linux-gui-plan

Environment: close-out re-demo, 2026-11-10 06:53–07:50 UTC, after the fix to
B1/B2. Target: mint (Linux Mint 22.3, Cinnamon on X11, DISPLAY=:0, 1440x900,
Intel GM965/GL960, GTK 4.14 / libadwaita 1.5, glibc 2.39), reached only by
`ssh mint`. Branch gui-linux at HEAD 772e0ed, put on mint by the real
`nice-dns install` through
`tests/live/target.sh command mint --mode install-git --cell socat/standard --source-sha 772e0ed…`
(after a `target.sh snapshot mint`, which the command requires).

Two GUI binaries were used; both print `nice-dns-gui 0.1.0`, so they are told
apart by sha256 only:
- RELEASE = the v1.1.0 asset the installer fetches (release/assets.lock),
  sha256 `50eb5a55…cbbebe53`. Used for Stage 2 Outcomes 1-3.
- HEAD = HEAD's own `gui/linux` build, sha256 `0db7ffe1…48f06c550`. Used for
  every window observation (S1-*, B1, B2, DEC-023 wording). Deviation from the
  brief: mint has no cargo/rustc and no GTK dev packages (`dpkg -l` shows none;
  `pkg-config gtk4` not found), so it could not be built there. It was built on
  the laptop from `git archive HEAD gui` in the scratchpad
  (`cargo build --release`, exit 0), not run on the laptop, and copied to mint.
  The laptop and mint share glibc 2.39 and GTK 4.14.5 / libadwaita 1.5.0; the
  binary needs at most GLIBC_2.39 (`objdump -T`). It was copied over
  `~/.local/bin/nice-dns-gui` after each install that put RELEASE there.

The window was driven as a person would: the Cinnamon applications menu
(Super, type, Return), mouse clicks and the wheel through xdotool inside the
user's session (`systemd-run --user … -E DISPLAY=:0`). Screens were captured
with a PIL grab of :0 (not the `--screenshot` hook) and every PNG was looked
at. GSK_RENDERER was never set (`/proc/<pid>/environ` of the menu-launched GUI
has only DISPLAY among GSK/GDK/DISPLAY vars). PNGs, logs and strace files are in
/tmp/claude-1000/-home-user-dev-containers-nice-dns/f4c531d7-439e-4230-8ed0-d483590de17e/scratchpad/eval2/
(named below without that folder). The screen lock was lifted with
`cinnamon-screensaver-command -d`; the session idle-delay was set to 0 during
the demo and reset to its default (900) at the end.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: after `nice-dns install` on Linux, `nice-dns-gui` is on the user's PATH, the launcher shows nice-dns, the app opens on the status page; uninstall removes all of it.
Verdict: holds
Evidence:
```
$ target.sh command mint --mode install-git --cell socat/standard --source-sha 772e0ed…   (install1.log)
▸ Preparing generation 20261110T065624Z-772e0ed629f4 (source checkout, commit 772e0ed6…; previous 20261109T232843Z-143ef9e75c2f, rollback available)
▸ Fetching nice-dns-gui (linux/amd64)
▸ Generation 20261110T065624Z-772e0ed629f4 is active (previous: 20261109T232843Z-143ef9e75c2f).
The nice-dns window: open nice-dns from the applications menu, or run /home/user/.local/bin/nice-dns-gui
command_exit 0

$ ssh mint 'bash -lc "command -v nice-dns-gui; nice-dns-gui --version"'
/home/user/.local/bin/nice-dns-gui
nice-dns-gui 0.1.0          (sha256 50eb5a55…  = RELEASE)
~/.local/share/applications/nice-dns.desktop: Name=nice-dns, Exec=/home/user/.local/bin/nice-dns-gui,
  Icon=nice-dns (~/.local/share/icons/hicolor/256x256/apps/nice-dns.png), Keywords=DNS;Tor;Pi-hole;privacy;
  desktop-file-validate exit 0. PATH comes from Mint's ~/.profile (adds ~/.local/bin when it exists).
```
- 01-menu-nice-dns.png: Cinnamon menu, search `nice-dns` (with the hyphen):
  no result. 01b-menu-nice.png: search `nice`: one entry, the nice-dns icon,
  "nice-dns / See and manage the nice-dns stac…".
- Return on it -> 02-release-gui-open.png (RELEASE): window "nice-dns",
  subtitle "generation 20261110T065624Z-772e0ed629f4 · socat · standard Pi-hole
  · branch main", Containers (pi-hole/unbound/tor-socat healthy), Bridges
  switch on ("7 bridges, last refresh 6 h ago"), Health controller (Verdict OK,
  Last pass just now, Mode active, Schedule loaded), log pane "No action run
  yet". The status page. The window opened 842x982 at -11,-55 (top and bottom
  off the 900 px screen).
- The same route with HEAD (10-head-open.png, after the HEAD copy) also opens
  on the status page.

Uninstall (the second HEAD install, generation 20261110T073227Z-772e0ed629f4):
```
$ ssh mint '~/.local/bin/nice-dns uninstall'    (o1-uninstall.log)
custom-dns-deb: restored the resolver state from before nice-dns (fresh)
nice-dns uninstalled.   exit=0
after: ~/.local/bin empty; no nice-dns.desktop; no nice-dns icon; no ~/.local/share/nice-dns;
       no /usr/libexec/nice-dns-helper; bash -lc 'command -v nice-dns-gui' -> not found;
       /etc/resolv.conf -> nameserver 127.0.0.53; no containers
```
- 64-menu-after-uninstall.png: menu search `nice` finds nothing.
- Note: `~/.config/nice-dns/` (bridge-pool.tsv, bridges.env, bridges.env.prev,
  bridges-mode.env) stays after uninstall. These are not GUI files.

## Outcome 2
> The asset download fails → the install continues and says `GUI not installed; reinstall with network to add it`.
Verdict: holds
Evidence:
Injection (mint only, undone): appended `0.0.0.0 github.com`,
`0.0.0.0 objects.githubusercontent.com`, `0.0.0.0 release-assets.githubusercontent.com`
to /etc/hosts (backup taken; original sha256 181baad9…f31e615). `curl` to the
release URL then failed: `curl: (7) Failed to connect to github.com port 443`.
Then the user's own command:
```
$ ssh mint '~/.local/bin/nice-dns reinstall --local'    (o2-reinstall-nodownload.log)
▸ Preparing generation 20261110T070047Z-nogit0000000 (source checkout, commit unknown; previous 20261110T065624Z-772e0ed629f4, rollback available)
▸ Fetching nice-dns-gui (linux/amd64)
! The nice-dns-gui download failed (curl exit 7): GUI not installed; reinstall with network to add it.
... (images, quadlets, bridges, controller, DNS pin all proceed)
▸ Generation 20261110T070047Z-nogit0000000 is active (previous: 20261110T065624Z-772e0ed629f4).
! The nice-dns-gui download failed (curl exit 7): GUI not installed; reinstall with network to add it.
exit=0
~/.local/bin/nice-dns-gui before and after: 2026-11-10 06:59:34, sha256 50eb5a55… (unchanged)
```
/etc/hosts was put back (sha256 181baad9…f31e615 again; `grep -c githubusercontent` -> 0)
and DNS answered (`dig +short @127.0.0.1 cloudflare.com` -> 104.16.133.229, 104.16.132.229).
As in the first demo, the earlier GUI stays in place, so "GUI not installed"
is true of this run's fetch only.

## Outcome 3
> The asset's sha256 differs → refused, same message.
Verdict: holds
Evidence:
Injection (mint only, undone): in the kept source
`~/.local/share/nice-dns/source/release/assets.lock` the `gui linux amd64`
row's sha256 `9557135b…60167788` was replaced by 64 zeros (original lock
sha256 722028c6…c908, tampered 30a4c6e6…3c17).
- First try (o3-try1-curl7.log): with /etc/hosts already restored, this run's
  fetch still failed with `curl exit 7` and printed the download-failed
  message. A `curl` from the same shell right after returned 200. Not
  explained; treated as a transient, the run was repeated.
- Second try:
```
$ ssh mint '~/.local/bin/nice-dns reinstall --local'    (o3-reinstall-badsha.log)
▸ Preparing generation 20261110T070816Z-nogit0000000 (...)
▸ Fetching nice-dns-gui (linux/amd64)
! The nice-dns-gui download's sha256 is not the one release/assets.lock pins; it was not installed: GUI not installed; reinstall with network to add it.
...
▸ Generation 20261110T070816Z-nogit0000000 is active (previous: 20261110T070450Z-nogit0000000).
! The nice-dns-gui download's sha256 is not the one release/assets.lock pins; it was not installed: GUI not installed; reinstall with network to add it.
exit=0
~/.local/bin/nice-dns-gui after: 2026-11-10 06:59:34, sha256 50eb5a55… (not replaced)
```
The downloaded bytes were refused and the install finished. The lock was
restored (sha256 722028c6…c908 again). Nit (as before): "reinstall with
network to add it" is the wrong remedy for bad bytes, but it is the message
this Outcome asks for.

## Outcome 4
> A target is unreachable → that check is `[~]` with the reason.
Verdict: cannot reach by the user's route
Evidence:
The route to this branch is a live run of the gui-linux group against a target
that does not answer. This evaluation was told not to start `tests/run.sh`
live groups, so it is the evaluator's limit, not a product defect. The
committed receipt
`docs/evidence/2026-11-05-gui-update-bridges-restart-sub-06-linux-gui-plan/2.3/receipt.tsv`
(run 20261109T205402Z-2c933b54) reached its one target (`cell linux socat
standard mint … observed`), six scenarios `pass`, one `limit
no-person-clicked`, no `[~]` row. The unreachable branch was not exercised.

## Stage 1 Outcomes (re-demo at close-out)

All window observations below use HEAD (sha256 0db7ffe1…), launched from the
Cinnamon menu or as `nice-dns-gui`, GSK_RENDERER unset.

### S1-1
> Works: the window shows installed state, an update banner, a containers table, observations, bridges (a switch), the controller, recent actions; a button per action streams the command's output and shows its exit; the admin page opens in the browser.
Verdict: holds
Evidence:
Shown (10-17, 23): subtitle with generation; Containers table; Bridges switch;
Health controller (Verdict, Last pass, Mode, Schedule, Route) with "Run a
health check now", "Start the health controller", "Stop the health
controller", "Show recent failures"; Installed (Generation, Source commit,
Proxy, Pi-hole, Update, Helper "installed, 0.1.1") with "Check for an update",
"Restart the stack", "Reinstall the stack", red "Uninstall nice-dns"; Pi-hole
admin with "Open the Pi-hole admin page", "Show where the admin password is";
Recent actions (route:cloudflare-exit ready/acknowledged/requested…);
Observations (proxy, dns-owner, install-drift, local-service, filtering,
local-cache, four routes, unbound).

Each button clicked ran its command, streamed output and showed its exit:
- "Check for an update" (18, 19): `$ /home/user/.local/bin/nice-dns update --check`
  / `unknown: the installed source was not a clean commit` / `unknown (exit 1)`
  (a `--local` generation); the Update row turned "unknown (checked just now)".
- "Show where the admin password is" (20): toast "The admin password is in
  /home/user/.local/state/nice-dns/secrets/pihole/pihole_webpassword".
- "Open the Pi-hole admin page" (21, 22): Firefox started with
  `http://localhost:8880/admin`; window "Pi-hole nice-dns — Mozilla Firefox"
  shows the Pi-hole login page at localhost:8880/admin/login.
- Bridges switch (24, 25): log "Turn bridges off", `$ … nice-dns bridges off`,
  "Bridges are off. … Restarting the proxy..." with `running…`, then "Chain is
  resolving … Bridges are off; the proxy restarted and DNS is answering." /
  `finished (exit 0)`; `bridges-mode.env` -> `TOR_BRIDGES=off`; the row
  re-enabled with "Tor runs without bridges: your ISP can see that Tor is in use".
- "Run a health check now" (28): `$ … nice-dns-health run` / `finished (exit 0)`.
- "Show recent failures" (29): `No failure dumps in /home/user/.local/state/nice-dns-health` / exit 0.
- "Stop the health controller" (30): "Timer stopped." exit 0; Schedule row -> "stopped".
- "Start the health controller" (38): "Timer started." exit 0; Schedule "loaded".
- "Restart the stack" (42, 43): ran at once (no question), every button greyed
  while `running…`, then "nice-dns restarted; DNS is answering." /
  `finished (exit 0)`, buttons back.
- Update banner, on the clean HEAD generation 20261110T073227Z-772e0ed629f4
  (53, 54, 60): "Check for an update" -> `available 0f6a6e755fb1` /
  `a different version is available (exit 10)`; a banner "A different version
  is available: 0f6a6e755fb1 [Apply]"; the Update row "available: 0f6a6e755fb1
  (checked just now)"; the window then asks "Install the update? The branch's
  commit 0f6a6e755fb1 is installed like a reinstall, with the recorded
  choices. The stack restarts. [Not now] [Install]". "Apply" on the banner
  (63) opens the same question. "Not now" was chosen each time; nothing was
  installed (`checked_at` and generation unchanged).
strace of the GUI pid (strace-main.txt, strace-2.txt): `nice-dns status --tsv`
every 5 s (07:11:39, :44, :49, :54, :59, 07:12:04, :09, :14 …), and an exec per
click (e.g. `07:38:05 nice-dns-health failures`, `07:38:18 nice-dns update --check`).

### S1-2
> Not installed → a page saying so with the README curl line and an Install button only when the kept source exists.
Verdict: holds
Evidence:
State built after `nice-dns uninstall` (which removes the command, so the user
cannot reach this page right after an uninstall): `nice-dns` from
`git archive HEAD` and the HEAD GUI put in ~/.local/bin, no kept source.
`nice-dns status --tsv` -> `install installed no`, `install hint curl -fsSL …`,
exit 1; `nice-dns-gui --check` -> `not installed; install with: curl -fsSL https://raw.githubusercontent.com/sureserverman/nice-dns/main/install-deb.sh -o install-deb.sh && bash install-deb.sh`, exit 1.
- Launched as `nice-dns-gui` -> 65-s1-2-no-source.png: subtitle "not
  installed", "nice-dns is not installed", "Install it with this line in a
  terminal:", the curl line; no Install button.
- With the window open, the kept source was copied to
  ~/.local/share/nice-dns/source -> 10 s later 66-s1-2-with-source.png shows a
  full-width "Install nice-dns" button (the window followed the change).
- Clicking it (67, 68) ran `nice-dns install`: "Preparing generation
  20261110T074536Z-nogit0000000 …", "Installing nice-dns-helper …", then the
  polkit prompt; Cancel -> "Error executing command as another user: Request
  dismissed" and `authorisation cancelled (exit 1)`.
The copies and the half-made state were replaced by the final install-git.

### S1-3
> The controller is stale → the sections are shown greyed with `stale <seconds>`.
Verdict: holds
Evidence:
With the window open, "Stop the health controller" was clicked (07:17:18).
`nice-dns status --tsv` first printed `controller stale 307` at 07:22:11. At
07:22:20 the same, still-open window (37-s1-3-stale.png) showed the Containers
rows and Health controller rows greyed, each heading with an amber
`stale 311s`; Last pass "5 min ago", Schedule "stopped"; the Bridges row not
greyed. "Start the health controller" then brought it back: 38 shows the rows
in colour, Last pass "just now", no stale label; TSV `stale no`. The open
window followed both changes (in the first demo it did not refresh).

### S1-4
> An action fails → its output and exit code stay in the log pane; the buttons re-enable.
Verdict: holds
Evidence:
- "Check for an update" on a `--local` generation failed (18, 19): log kept
  `unknown: the installed source was not a clean commit` and `unknown (exit 1)`
  in red, header `unknown (exit 1)`; the next clicks ran (20-22).
- "Reinstall the stack" with the polkit prompt cancelled (47, 48): the log kept
  the command, "Preparing generation …", "Error executing command as another
  user: Request dismissed", `nice-dns: authorisation cancelled`, "nice-dns
  install: the DNS ownership check failed (exit 126); nothing was changed.",
  `authorisation cancelled (exit 1)`; 10 s later the text was still there and
  every button was back at full colour (48).

### S1-5
> A polkit prompt is dismissed → the log shows `authorisation cancelled` from the command.
Verdict: holds
Evidence:
"Reinstall the stack" -> dialog "Reinstall nice-dns?" (Proxy socat, Pi-hole
standard, Branch main) -> Reinstall (44, 45). `pgrep` showed
`pkexec /usr/libexec/nice-dns-helper --tree /home/user/.cache/nice-dns/fetch.…/nice-dns dns check`
and Cinnamon's dialog "Authentication Required — Authentication is required
for nice-dns to install, update or remove its DNS setup (pin the system
resolver, install its packages and services)" (46-polkit.png). Cancel ->
47-polkit-cancelled.png: log `nice-dns: authorisation cancelled`, final line
`authorisation cancelled (exit 1)`, header and toast "Reinstall the stack:
authorisation cancelled (exit 1)". Generation unchanged
(20261110T070816Z-nogit0000000) and DNS kept answering. Same result from the
not-installed page's Install button (68).

### S1-6
> `nice-dns` is missing from `~/.local/bin` → one error page naming the path, exit 1 for `--check`.
Verdict: holds
Evidence:
`mv ~/.local/bin/nice-dns /tmp/eval2/nice-dns.saved` with the window open ->
8 s later 49-s1-6-open-window.png: subtitle "error", one page "nice-dns cannot
be read" / "The nice-dns command is not installed: looked for
/home/user/.local/bin/nice-dns". `nice-dns-gui --check` -> `nice-dns command
not found: looked for /home/user/.local/bin/nice-dns`, exit 1. Closed with the
title-bar X (process exited), reopened from the menu -> 50-s1-6-menu-launch.png,
same page. Moved the command back -> 8 s later the open window returned to the
status page (51); `--check` -> `installed: generation …; controller OK, fresh`, exit 0.

## Earlier Blocking findings

### B1 — the window ran nothing and never refreshed
Verdict: holds-fixed
Evidence:
- Plain launch from the menu (10) and as `nice-dns-gui` (65): strace shows
  `nice-dns status --tsv` every 5 s.
- The page follows state changes: container details "health starting" ->
  "health healthy" 13 s after the controller pass (11 -> 12); `nice-dns bridges
  on` run from ssh flipped the open window's switch back on within 8 s (26);
  stale and fresh controller (37, 38); command removed and restored (49, 51);
  kept source added (66).
- Every button, the switch, the banner's Apply and the Install button run
  their command (S1-1 list, 67), with output streamed and the exit shown.
- Closing by the title-bar X ends the process (three times).

### B2 — GPU hang and Mesa abort under the default renderer
Verdict: holds-fixed
Evidence:
Before: `sudo -n dmesg | grep -ci "gpu hang"` -> 9 (last 2026-11-09 22:57:51).
HEAD launched from the menu, GSK_RENDERER unset. Maximized (1440x860), then
wheel-scrolled 8+8+10 steps down, 30 up, 30 down, 30 up, 15 down (14-17: every
section drawn, no tearing), then used for ~25 minutes of clicks and scrolling.
After the demo: the count is still 9; `journalctl -k` since 06:50 has no GPU
HANG or reset. A launch with only `GSK_DEBUG=renderer` (gskdebug.txt) prints
`Using renderer of type 'GskCairoRenderer' for surface 'GdkX11Toplevel'`.
One GUI coredump was recorded (07:32:17, SIGABRT in a GTK assertion). The
journal shows it began with my `xdotool search --name "^nice-dns$" windowclose`
at the same second. That call destroys the X window from outside, which no user
route does. It is not the Mesa abort of B2 and not a finding.

### DEC-023 wording
Holds: the banner says "A different version is available: 0f6a6e755fb1", the
check's outcome "a different version is available (exit 10)", the Update row
"available: 0f6a6e755fb1". The words "an update is available" and "newer" were
not seen. The follow-up question is titled "Install the update?".

### DEC-018 / DEC-019
Holds as observed. Uninstall asks with a typed confirmation ("Type uninstall to go
ahead", Uninstall greyed until typed, 31). Reinstall asks (36, 44). Update/Apply
asks (53, 63). Restart and the bridges switch run at once and are not
destructive. Nothing re-rendered the install unattended: an available update
was only offered. No Mullvad wording or step appeared in the window or its
logs. Mullvad is not installed on mint, so that route was not exercised.

## Findings

No Blocking finding.

Minor (still seen from the first demo):
- **Sha-mismatch remedy.** The refused-sha line ends "reinstall with network
  to add it", the wrong remedy for bad bytes. Repro: zero the gui sha in the
  kept assets.lock, `nice-dns reinstall --local`.
- **"GUI not installed" while the old GUI stays.** After a failed or refused
  fetch, ~/.local/bin/nice-dns-gui (06:59:34, RELEASE) stays and the launcher
  opens it. Repro: block github.com in /etc/hosts, `nice-dns reinstall --local`, `ls -l ~/.local/bin/nice-dns-gui`.
- **Root-step noise without a terminal.** Every root step over ssh prints
  `Error creating textual authentication agent …` and `nice-dns-helper could
  not run '<verb>' (exit 127); running it through sudo` (install1.log,
  o2/o3 logs). Repro: any install over ssh.
- **PATH advice when PATH is already set.** The install ends "add this line to
  your shell profile: export PATH=…" although `bash -lc 'echo $PATH'` already
  starts with /home/user/.local/bin. Repro: install-git on mint.
- **Window taller than a 900 px screen.** Opens 842x982 at -11,-55 (02, 10, 50).
  Repro: open nice-dns from the menu on mint.
- **Menu search with the hyphen.** `nice-dns` finds nothing, `nice` finds the
  entry (01, 01b). The .desktop Keywords lack "nice-dns".

Minor (new):
- **Closing a dialog moves the page.** After "Cancel" on "Uninstall
  nice-dns?" the page jumped up to the Route row with a text cursor in its
  subtitle (32). After "Not now" on "Install the update?" it jumped to the top
  (55, 61). In both cases the button under the pointer moved away, so the next
  click landed on empty space and ran nothing (58; and 61/62 at 07:38:52,
  where strace recorded no exec for the click). Repro: scroll to the Installed buttons, click Uninstall, Cancel,
  click "Restart the stack" at the same spot.
- **Both GUI builds report `nice-dns-gui 0.1.0`.** The release asset
  (50eb5a55…) and HEAD's fixed build (0db7ffe1…) cannot be told apart by
  `--version`, and the Helper row shows only the helper's version. Repro:
  `nice-dns-gui --version` with each binary.

Observation, not a finding: `~/.config/nice-dns/` (bridge pool, bridges.env,
mode file) stays after `nice-dns uninstall`.

Overall: PASS with recorded residuals. B1 and B2 are fixed. Every Stage 1
Outcome holds by the user's route. Stage 2 Outcomes 1-3 hold. Outcome 4 cannot
be reached within this evaluation's limits (a live run), not because of a
defect. The plan goal grep over gui/share/actions.tsv passes (all ten actions
present).

## mint's final state

Re-installed from HEAD by the install-git command (install-final.log,
command_exit 0): generation 20261110T074614Z-772e0ed629f4, source_commit
772e0ed629f49fff58c90c8318e9f95018763a38, socat, standard Pi-hole, bridges on.
Then HEAD's own GUI build was copied over the release asset:
`~/.local/bin/nice-dns-gui` sha256 0db7ffe1725804c9bd151be7af6b4224d28137ac3602c94668e827e48f06c550
(`nice-dns-gui 0.1.0`). At 07:50Z: controller verdict OK, stale no, schedule
loaded, every check healthy; `/etc/resolv.conf` -> `nameserver 127.0.0.1`;
`dig +short @127.0.0.1 cloudflare.com` -> 104.16.133.229, 104.16.132.229;
`nice-dns-gui --check` -> "installed: generation 20261110T074614Z-772e0ed629f4;
controller OK, fresh", exit 0. /etc/hosts (181baad9…) and the kept source's
assets.lock (722028c6…) match their originals. No nice-dns-gui window, strace
or Firefox is left running. The session idle-delay is reset to its default.
/tmp/eval2 on mint was removed. The coredump from 07:32:17 is still in
coredumpctl.
