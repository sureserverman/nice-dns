# Stage 2 premises — 2026-11-18-backlog-sweep-sub-02-controller-bridges-plan

Goal: A person reading `nice-dns status` or the journal sees what really happened, and the controller keeps working after a rollback, a failed query or a missing tool.
Risk: MEDIUM — Task 2.1 loosens the state reader and Task 2.6 reinstalls a live host. The reader still validates every known key; mint is disposable by rule and the installer rolls back on failure.

Outcomes:
- Works: a controller that meets a state key it does not know keeps running and says so once in the journal
- Works: a proxy on warm onion circuits keeps the onion route when the query for its generation fails or times out
- Works: the journal names the missing tool, the unit that is missing, and a visibility timeout as what they are
- Works: on mint, reinstalled from the branch, the controller's verdict is OK and a bridge refresh started by hand ends inside its limit
- A host with neither `sha256sum` nor `shasum` → the controller and the installer say the hash is unknown and stop that step; no two bridge sets compare equal by accident
- A state file with a bad value for a known key → refused as today, with the key named

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: on Linux `podman container exists <name>` tells an absent container (exit 1) from a query that failed (Task 2.2: "absent is exiting 1; any other failure is unknown").
Checked: on mint, 2026-11-19 07:06 UTC, podman 5.8.1: `podman container exists no-such-ctr-xyz; echo $?`, the same for `unbound`, with a bad flag, and with `XDG_RUNTIME_DIR=/nonexistent` (podman cannot load its configuration).
Result: absent rc 1, stderr only the storage warning; present rc 0; bad flag rc 125; config failure rc 1 with "Failed to obtain podman configuration: lstat /nonexistent: ...".
Verdict: holds in part. Exit 1 alone also covers a podman that cannot load its configuration. Resolved inside Task 2.2 without changing its Outcome: absent is exit 1 with nothing on stderr but podman's storage warning; exit 1 with any other stderr, 125, or a timeout is unknown and keeps the route.

## Premise 2
Assumption: on macOS a successful `container ls -a` that does not list the proxy means the proxy is absent (the macOS rebuild creates it after Unbound).
Checked: read lib/platform/macos.sh (`_nd_mac_table`, `nd_platform_container_generation`, 192-212): `ls -a` lists stopped and running containers; an `Error:` banner with exit 0 is already refused as no table.
Result: the code treats exit 0 plus a table as an answer; the Mac is not used in this stage.
Verdict: not checkable here — the Mac is not used in this sub-plan (OD-2 names mint only); the fixture runtime in route-transition stands in.

## Premise 3
Assumption: podman's storage warning on stderr has a stable text Task 2.4 can drop (and Task 2.2 can ignore).
Checked: on mint, the stderr of each podman call above.
Result: every call printed one line `time="..." level=warning msg="The storage 'driver' option should be set in /usr/share/containers/storage.conf. A driver was picked automatically."`
Verdict: holds

## Premise 4
Assumption: mint runs the minute controller with a good verdict, has the bridge timer, and its `nice-dns` takes `reinstall --branch` (Task 2.6, the mint gate check).
Checked: `ssh mint '~/.local/bin/nice-dns status --tsv | grep ^controller; systemctl --user list-timers; nice-dns --help'`.
Result: `controller verdict OK`, `stale no`, `schedule loaded`; nice-dns-health.timer, -bridges.timer and -update.timer listed; usage shows `reinstall [haproxy|socat] [--hardened|--standard] [--branch B] [--local]`. mint's awk is mawk 1.3.4.
Verdict: holds

## Premise 5
Assumption: the hermetic suite runs from this session.
Checked: this morning's baseline, `stage controller` 307/307 (run 20261119T061439Z-25a9071a), run in a user unit through `systemd-run --user` (Sub-plan 1's amendment, master OD-4).
Result: green that way; a direct run here hits the one-ID user namespace.
Verdict: holds, through systemd-run --user
