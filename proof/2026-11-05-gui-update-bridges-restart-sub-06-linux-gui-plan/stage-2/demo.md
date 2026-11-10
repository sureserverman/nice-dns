# Stage 2 demo — 2026-11-05-gui-update-bridges-restart-sub-06-linux-gui-plan

Environment: mint (Linux Mint 22.3, Cinnamon on X11, DISPLAY=:0, 1440x900,
Intel GM965/GL960 graphics, GTK 4.14 / libadwaita 1.5), reached by `ssh mint`.
Branch gui-linux at HEAD 143ef9e, put on mint by the real `nice-dns install`
through `tests/live/target.sh command mint --mode install-git --cell
socat/standard` (generation 20261109T224841Z-143ef9e75c2f). The installed
`nice-dns-gui` is the v1.1.0 release asset pinned in release/assets.lock
(`nice-dns-gui 0.1.0`). The window was driven as a person would: the
Cinnamon applications menu (Super, type, Return), mouse clicks, wheel and
keys, all through xdotool in the user's session (`systemd-run --user`).
Screens were captured with a PIL grab of :0 (not the `--screenshot` hook)
and every PNG was looked at. PNGs live in
/tmp/claude-1000/-home-user-dev-containers-nice-dns/f4c531d7-439e-4230-8ed0-d483590de17e/scratchpad/eval/
(named below without that folder). The session's screen lock was lifted
with `cinnamon-screensaver-command -d` before each capture.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: after `nice-dns install` on Linux, `nice-dns-gui` is on the user's PATH, the launcher shows nice-dns, the app opens on the status page; uninstall removes all of it.
Verdict: holds
Evidence:
```
$ target.sh command mint --mode install-git --cell socat/standard --source-sha 143ef9e...   (install1.log)
▸ Fetching nice-dns-gui (linux/amd64)
▸ Generation 20261109T224841Z-143ef9e75c2f is active (previous: 20261109T221414Z-1102b4f6918a).
The nice-dns window: open nice-dns from the applications menu, or run /home/user/.local/bin/nice-dns-gui
command_exit 0

$ ssh mint 'bash -lc "command -v nice-dns-gui; nice-dns-gui --version"'
/home/user/.local/bin/nice-dns-gui
nice-dns-gui 0.1.0
(PATH comes from Mint's ~/.profile, which adds ~/.local/bin when it exists)
~/.local/share/applications/nice-dns.desktop: Name=nice-dns, Exec=/home/user/.local/bin/nice-dns-gui,
  Icon=nice-dns (~/.local/share/icons/hicolor/256x256/apps/nice-dns.png); desktop-file-validate exit 0
$ nice-dns-gui --check   -> "installed: generation 20261109T224841Z-143ef9e75c2f; ...", exit 0
```
- 01-menu-search.png / 01b: Cinnamon menu, search text `nice-dns` (with the
  hyphen): no result. 01c-menu-nice.png: search `nice`: one entry, the nice-dns
  icon, "nice-dns / See and manage the nice-dns stac…".
- Return on that entry -> 02-gui-open.png: window "nice-dns", subtitle
  "generation 20261109T224841Z-143ef9e75c2f · socat · standard Pi-hole · branch
  main", Containers (pi-hole/unbound/tor-socat healthy), Bridges switch on
  ("7 bridges, last refresh never"), Health controller (Verdict OK, Last pass
  just now, Mode active, Schedule loaded), log pane "No action run yet". The
  status page, not an error page. (The window opened 842x982 on a 900 px
  screen, partly off screen; maximized for the later captures: 03-gui-max.png.)
```
$ ssh mint '~/.local/bin/nice-dns uninstall'   (o1-uninstall.log)
custom-dns-deb: restored the resolver state from before nice-dns (fresh)
nice-dns uninstalled.   exit=0
after: ~/.local/bin empty; no nice-dns.desktop; no nice-dns icon; ~/.local/share/nice-dns gone;
       bash -lc 'command -v nice-dns-gui' -> not found; /etc/resolv.conf -> 127.0.0.53
```
- 38-menu-after-uninstall.png: menu search `nice` now finds nothing.

## Outcome 2
> The asset download fails → the install continues and says `GUI not installed; reinstall with network to add it`.
Verdict: holds
Evidence:
Injection (mint only, undone): appended `0.0.0.0 github.com`,
`objects.githubusercontent.com`, `release-assets.githubusercontent.com` to
/etc/hosts (backup /tmp/eval-hosts.orig); `curl` to the release URL then
failed with exit 7. Then the user's own command:
```
$ ssh mint '~/.local/bin/nice-dns reinstall --local'   (o2-reinstall-nodownload.log)
▸ Preparing generation 20261109T232105Z-nogit0000000 (source checkout, commit unknown; previous ..., rollback available)
▸ Fetching nice-dns-gui (linux/amd64)
! The nice-dns-gui download failed (curl exit 7): GUI not installed; reinstall with network to add it.
... (images, quadlets, bridges, controller, DNS pin all proceed)
▸ Generation 20261109T232105Z-nogit0000000 is active (previous: 20261109T231735Z-nogit0000000).
! The nice-dns-gui download failed (curl exit 7): GUI not installed; reinstall with network to add it.
exit=0
```
The install went on and finished (exit 0, DNS answering). /etc/hosts was put
back from the backup (`grep -c githubusercontent /etc/hosts` -> 0).
Note: the GUI files from the previous good install (22:51) stayed in place, so
"GUI not installed" is true of this run only; the launcher still opened the
older, verified copy.

## Outcome 3
> The asset's sha256 differs → refused, same message.
Verdict: holds
Evidence:
Injection (mint only, undone): in the kept source
`~/.local/share/nice-dns/source/release/assets.lock` the `gui linux amd64` row's
sha256 `9557135b…167788` was replaced by 64 zeros (backup
/tmp/eval-assets.lock.orig, sha256 722028c6…c908). Then:
```
$ ssh mint '~/.local/bin/nice-dns reinstall --local'   (o3-reinstall-badsha.log)
▸ Fetching nice-dns-gui (linux/amd64)
! The nice-dns-gui download's sha256 is not the one release/assets.lock pins; it was not installed: GUI not installed; reinstall with network to add it.
...
▸ Generation 20261109T231735Z-nogit0000000 is active (previous: 20261109T224841Z-143ef9e75c2f).
! The nice-dns-gui download's sha256 is not the one release/assets.lock pins; it was not installed: GUI not installed; reinstall with network to add it.
exit=0
```
The downloaded bytes were refused; ~/.local/bin/nice-dns-gui kept its 22:51
timestamp (not replaced). The lock was restored (sha256 722028c6…c908 again).
Nit: the tail "reinstall with network to add it" names the wrong remedy for a
hash mismatch, but it is the message this Outcome asks for.

## Outcome 4
> A target is unreachable → that check is `[~]` with the reason.
Verdict: cannot reach by the user's route
Evidence:
The route to this branch is a live run (`tests/run.sh live gui-linux` against a
target that does not answer), which this evaluation was told not to start; it
is the evaluator's limit, not a product defect. What the owner reads instead,
the committed receipt
`proof/2026-11-05-gui-update-bridges-restart-sub-06-linux-gui-plan/2.3/receipt.tsv` (moved at close-out to `docs/evidence/2026-11-05-gui-update-bridges-restart-sub-06-linux-gui-plan/2.3/receipt.tsv`: only records may live under proof/)
(run 20261109T205402Z-2c933b54), reached its one target: `cell linux socat
standard mint generation=20261109T210323Z-b9127e2fba9e observed`, six
scenarios `pass`, one `limit no-person-clicked`, and no row marked `[~]`. The
unreachable branch itself was not exercised.

## Stage 1 Outcomes (re-demo at close-out)

### S1-1
> Works: the window shows installed state, an update banner, a containers table, observations, bridges (a switch), the controller, recent actions; a button per action streams the command's output and shows its exit; the admin page opens in the browser.
Verdict: does not hold
Evidence:
Shown (02, 03, 12-cairo-p0..p4, 13-cairo-q1/q2, 36): subtitle with generation,
Containers table, Bridges switch, Health controller (Verdict, Last pass, Mode,
Schedule, Route) with buttons "Run a health check now", "Start the health
controller", "Stop the health controller", "Show recent failures"; Installed
(Generation, Source commit, Proxy, Pi-hole, Update "not checked yet", Helper
"installed, 0.1.1") with "Check for an update", "Restart the stack",
"Reinstall the stack", red "Uninstall nice-dns"; Pi-hole admin with "Open the
Pi-hole admin page", "Show where the admin password is"; Recent actions;
Observations (runtime, proxy, dns-owner, install-drift, local-service,
filtering, local-cache, four routes, unbound). The update banner "An update is
available: 0f6a6e755fb1 [Apply]" showed in 36 once an update check had been
recorded.

What fails, by the user's route:
1. Default renderer, opened from the menu: stderr says
   `Gsk-Message: Failed to realize renderer of type 'GskNglRenderer' ... OpenGL ES 3.0 is not supported by this renderer.`
   and GTK falls back to its GL renderer. Scrolling down to reach the buttons
   hangs the GPU: kernel `i915 ... [drm] GPU HANG: ecode 4:1:8545f8ff, in nice-dns-gui [2186227]`,
   `Resetting chip for stopped heartbeat on rcs0`, three times, then
   `Process 2186227 (nice-dns-gui) of user 1000 dumped core` (SIGABRT,
   22:54:35; stack: abort <- libgallium dri_flush <- loader_dri3_swap_buffers_msc
   <- gdk_draw_context_end_frame <- gsk_renderer_render). The window vanished
   (07-gui-mid.png shows the desktop where it was). Reproduced on a second menu
   launch (GPU HANG 22:57:36, then torn, half-drawn frames: 09, 10). The
   buttons below the Health controller never rendered in that mode.
2. Diagnostic only, not the user's route: with `GSK_RENDERER=cairo` the page
   scrolls and draws fully (12/13 series), so the rest was tried that way and
   again on menu launches.
3. No button runs its command. Clicked "Check for an update" (14-16, 29),
   "Show where the admin password is" (17, 19; and by keyboard: Tab focus ring
   on it, Return, 26-28), "Apply" on the update banner (37), the Bridges switch
   (31-33, both renderers), "Install nice-dns" (41). Each time the log pane
   stayed "No action run yet". `strace -f -e trace=execve -p <gui pid>` during
   those clicks recorded no exec at all (eval-strace4/5/6: 0 lines); the
   Bridges switch flipped to off and its row greyed out, but
   `~/.config/nice-dns/bridges-mode.env` stayed `TOR_BRIDGES=on` and the row
   never came back. The clicks reach the widgets (the switch moves; xdotool
   clicks work in simple-scan, a GTK4/libadwaita app on the same session: 23).
4. The window never refreshes. Under strace from launch the GUI ran
   `nice-dns status --tsv` once (23:07:28) and nothing in the next 35+ s;
   `strace -c` over 6 idle seconds counted zero syscalls; the stale page in 36
   kept "stale 324s" for over a minute. The 5 s poll does not run.
5. The same command through the test hook works:
   `nice-dns-gui --run-action update-check --exit` printed
   `$ /home/user/.local/bin/nice-dns update --check` / `available 0f6a6e755fb1` /
   `an update is available (exit 10)`, rc=10. So the runner works; the click
   path and the timer do not reach it.
The admin page could not be opened (its button runs nothing).

### S1-2
> Not installed → a page saying so with the README curl line and an Install button only when the kept source exists.
Verdict: holds
Evidence:
State built on mint after `nice-dns uninstall` (which removes the command, so a
user cannot reach this page right after an uninstall): copies of `nice-dns` and
`nice-dns-gui` put back in ~/.local/bin, no kept source.
`nice-dns status` -> `install installed no` + hint line, exit 1; `nice-dns-gui
--check` -> `not installed; install with: curl -fsSL https://raw.githubusercontent.com/sureserverman/nice-dns/main/install-deb.sh -o install-deb.sh && bash install-deb.sh`, exit 1.
- 39-s1-2-no-source.png: subtitle "not installed", "nice-dns is not installed",
  "Install it with this line in a terminal:" and the README curl line; no
  Install button.
- Kept source copied back to ~/.local/share/nice-dns/source, window reopened:
  40-s1-2-with-source.png shows the same page plus a full-width "Install
  nice-dns" button.
- Clicking that button did nothing (41; no exec under strace), as in S1-1.
The copies and the source were removed again before the final install.

### S1-3
> The controller is stale → the sections are shown greyed with `stale <seconds>`.
Verdict: holds
Evidence:
`ssh mint 'nice-dns-health stop'` ("Timer stopped.", 23:11:19); waited until
`nice-dns status --tsv` printed `controller stale 310` (23:16:19). Opened
nice-dns from the menu -> 36-s1-3-stale.png: Containers rows and Health
controller rows greyed, each heading with an amber `stale 324s` on the right;
Last pass "5 min ago"; the Bridges row not greyed. Holds for a window opened
while stale. A window already open does not turn stale (no refresh, S1-1 item
4): the number stayed 324s. `nice-dns-health start` -> "Timer started."

### S1-4
> An action fails → its output and exit code stay in the log pane; the buttons re-enable.
Verdict: does not hold
Evidence:
No clicked action runs (S1-1 item 3), so no failure output ever reaches the
log pane ("No action run yet" throughout). The one control that changed state
on a click, the Bridges switch, greyed its row and never re-enabled it (31, 32,
33: still greyed with the switch off while the mode file said on).

### S1-5
> A polkit prompt is dismissed → the log shows `authorisation cancelled` from the command.
Verdict: cannot reach by the user's route
Evidence:
Cinnamon's polkit agent runs in the session and dialogs can be dismissed with
the keyboard, but no root action can be started from the window: "Uninstall",
"Reinstall", "Install" and the switch run no command (S1-1 item 3), so no
polkit prompt appears. Caused by the defect in S1-1, not by a tool limit.
(Over ssh, the installer's own root steps show
`Error creating textual authentication agent ...` /
`nice-dns-helper could not run 'pin' (exit 127); running it through sudo`.)

### S1-6
> `nice-dns` is missing from `~/.local/bin` → one error page naming the path, exit 1 for `--check`.
Verdict: holds
Evidence:
`mv ~/.local/bin/nice-dns /tmp/eval-nice-dns.saved`; opened nice-dns from the
menu -> 34-s1-6-missing.png: subtitle "error", one page "nice-dns cannot be
read" / "The nice-dns command is not installed: looked for
/home/user/.local/bin/nice-dns". `nice-dns-gui --check` ->
`nice-dns command not found: looked for /home/user/.local/bin/nice-dns`,
exit 1. Moved the command back; the open window still showed the error 15 s
later (35), consistent with no refresh.

## Findings

- **Blocking B1 — the window runs nothing and never refreshes.** No button,
  banner Apply or switch starts its command; the status is read once at launch.
  Evidence: S1-1 items 3-5 (strace: one `status --tsv` at launch, no exec on
  clicks; log pane "No action run yet"; switch row stuck greyed; the
  `--run-action` hook runs the same action fine). Repro: on mint open nice-dns
  from the menu, click "Check for an update" -> nothing in the log pane.
- **Blocking B2 — the default renderer hangs the GPU and aborts on mint.** GTK
  falls back from NGL to GL on the GM965; scrolling hangs the i915 ring and the
  app dies with SIGABRT in Mesa (coredump 2186227). `GSK_RENDERER=cairo` avoids
  it. Repro: open nice-dns from the menu on mint, scroll the page with the wheel.
- **Minor — sha mismatch remedy.** The refused-sha line ends "reinstall with
  network to add it", which is the wrong remedy for bad bytes (as specified).
- **Minor — "GUI not installed" while the old GUI stays.** After a failed or
  refused fetch the earlier GUI files stay and the launcher still opens them.
- **Minor — root-step noise without a terminal.** Every root step over ssh
  prints `Error creating textual authentication agent ...` and
  `nice-dns-helper could not run '<verb>' (exit 127); running it through sudo`.
- **Minor — PATH advice.** The install ends "add this line to your shell
  profile: export PATH=..." though Mint's ~/.profile already adds ~/.local/bin.
- **Minor — window taller than a 900 px screen** (opens 842x982, top and bottom
  off screen); menu search `nice-dns` (with the hyphen) finds nothing, `nice`
  does.

DEC-018 / DEC-019: nothing seen re-renders the install or touches Mullvad; but
"destructive actions ask first" could not be observed because no action starts.

Overall: FAIL (B1, B2).

## mint's final state

Re-installed from HEAD by the install-git command (install-final.log,
command_exit 0): generation 20261109T232843Z-143ef9e75c2f, source_commit
143ef9e75c2f723efbb23ba6942571bb500f22f9, socat, standard Pi-hole, bridges on.
At 23:34Z: controller verdict OK, stale no, schedule loaded, every check
healthy; `/etc/resolv.conf` -> `nameserver 127.0.0.1`;
`dig +short @127.0.0.1 cloudflare.com` -> 104.16.132.229, 104.16.133.229;
`nice-dns-gui --check` -> "installed: generation 20261109T232843Z-143ef9e75c2f;
controller OK, fresh", exit 0. /etc/hosts and the kept source's assets.lock
are back to their originals; no nice-dns-gui window or eval-* unit is left
running; the evaluator's /tmp/eval-* files on mint were removed.
