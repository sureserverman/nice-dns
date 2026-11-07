# Stage 1 premises — 2026-11-05-gui-update-bridges-restart-sub-04-bridges-toggle-plan

Goal: A person switches bridges off or on with one command and every part of the stack honours it at the next proxy start, with no refresh fighting the choice.
Risk: LOW — one file read in five places, each with a fixture.

Outcomes:
- Works: `nice-dns bridges off` writes the mode and prints what the ISP will now see; `nice-dns bridges status` prints `off` and the pool size; the proxy's next start runs Tor direct; refreshes journal `skipped`.
- `nice-dns bridges on` → the last good set is used again at the next start; refreshes resume.
- Not installed → the usual not-installed message, exit 1.
- A bad argument → usage, exit 2.
- The mode file cannot be written → the error names the path; nothing else changes.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: the pinned proxy image honours TOR_BRIDGES (on default, off direct, anything else refused).
Checked: ssh mint 'podman exec tor-socat sh -c "grep -n TOR_BRIDGES /bin/start.sh"' (2026-11-07; image sha256:4feee064, socat v2.12)
Result: start.sh:39 TOR_BRIDGES="${TOR_BRIDGES:-on}"; :42 refuses other values; :44 BRIDGES_OFF when off.
Verdict: holds

## Premise 2
Assumption: a quadlet's optional `EnvironmentFile=-%h/.config/nice-dns/bridges-mode.env` (after bridges.env) renders to an optional mode file (Research Summary: systemd.exec(5) `-` prefix).
Checked: on mint (podman 5.8.1, systemd 255), a scratch [Container] unit with both lines through `QUADLET_UNIT_DIRS=$d /usr/libexec/podman/quadlet -dryrun -user` (2026-11-07).
Result: ExecStart=... --env-file %h/.config/nice-dns/bridges.env --env-file /tmp/tmp.W8N7SF7Xad/-%h/.config/nice-dns/bridges-mode.env -- quadlet's [Container] EnvironmentFile= is podman --env-file, takes no `-` prefix, and resolves `-%h/...` as a path relative to the unit dir. Podman would refuse to start the proxy (file missing) on every host, mode file or not.
Verdict: false
Nearby shape checked (not adopted; owner's call): [Service] EnvironmentFile=-%h/.config/nice-dns/bridges-mode.env plus [Container] PodmanArgs=--env TOR_BRIDGES renders `--env TOR_BRIDGES`; on mint `TOR_BRIDGES=off podman run --env TOR_BRIDGES alpine` prints [off] and with the variable unset it stays unset (image default on).
Resolution: owner, 2026-11-07: "Service env + passthrough (Recommended)" (sub-plan OD-6); Task 1.2 amended to the nearby shape checked above.
