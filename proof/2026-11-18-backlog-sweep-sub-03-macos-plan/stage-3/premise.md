# Stage 3 premises — 2026-11-18-backlog-sweep-sub-03-macos-plan

Goal: The owner of a Mac knows what happens to DNS after a reboot, knows whether it can be made to work before login, and finds the signing and the address limits written down.
Risk: HIGH — the spike reboots the mac and starts Apple's runtime from the system domain, the kind of start that wedged vmnet before. The daemon is a scratch file the spike removes, the runtime it started is stopped before the owner logs in, and the reboot waits for the owner's go (OD-3).

Outcomes:
- Works: the README and the workflow document say that after a reboot the Mac has no DNS until its user logs in, and recommend automatic login
- Works: `docs/qualification.md` says, with the commands and their output, whether the runtime and the stack came up before login on macOS 27.2.1
- Works: the decisions register says that ad-hoc signing is accepted and why, and the backlog marks the fixed-address limit as parked on Apple

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: nothing blocks a launchd daemon at boot before any login: FileVault is off (no pre-boot unlock screen), and no automatic login is set (so the window before login is real).
Checked: on the mac, 2026-11-19 17:57 UTC: `fdesetup status`; `defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser`.
Result: "FileVault is Off."; "Could not find key 'autoLoginUser'".
Verdict: holds

## Premise 2
Assumption: sshd answers at the login window, so the state before login can be read over ssh.
Checked: `sudo -n launchctl print system/com.openssh.sshd`; `launchctl print-disabled system | grep ssh`; `sudo -n systemsetup -getremotelogin`.
Result: a system-domain daemon (path /System/Library/LaunchDaemons/ssh.plist), "com.openssh.sshd" => enabled, state "not running" (started on demand per connection); "Remote Login: On".
Verdict: holds — after the 17:59:18 reboot ssh answered at 17:59:54 with no user logged in (`uptime`: up 18 secs, 0 users).

## Premise 3
Assumption: the spike adds a scratch daemon and nothing else; no nice-dns daemon is there today.
Checked: `ls /Library/LaunchDaemons | grep -i -E "nice|spike|container"`.
Result: nothing listed.
Verdict: holds

## Premise 4 (the open question the spike answers)
Assumption under test: Apple's container runtime, and then the stack, can start from a system-domain LaunchDaemon with `UserName` before anyone logs in.
Checked: not yet — Apple's command reference documents no boot or login behaviour (Research Summary); the spike's reboot is the check.
Result (Task 3.1, 2026-11-19): the daemon ran at boot in the `System` domain (17:59:44); `container system start` failed with "XPC connection error: Connection invalid" (rc 1), status "not running and not registered with launchd", start-container.sh gave up after 10 tries (18:00:22); before login no apiserver ran and DNS timed out. After the owner's login the agent started the runtime (18:01:06) and DNS answered at 18:01:36.
Verdict: false — the runtime does not start before login (docs/qualification.md "macOS pre-login start", verdict: does not start). The plan foresaw this outcome; it changes no Goal or Outcome: Task 3.2 records it.
