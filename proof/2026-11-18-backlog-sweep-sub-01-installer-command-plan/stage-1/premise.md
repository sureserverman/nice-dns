# Stage 1 premises — 2026-11-18-backlog-sweep-sub-01-installer-command-plan

Goal: A person who installs or updates nice-dns gets the whole install through a passing network failure, a truthful line about bridges, and no pile of old generations.
Risk: LOW — every change is in preparation or after a successful install; fixtures with fake `curl`, `podman`, `git` and `systemctl` cover each path.

Outcomes:
- Works: a GUI or helper download whose connect or name lookup fails is tried again, up to 3 times 20 s apart, and the app is installed
- Works: an image pull or the clone whose name lookup fails is tried again, up to 3 times, before the install gives up
- Works: after a successful install the state directory keeps the running generation, its rollback and the 5 newest others; older directories are gone
- Works: the install prints `Bridges selected` only when a selection ran, and `kept the existing bridges` when it was skipped
- Every download try fails → the install still finishes without the GUI, and its note names the address curl tried and how long the connect took
- The branch asked for does not exist → the message says the branch was not found and does not ask whether DNS is down
- Every pull try fails → the install stops in preparation with the registry name in the message; the running stack is untouched

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: curl reports a failed connect as exit 7 and a failed name lookup as exit 6, and a not-found asset as 22; `-w '%{remote_ip} %{time_connect}'` names the address tried and the connect time on a failed connect.
Checked: on this laptop (curl 8.5.0): `curl -fsSL -w 'ip=[%{remote_ip}] tc=%{time_connect} tt=%{time_total}' -o /dev/null --connect-timeout 5 https://localhost:1/x`; the same against https://no-such-host.invalid/x and a missing release URL on github.com.
Result: exit 7, 6 and 22 as assumed. On the failed connect `%{remote_ip}` is empty and `%{time_connect}` is 0.000000; curl's own error line carries the host, port and time: `Failed to connect to localhost port 1 after 0 ms: Couldn't connect to server` (BL-067's mint sample has the same shape: `after 1783 ms`). A connect timeout is exit 28, not 7.
Verdict: holds for the exit codes; the `-w` mechanism is false on a failed connect. The Outcome still holds: the note carries curl's own error line (host, port, ms) and `%{remote_ip} %{time_total}` when curl fills them. Implementation detail of Task 1.1, not a change to the Outcome.

## Premise 2
Assumption: a failed name lookup has a recognisable text in podman, Apple `container` and git, and git can tell a missing branch apart.
Checked: podman: BL-044's live record (`lookup registry-1.docker.io: no such host`); this laptop's podman cannot run a pull (user namespace error, a known laptop issue), so the live record stands. mac (container CLI via launchctl asuser, DEC-024): `container image pull no-such-host.invalid/x/y:1`. Laptop: `git clone https://no-such-host.invalid/x.git`; `git ls-remote --exit-code --heads https://github.com/sureserverman/nice-dns.git no-such-branch-xyz`; `git clone --depth 1 -b no-such-branch-xyz <repo>`.
Result: Apple container: `Error: failed to resolve either repository hostname no-such-host.invalid`. git: `Could not resolve host: no-such-host.invalid`. ls-remote on a missing branch: exit 2. clone of a missing branch: `fatal: Remote branch no-such-branch-xyz not found in upstream origin`.
Verdict: holds. The lookup patterns add Apple's `failed to resolve` beside the plan's three.

## Premise 3
Assumption: a oneshot whose `ExecCondition=` skipped it reads `Result=exec-condition` in `systemctl --user show -p Result`.
Checked: `ssh mint 'systemctl --user show -p Result nice-dns-fetch-bridges.service'` (the real unit, last started by the install and skipped).
Result: `Result=exec-condition`.
Verdict: holds
