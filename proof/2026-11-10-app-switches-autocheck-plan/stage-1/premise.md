# Stage 1 premises — 2026-11-10-app-switches-autocheck-plan

Goal: The owner at a terminal, and later both apps, can switch the proxy and the Pi-hole flavour with one command on any machine, and the controller checks for an update twice a day.
Risk: MEDIUM — Task 1.1 changes how the hardened image is sourced in the shared installer; a mistake there breaks hardened installs on both platforms. Fixture tests cover it here and a live hardened switch covers it in Stage 3.

Outcomes:
- Works: `nice-dns switch proxy socat` (or `haproxy`) and `nice-dns switch pihole hardened` (or `standard`) reinstall the kept source with that one choice changed; the last line says what now runs and that DNS answers; `nice-dns status` shows the new `variant` or `pihole`, and the same `source_commit` as before
- Works: a switch to hardened builds the base from the nice-dns tree on a machine that has no pi-hole-hardened checkout
- Works: twice a day the controller runs the check; `nice-dns status` shows its result and time in the `update` rows, and `update auto loaded`
- The choice asked for is the one installed → `Already <choice>; nothing changed.`, exit 0, nothing is reinstalled
- Nothing is installed → `nice-dns is not installed; run nice-dns install` on stderr, exit 1
- No kept source (an install older than the kept source) → stderr names the missing directory and `nice-dns reinstall`; exit 1; the stack is untouched
- The install fails (a build or pull fails, DNS does not come back) → the installer restores the running stack; stderr says the switch did not happen and the old choice still runs; exit 3
- A wrong or missing word (`switch proxy nginx`, `switch`) → a usage line on stderr, exit 2, nothing runs
- The scheduled check cannot reach GitHub or runs past 60 s → the cache says `unknown`, with the time; nothing else changes; the next slot tries again
- The schedules were stopped with `nice-dns-health stop` → `update auto stopped`; no check runs until `start`

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: both targets keep a source tree the switch can reinstall from with no clone, and publish `nice-dns` where the controller can find it.
Checked: `ssh mint|mac 'ls -d ~/.local/share/nice-dns/source/lib/install.sh ~/.local/share/nice-dns/source/pihole-hardened ~/.local/bin/nice-dns'`; fixture cases t_reinstall_local_uses_the_snapshot_with_no_clone and t_reinstall_flags_override_the_record in the green baseline of `integration nice-dns-cli`.
Result: all three paths exist on mint and on mac; both cases PASS (baseline 2026-11-10, 430 s).
Verdict: holds

## Premise 2
Assumption: the Alpine base the hardened Dockerfile names (alpine:3.21.3) has a published multi-platform index that covers every platform the lock supports, so it can be pinned by digest.
Checked: Docker Hub registry API, `GET /v2/library/alpine/manifests/3.21.3` with the OCI index Accept header, from this laptop.
Result: docker-content-digest sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c; platforms linux/amd64, arm/v6, arm/v7, arm64/v8, 386, ppc64le, riscv64, s390x. arm64 carries the variant v8: the lock row must name it as linux/arm64, the form the install compares.
Verdict: holds

## Premise 3
Assumption: the hardened FTL binary exists for each supported CPU, so a build from the tree works on mint (amd64) and on the mac (arm64).
Checked: `cat ../pi-hole-hardened/checksums/FTL-v6.6.1.sha256`.
Result: sha256 rows for pihole-FTL-amd64, -arm64, -armv7, -riscv64.
Verdict: holds (the build itself is proven live in Task 3.3)

## Premise 4
Assumption: the targets' systemd accepts `OnCalendar=*-*-* 00/12:00:00` and fires it twice a day.
Checked: `ssh mint "systemd-analyze calendar --iterations=3 '*-*-* 00/12:00:00'"`.
Result: systemd 255; next elapses 2026-11-11 00:00, 12:00, 2026-11-12 00:00.
Verdict: holds

## Premise 5
Assumption: launchd on the mac takes an array of dictionaries for StartCalendarInterval and starts a missed calendar job on wake.
Checked: `ssh mac "man launchd.plist | col -b | grep -A12 StartCalendarInterval"` (macOS 27.2).
Result: "<dictionary of integers or array of dictionaries of integers> ... Multiple dictionaries may be specified in an array ... launchd will start the job the next time the computer wakes up ... coalesced into one event".
Verdict: holds
