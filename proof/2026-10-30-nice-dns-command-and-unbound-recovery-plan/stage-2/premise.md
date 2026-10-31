# Stage 2 premises — 2026-10-30-nice-dns-command-and-unbound-recovery-plan

Goal: A person on Linux or macOS manages the stack with one command: `nice-dns install|uninstall|reinstall|restart`.
Risk: MEDIUM — `uninstall` is destructive and the snapshot joins the install transaction.

Outcomes:
- Works: `./nice-dns install [haproxy|socat] [--hardened] [--branch B]` from a checkout installs and leaves `nice-dns` on PATH. `reinstall` and `restart` work from any directory, and `uninstall` removes the stack and then the command itself.
- Run as root → refuses with the same message as the installers, exit 1.
- Unknown subcommand or option → usage on stderr, exit 2.
- `reinstall` or `restart` with nothing installed → "nice-dns is not installed; run `nice-dns install`", exit 1, nothing changed.
- `reinstall` clone fails (DNS is down) → says so and names `nice-dns reinstall --local`, which uses the kept snapshot; the running stack is untouched.
- `restart` gets no DNS answer within its wait → says DNS is not answering yet and names `nice-dns-health status`, exit 1.
- `~/.local/bin` is not on PATH → the install prints the full path and how to add it.
- `reinstall --hardened` without the sibling `pi-hole-hardened` checkout → the installer's existing refusal, before any change.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: `/bin/bash` on the Mac is Bash 3.2, so the dispatcher must avoid newer syntax.
Checked: `ssh mac '/bin/bash --version | head -1'`
Result: GNU bash, version 3.2.57(1)-release (arm64-apple-darwin26)
Verdict: holds

## Premise 2
Assumption: `~/.local/bin` is writable on both hosts and on the login PATH of a normal shell, while a non-login shell may not have it, so the PATH notice is reachable and worth having.
Checked: `ssh mint 'echo $PATH; bash -lc "echo $PATH"'`; `ssh mac 'echo $PATH; zsh -lic "echo $PATH"'`; `ls -ld ~/.local/bin` on both.
Result: mint: not on the ssh PATH, on the login PATH. mac: not on the ssh PATH, on the interactive zsh PATH. The directory exists, owned by the user, on both.
Verdict: holds

## Premise 3
Assumption: `~/.local/share/nice-dns` is free on both hosts, so the snapshot takes nothing over.
Checked: `ls -ld ~/.local/share/nice-dns` on both.
Result: No such file or directory on both.
Verdict: holds

## Premise 4
Assumption: `git clone` with DNS failing ends by itself with a non-zero exit and does not hang.
Checked: `time git clone -q https://github.invalid/x.git /tmp/nd-x` on mint; an unresolvable name stands in for failing DNS.
Result: "Could not resolve host", rc=128, 0.04 s. A resolver that hangs rather than refuses was not checked; the command adds git's low-speed limit for a stalled transfer.
Verdict: holds

## Premise 5
Assumption: the kept snapshot passes the installers' checkout test, so it can install and uninstall with no clone.
Checked: read the tests in `install-deb.sh` (`lib/install.sh`, `deb/quadlet`, `deb/custom-dns-deb`) and `install-mac.sh` (`lib/install.sh`, `mac/persist.sh`). The snapshot list holds all of them. `git` is present on both hosts today; the test removes it.
Result: Every named path is in the snapshot list.
Verdict: holds

## Premise 6
Assumption: holding the controller from a terminal session works on the Mac without disturbing its runtime. A runtime STARTED over ssh goes to the wrong launchd domain (BL-052), so `restart` must never call `container system start`.
Checked: `launchctl unload` and `load` of the health plist over ssh, three times on 2026-10-30. Ticks resumed each time, and the apiserver stayed in `gui/501`. `nd_platform_restart_stack` on macOS is a `launchctl kickstart -k gui/<uid>/...`, which targets the GUI domain from any session.
Result: Ticks resumed; apiserver in `gui/501`.
Verdict: holds
