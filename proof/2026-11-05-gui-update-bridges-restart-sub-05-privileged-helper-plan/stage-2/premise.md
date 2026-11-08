# Stage 2 premises — 2026-11-05-gui-update-bridges-restart-sub-05-privileged-helper-plan

Goal: A program with no terminal (the GUI) runs an install, update or uninstall through the helper, authorised by polkit on Linux and by the setuid bit on macOS, and the helper reaches a user's machine as a verified release asset.
Risk: HIGH — a flaw in the allow-list is a local root hole; the tier-1 review binds Tasks 2.1–2.3 and the threat model is written before the code.

Outcomes:
- Works: `nice-dns-helper pin` from a user process execs root-ops as root with only the three variables and a fixed PATH; polkit shows its prompt once (Linux); macOS prompts nothing.
- A verb or argument outside the allow-list → exit 2, nothing executed, the verb named on stderr.
- root-ops is missing, not root-owned, writable by others or a symlink → exit 3, nothing executed.
- The polkit dialog is dismissed (126) or denied (127) → the installer prints `authorisation cancelled` / `not authorised` and aborts or rolls back as for any failed verb.
- The asset download fails or its sha256 differs → the install continues without the helper and says `GUI actions needing root will not work until a reinstall with network`; a mismatch is never installed.
- The helper is installed but older than root-ops expects (`version` mismatch) → the installer re-installs it from the staged asset through root-ops `install-helper`.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: pkexec on mint (the Linux target) runs a program as root after polkit authorises it, and with no agent and no terminal it refuses with exit 127 rather than hanging (Outcome 4's 127 branch).
Checked: `ssh -T mint 'pkexec /bin/true </dev/null; echo rc=$?; pkexec --version; ls /usr/share/polkit-1/policyconfig-1.dtd'`, 2026-11-08.
Result: "Error creating textual authentication agent: ... /dev/tty: No such device or address", rc=127; pkexec version 124; the DTD exists.
Verdict: holds

## Premise 2
Assumption: a program in the desktop session (the GUI) has a polkit authentication agent to show the prompt (Outcome 1, "polkit shows its prompt once").
Checked: `ssh mint 'loginctl show-session c2 -p Type -p Desktop; ls /usr/share/cinnamon/js/ui/polkitAuthenticationAgent.js; pgrep -a -x cinnamon'`.
Result: session c2 is x11, Desktop=cinnamon, active; Cinnamon ships its own agent (polkitAuthenticationAgent.js) inside the running `cinnamon --replace` process (pid 2117), so no separate agent process shows.
Verdict: holds for registration; the prompt itself is not checkable here — it needs a person at mint's screen. Task 2.6 authorises through a temporary rules file instead (as the plan says).

## Premise 3
Assumption: on the mac, a root:wheel 4755 binary under /usr/local/libexec runs with euid 0: /usr/local is root-owned and its volume is not mounted nosuid.
Checked: `ssh mac 'sw_vers -productVersion; stat -f "%Su:%Sg %Sp %N" /usr/local /usr/local/libexec; mount | grep -E " /System/Volumes/Data "; mount | grep nosuid; csrutil status'`.
Result: macOS 27.2 arm64; both directories root:wheel drwxr-xr-x; /System/Volumes/Data is mounted (apfs, local, journaled, nobrowse, protect, root data) with no nosuid; the only nosuid mounts are an exFAT stick, a simulator image and a LuLu dmg; SIP enabled (SIP does not cover /usr/local).
Verdict: holds. Consequence for Task 2.1: the mac's /bin/bash drops euid to the real uid when the two differ and -p is not given, so the helper must make the real uid 0 too (setgid(0), setuid(0)) before exec — the "full setuid(0)" the Stage 1 handoff carries.

## Premise 4
Assumption: the helper builds here with `libc` as its only dependency (crates.io reachable or the crate cached).
Checked: `ls ~/.cargo/registry/cache/*/ | grep '^libc-0.2'; cargo --version`.
Result: libc 0.2.189-0.2.191 cached; cargo 1.93.1. The mac has cargo 1.99.1 (Preflight).
Verdict: holds

## Premise 5
Assumption: GitHub's `ubuntu-24.04`, `ubuntu-24.04-arm` and `macos-15` runners take jobs for sureserverman/nice-dns, and a pushed `v*` tag runs release.yml.
Checked: Preflight's `gh api /repos/sureserverman/nice-dns/actions/permissions -q .enabled` = true.
Result: Actions are enabled; whether the arm runner picks up a job is only shown by a run.
Verdict: not checkable here — no workflow run exists before Task 2.5 pushes the tag; Task 2.5's test is the check.
