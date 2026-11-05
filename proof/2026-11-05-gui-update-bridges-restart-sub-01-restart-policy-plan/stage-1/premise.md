# Stage 1 premises — 2026-11-05-gui-update-bridges-restart-sub-01-restart-policy-plan

Goal: The controller, and later the status readers, see each container's state, health and restart count every minute, and the units stop restarting on health or every 3 s.
Risk: LOW — the fields already appear in the failure dump; the quadlet keys are documented systemd 254 options rendered by the dry-run test.

Outcomes:
- Works: three `container:<name>` records per pass, one each for pi-hole, unbound and the proxy, with state, health, restart count and exit code in the reason.
- The runtime cannot inspect a container → that record is indeterminate with the runtime's error, and nothing acts on it.
- A container is paused → unhealthy with reason `paused`.
- A container exited → unhealthy with reason `exited: rc N`.
- podman's own health check says unhealthy → unhealthy with reason `unhealthy: <its last output>`; macOS, which has no health check, reports `health none`.
- A process keeps crashing on Linux → the unit's own back-off stretches from 3 s to 300 s between starts instead of every 3 s, and podman no longer restarts Pi-hole on its health check.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: podman inspect on a real Linux host gives state, health, restart count and exit code for each stack container.
Checked: 2026-11-05 on mint (podman 5.8.1)
Result: `ssh mint "podman inspect -f '{{.Name}} {{.State.Status}} {{if .State.Healthcheck}}{{.State.Healthcheck.Status}}{{else}}none{{end}} {{.RestartCount}} {{.State.ExitCode}}' pi-hole unbound tor-haproxy"` printed `pi-hole running healthy 0 0`, `unbound running healthy 0 0`, `tor-haproxy running healthy 0 0`
Verdict: holds

## Premise 2
Assumption: Apple container inspect gives the container state, with no health check and no restart count (so the adapter reports health none and keeps its own restart counter).
Checked: 2026-11-05 on mac (container CLI 1.6.1, macOS 27.2)
Result: `ssh mac 'container inspect unbound'` top-level keys are configuration, id, status; status has state "running", startedDate, networks. No health, no restart count, and no exit code field.
Verdict: holds for state, health none and restart count. The exit code is absent, so the macOS adapter reports `?` for it; an exited container on macOS reads `exited: rc ?`. The Outcome's reason still names the state; recorded as a deviation in the gate report.

## Premise 3
Assumption: the Linux hosts run systemd 254 or newer, so RestartSteps= and RestartMaxDelaySec= take effect; the units today restart every 3 s.
Checked: 2026-11-05 on mint and this laptop
Result: `ssh mint systemctl --version` systemd 255 (255.4-1ubuntu8.17); laptop systemd 255; `ssh mint systemctl --user show -p RestartUSec -p NRestarts pi-hole.service` RestartUSec=3s NRestarts=0
Verdict: holds
