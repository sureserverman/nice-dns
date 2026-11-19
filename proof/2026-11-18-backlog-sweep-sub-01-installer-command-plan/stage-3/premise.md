# Stage 3 premises — 2026-11-18-backlog-sweep-sub-01-installer-command-plan

Goal: A person at a terminal gets one reading of the bridges mode, a restart that is not repeated behind their back, clear messages, and documents that match.
Risk: MEDIUM — Task 3.2 writes the controller's state from the command, and Task 3.5 reinstalls a live host. The state write goes through the existing locked writer; mint is disposable by rule and the installer rolls back on failure.

Outcomes:
- Works: `bridges-mode.env` means the same to the installer, the status, the Linux unit and the macOS agent, also after a hand edit that left two lines; the last line wins everywhere
- Works: after `nice-dns uninstall` no `bridges-mode.env` is left, so a later install starts with bridges on
- Works: after `nice-dns restart` the controller's next pass does not restart the stack again inside its cooldown
- Works: a macOS restart that waits on a slow Tor prints a waiting line every 30 s
- Works: mint, reinstalled from the branch, answers DNS and keeps at most 7 generation directories
- Running an installer as root → the same message from `install-deb.sh`, `install-mac.sh` and `nice-dns`

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: systemd's `EnvironmentFile=` takes the last line when a key repeats, so "the last line wins" already holds for the Linux proxy unit and the other readers must match it (Outcome 1).
Checked: `systemd-run --user --wait --pipe -p EnvironmentFile=<file with TOR_BRIDGES=on then TOR_BRIDGES=off> -- sh -c 'echo $TOR_BRIDGES'` on this laptop (systemd 255.4-1ubuntu8.18); mint runs systemd 255.4-1ubuntu8.17 (`ssh mint systemctl --version`), 2026-11-18.
Result: `TOR_BRIDGES=off`.
Verdict: holds

## Premise 2
Assumption: the hosts' awk and sh can read the last `TOR_BRIDGES=` line: mint's mawk 1.3.4, the Mac's /usr/bin/awk, and dash as the `/usr/bin/sh` of the unit's `ExecCondition=`.
Checked: `ssh mint` and `ssh mac`: `printf 'TOR_BRIDGES=on\nTOR_BRIDGES=off\n' | awk -F= '$1=="TOR_BRIDGES"{v=$2} END{print v}'`; `ssh mint readlink -f /usr/bin/sh` and a dash `sed -n s/^TOR_BRIDGES=//p | tail -n 1` test, 2026-11-18.
Result: mint mawk 1.3.4 20240123 → `off`; mac awk version 20200816 → `off`; mint /usr/bin/sh is /usr/bin/dash and detected `off`.
Verdict: holds

## Premise 3
Assumption: mint can be reinstalled from a pushed branch, and it now holds more than 7 generation directories, so Task 3.5's count can go red (Outcome 5).
Checked: `ssh mint 'ls ~/.local/state/nice-dns-install/generations | wc -l; dig @127.0.0.1 +short cloudflare.com'`, 2026-11-18.
Result: 191 directories; DNS answered 104.16.133.229.
Verdict: holds

## Premise 4
Assumption: a macOS restart that waits on a slow Tor prints a waiting line every 30 s (Outcome 4) — the live Mac wait.
Checked: not run: a live stack restart on the Mac is outside this sub-plan (fixtures only; OD-2 names mint as the only live target).
Result: —
Verdict: not checkable here — no live Mac restart is authorized in this sub-plan; the fixture macOS restart in Task 3.3 carries it
