# Stage 2 premises — 2026-11-10-app-switches-autocheck-plan

Goal: A person using the Linux window or the macOS menu-bar app can switch the proxy and the Pi-hole flavour from an own control, without opening Reinstall.
Risk: LOW — two clients of a table and a contract that Stage 1 fixed; no privileged code.

Outcomes:
- Works: the Installed section shows a Proxy selector (haproxy, socat) and a Pi-hole selector (standard, hardened) set to what `status` says; on macOS the menu has the same two choices as submenus with a check mark
- Works: picking the other value asks first ("Switch the proxy to socat? The stack is reinstalled from the kept source. This takes a few minutes and DNS stops briefly."); on Switch the action runs with its output in the log pane, the selector shows the new value while it runs, and the next status read confirms it
- Works: the Check for an update button and the update banner behave as before; the Update row's "checked ... ago" now also moves when the schedule ran
- Not now or the dialog dismissed → the selector goes back to the installed value; nothing runs
- The switch fails (exit 3, or a root step not authorised) → the selector goes back to the installed value; the log pane shows the command's stderr and the named exit; a toast says the switch did not happen
- Another action is running → both selectors are disabled until it ends, like every button
- `status` does not name the variant or the flavour, or names a value outside the two → that selector is disabled and shows `unknown`
- Nothing is installed → the not-installed page, as before; no selectors

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: both targets' installed `nice-dns status --tsv` names the variant and the flavour in rows the apps can set their selectors from.
Checked: `ssh mint '~/.local/bin/nice-dns status --tsv | grep -E "variant|pihole"'` and the same on mac.
Result: both print `install	variant	socat` and `install	pihole	standard`; the shared fixture status-installed.tsv carries the same two rows.
Verdict: holds

## Premise 2
Assumption: mint's GTK and libadwaita (the Linux window's runtime) provide the widgets the selectors use (gtk::DropDown, as the Reinstall dialog already does) at the versions the crate targets (gtk4 v4_14, libadwaita v1_5).
Checked: `ssh mint 'dpkg-query -W libgtk-4-1 libadwaita-1-0'`; `grep -n DropDown gui/linux/src/window.rs`.
Result: libgtk-4-1 4.14.5, libadwaita-1-0 1.5.0 on mint (the laptop builds against 4.14.5 / 1.5.0); window.rs:598-600 already builds gtk::DropDown for the Reinstall dialog.
Verdict: holds

## Premise 3
Assumption: the mac runs a SwiftUI that has Picker in a Form and in a menu (submenus with a check mark), on macOS 13+ as the package targets.
Checked: `ssh mac 'sw_vers -productVersion; swift --version'`; `grep -n Picker gui/mac/Sources/NiceDNSGUI/WindowView.swift`.
Result: macOS 27.2, Swift 6.3.3; WindowView.swift:312-313 already uses Picker for the Reinstall dialog's choices, and the app built there in Task 1.3 (swift build, Build complete).
Verdict: holds

## Premise 4
Assumption: both apps are installed on the targets, so Stage 3's live cells can run the new actions through the apps' hooks.
Checked: `ssh mint 'ls ~/.local/bin/nice-dns-gui'`; `ssh mac 'ls -d ~/Applications/nice-dns.app'`.
Result: both present (v1.3.0 builds; Stage 3 installs v1.4.0).
Verdict: holds
