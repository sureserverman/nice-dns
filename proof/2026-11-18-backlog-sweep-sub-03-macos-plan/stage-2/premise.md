# Stage 2 premises — 2026-11-18-backlog-sweep-sub-03-macos-plan

Goal: A person who installs on a Mac over ssh gets a working stack, and a person who reinstalls often does not lose their disk to the builder.
Risk: HIGH — a runtime started in the wrong launchd domain wedged the mac's network for two hours on 2026-11-07. The fix never starts or moves a runtime outside the GUI domain, the fixture task comes first, and the live task has a known repair.

Outcomes:
- Works: `nice-dns install` or `reinstall` over ssh starts the container runtime where the login agent sees it; DNS answers when the install ends
- Works: after a successful install no builder container is left; the README says how to see disk use and what `container image prune -a` also removes
- Works: the mac, reinstalled over plain ssh from the branch, answers DNS, has the scoped-DNS block loaded and lists no `buildkit` container
- The Mac has no login session at all → the install stops before any change and says a user must be logged in at the Mac
- `container builder delete` fails → the install still succeeds and says the builder was left

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: an ssh session on the mac is outside the GUI launchd domain, so the installer can tell an ssh install from a Terminal one by `launchctl managername` (Background against Aqua).
Checked: on the mac, 2026-11-19: `ssh mac launchctl managername`.
Result: `Background` (Preflight printed the same). Aqua in a login Terminal was not observed: no one is at the mac's screen in this stage.
Verdict: holds for ssh; the Aqua branch is not checkable here — the fixture fakes it.

## Premise 2
Assumption: over ssh a direct `container system status` does not see the runtime the login agent runs in the GUI domain, and `launchctl asuser <uid> sudo -n -u <user> container ...` does (BL-052, DEC-024).
Checked: on the mac: `/opt/homebrew/bin/container system status` and `sudo -n launchctl asuser $(id -u) sudo -n -u $USER /opt/homebrew/bin/container system status`.
Result: direct: `apiserver is not running and not registered with launchd`; through asuser: `status running`, `client.version 1.7.1`.
Verdict: holds

## Premise 3
Assumption: `launchctl print gui/<uid>` tells a user with a GUI session from one with none, so the install can refuse before any change when nobody is logged in at the Mac.
Checked: on the mac: `launchctl print gui/$(id -u) >/dev/null; echo $?` and the same for uid 599 (no session).
Result: 0 for the logged-in user; 112 for uid 599.
Verdict: holds (the "no session at all" case for the real user is not checkable without logging them out; uid 599 stands in for it).

## Premise 4
Assumption: the mac's CLI deletes the builder, and builds leave a stopped `buildkit` container today (BL-024).
Checked: Preflight `container builder delete --help` (CLI 1.7.1); now `container ls -a | grep -i buildkit`.
Result: usage printed; `buildkit  ghcr.io/apple/container-builder-shim/builder:0.13.3 ... stopped`.
Verdict: holds

## Premise 5
Assumption: `container system df` shows disk use per kind, for the README's "Disk use on macOS".
Checked: on the mac, through asuser: `container system df`.
Result: Images 43 (4 active) 33.81 GB, 32.37 GB reclaimable (96%); Containers 4 (3 active) 2.18 GB; Local Volumes 2, 354.9 MB.
Verdict: holds

## Premise 6
Assumption (Risk HIGH): reaching the runtime through `launchctl asuser` from ssh does not start or move a runtime in the ssh domain, the start that wedged vmnet on 2026-11-07.
Checked: only the read-only `system status` and `system df` above, run through asuser. A `system start` through this path is first run in Task 2.3's live install.
Result: both reads answered from the GUI-domain runtime; nothing was started.
Verdict: holds for reads; the `system start` through the verb is first run live in Task 2.3, with the plan's Rollback ready.

## Premise 7 (found by Task 2.3's first live run)
Assumption: an install started over plain ssh (`ssh mac '~/.local/bin/nice-dns reinstall ...'`) finds Homebrew and the container CLI on PATH, as one started from Terminal does.
Checked: on the mac, 2026-11-19 15:26 UTC, the live reinstall from sweep-macos at b5050a8; then `ssh mac 'echo "PATH=$PATH"; command -v brew; ls -l /opt/homebrew/bin/brew'`.
Result: the install stopped in preparation with "Homebrew not found" (rc 1, nothing changed, the previous helper put back); PATH=/Users/user/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin — no Homebrew directory, while /opt/homebrew/bin/brew exists.
Verdict: false — fixed in the product (both macOS entrypoints add Homebrew's directories when PATH lacks them, the LaunchAgent's order), with a fixture case that reproduces the ssh PATH (RED 20261119T152755Z-4af27718, green 20261119T153534Z-6ae00c31). The Stage 2 Outcome it serves ("an install over ssh works") is unchanged.

## Limit (Task 2.3)
The mac's sudoers holds `user ALL=(ALL) NOPASSWD: ALL` (sudo -n -l, 2026-11-19), so the live run cannot show an ssh install that has to ask for a sudo password; the `runtime` verb goes to plain sudo.
