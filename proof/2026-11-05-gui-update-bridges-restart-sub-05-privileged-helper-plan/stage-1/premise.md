# Stage 1 premises — 2026-11-05-gui-update-bridges-restart-sub-05-privileged-helper-plan

Goal: Every root-run step of an install, uninstall or rollback goes through `root-ops` with a named verb, and a terminal install behaves exactly as today.
Risk: HIGH — 89 call sites move; a wrong move breaks installs or uninstalls on real hosts. The installer fixtures are the net: every installer group runs on fakes that now match the root-ops lines, and the moved bodies are byte-compared against the old functions.

Outcomes:
- Works: `install-deb.sh` and `install-mac.sh` from a terminal prompt for sudo once (plus the keepalive) and run the same root steps as before, now as `sudo bash <tree>/<os>/root-ops <verb>` lines.
- A verb is unknown or an argument malformed → root-ops exits 2 with the verb named; the installer aborts before any change, or rolls back if one was made.
- root-ops is run as a non-root user → exit 1 `must run as root`.
- A rollback or uninstall → the same verbs in reverse, as today.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

*Written at the Stage 1 gate, 2026-11-08, not before Task 1.1 as Step 3.0 asks (an executor slip). Every check below ran on the real hosts, against the committed tree (ae9e1da).*

## Premise 1
Assumption: sudo on the targets runs `sudo bash <file> <verb>` as root for the installing user, with SUDO_USER set, and that user's passwd/directory entry names the home root-ops expects.
Checked: `ssh mint 'id -un; getent passwd "$(id -un)" | cut -d: -f6; sudo -n true'`; `ssh mac 'dscl . -read "/Users/$(id -un)" NFSHomeDirectory; sudo -n true'`
Result: mint user /home/user, sudo 1.9.15p5 (sudo -n true rc 0); mac NFSHomeDirectory /Users/user, sudo -n true rc 0.
Verdict: holds

## Premise 2
Assumption: root-ops' caller validation (getent or dscl, the tree's owner by `stat -c`/`stat -f`, `pwd -P`) passes as real root on each platform, and its refusals hold there: exit 2 for an unknown verb or a run of helper verbs, exit 1 run as the user, and a hostile environment (an exported `id` function, APT_CONFIG) changes nothing.
Checked: a `git archive` of ae9e1da unpacked to `~/nd-premise` on each host, then `sudo bash ~/nd-premise/deb/root-ops dns status` (mint) and `sudo bash ~/nd-premise/mac/root-ops agent status` (mac), the same with `frob`, with `dns "check status"`, without sudo, and on mint under `sudo env BASH_FUNC_id%%=... APT_CONFIG=/tmp/x`. Both copies were removed afterwards.
Result: mint `pinned` rc 0, frob rc 2, run of verbs rc 2, as user rc 1 `must run as root`, hostile env `pinned` rc 0; mac `pinned` rc 0, frob rc 2, as user rc 1.
Verdict: holds

## Premise 3
Assumption: macOS's /bin/bash is 3.2, so mac/root-ops must parse and run there; a scrubbed environment (no TMPDIR) still gives mktemp a directory.
Checked: `ssh mac '/bin/bash --version | head -1; env -i /bin/bash -c mktemp'`
Result: GNU bash 3.2.57(1)-release (arm64-apple-darwin26); mktemp printed a /var/folders/... path.
Verdict: holds

## Premise 4
Assumption: a full terminal install, which runs every verb's body as root on a real host (packages, the pin, NetworkManager, the sudoers rule, visudo), behaves as before.
Checked: not run at this stage. It changes the targets' DNS stack and takes several minutes per host.
Result: —
Verdict: not checkable here — the Stage 1 demo evaluator gets it (a reinstall from this branch on mint and the mac), and Task 2.6 repeats it with the helper.
