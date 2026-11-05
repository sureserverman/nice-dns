# Stage 1 demo — 2026-11-05-gui-update-bridges-restart-sub-01-restart-policy-plan

Environment: (see below)

Evaluator: skipped — goal command `! grep -l 'HealthOnFailure=restart' deb/quadlet/*.container && for f in deb/quadlet/*.container; do grep -q '^RestartSteps=' "$f" && grep -q '^RestartMaxDelaySec=' "$f" || exit 1; done` at 4679d05

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: three `container:<name>` records per pass, one each for pi-hole, unbound and the proxy, with state, health, restart count and exit code in the reason.
Verdict: holds
Decided by: `bash tests/run.sh stage controller && bash tests/run.sh integration installers-persistence && shellcheck lib/health.sh lib/platform/linux.sh lib/platform/macos.sh` at 4679d05
Evidence:
unit/observations t_container_running_records_follow_runtime_for_each_proxy_variant: for linux and macos, haproxy and socat, records runtime container:pi-hole container:unbound container:tor-<v> in that order, each `running: health H restarts N`; the exit code is in the reason of every non-running record (t_container_exited_reports_its_exit_code_and_restarts).
The stage-scope command ran in full at 12f4eea (243 cases, run 20261105T142438Z-f1daece0: every group green but unit/harness-contracts, 67 of 68, the citation pin); round 1 then re-ran at fix-scope at 4679d05: unit/harness-contracts 68/68, unit/observations 47/47, integration/controller-interaction 12/12, integration/recovery-actions 40/40, integration/installers-persistence 3/3, shellcheck rc 0 (the untouched groups unit/state-policy 52/52 and unit/receipt-verifier 32/32 stand from 12f4eea).

## Outcome 2
> The runtime cannot inspect a container → that record is indeterminate with the runtime's error, and nothing acts on it.
Verdict: holds
Decided by: `bash tests/run.sh stage controller && bash tests/run.sh integration installers-persistence && shellcheck lib/health.sh lib/platform/linux.sh lib/platform/macos.sh` at 4679d05
Evidence:
t_container_inspect_failure_is_indeterminate: the reason matches `^unknown: the state of unbound is not readable .*no such object.* restarts [?]$` (podman's error), and an unreadable count matches `.*Failed to connect to bus.*` (the manager's). No policy rule reads container:<name> records at Stage 1 (lib/policy.sh unchanged; unit/state-policy 52/52).
The stage-scope command ran in full at 12f4eea (243 cases, run 20261105T142438Z-f1daece0: every group green but unit/harness-contracts, 67 of 68, the citation pin); round 1 then re-ran at fix-scope at 4679d05: unit/harness-contracts 68/68, unit/observations 47/47, integration/controller-interaction 12/12, integration/recovery-actions 40/40, integration/installers-persistence 3/3, shellcheck rc 0 (the untouched groups unit/state-policy 52/52 and unit/receipt-verifier 32/32 stand from 12f4eea).

## Outcome 3
> A container is paused → unhealthy with reason `paused`.
Verdict: holds
Decided by: `bash tests/run.sh stage controller && bash tests/run.sh integration installers-persistence && shellcheck lib/health.sh lib/platform/linux.sh lib/platform/macos.sh` at 4679d05
Evidence:
t_container_paused_is_unhealthy: `paused restarts 1` for a paused proxy, verdict unhealthy.
The stage-scope command ran in full at 12f4eea (243 cases, run 20261105T142438Z-f1daece0: every group green but unit/harness-contracts, 67 of 68, the citation pin); round 1 then re-ran at fix-scope at 4679d05: unit/harness-contracts 68/68, unit/observations 47/47, integration/controller-interaction 12/12, integration/recovery-actions 40/40, integration/installers-persistence 3/3, shellcheck rc 0 (the untouched groups unit/state-policy 52/52 and unit/receipt-verifier 32/32 stand from 12f4eea).

## Outcome 4
> A container exited → unhealthy with reason `exited: rc N`.
Verdict: holds
Decided by: `bash tests/run.sh stage controller && bash tests/run.sh integration installers-persistence && shellcheck lib/health.sh lib/platform/linux.sh lib/platform/macos.sh` at 4679d05
Evidence:
t_container_exited_reports_its_exit_code_and_restarts: `exited: rc 134 restarts 4` (linux), `exited: rc ? restarts 2` (macos, which records no exit code: premise 2). States on the way up or down read `transient: state S`, indeterminate.
The stage-scope command ran in full at 12f4eea (243 cases, run 20261105T142438Z-f1daece0: every group green but unit/harness-contracts, 67 of 68, the citation pin); round 1 then re-ran at fix-scope at 4679d05: unit/harness-contracts 68/68, unit/observations 47/47, integration/controller-interaction 12/12, integration/recovery-actions 40/40, integration/installers-persistence 3/3, shellcheck rc 0 (the untouched groups unit/state-policy 52/52 and unit/receipt-verifier 32/32 stand from 12f4eea).

## Outcome 5
> podman's own health check says unhealthy → unhealthy with reason `unhealthy: <its last output>`; macOS, which has no health check, reports `health none`.
Verdict: holds
Decided by: `bash tests/run.sh stage controller && bash tests/run.sh integration installers-persistence && shellcheck lib/health.sh lib/platform/linux.sh lib/platform/macos.sh` at 4679d05
Evidence:
t_container_podman_unhealthy_carries_the_last_check_output: `unhealthy: dig: couldn't get address for 127.0.0.1#5335 restarts 2`; t_container_macos_health_is_none: `running: health none restarts 3`.
The stage-scope command ran in full at 12f4eea (243 cases, run 20261105T142438Z-f1daece0: every group green but unit/harness-contracts, 67 of 68, the citation pin); round 1 then re-ran at fix-scope at 4679d05: unit/harness-contracts 68/68, unit/observations 47/47, integration/controller-interaction 12/12, integration/recovery-actions 40/40, integration/installers-persistence 3/3, shellcheck rc 0 (the untouched groups unit/state-policy 52/52 and unit/receipt-verifier 32/32 stand from 12f4eea).

## Outcome 6
> A process keeps crashing on Linux → the unit's own back-off stretches from 3 s to 300 s between starts instead of every 3 s, and podman no longer restarts Pi-hole on its health check.
Verdict: holds
Decided by: `! grep -l 'HealthOnFailure=restart' deb/quadlet/*.container && for f in deb/quadlet/*.container; do grep -q '^RestartSteps=' "$f" && grep -q '^RestartMaxDelaySec=' "$f" || exit 1; done` at 4679d05
Evidence:
The (goal) command exits 0 at 4679d05; integration/installers-persistence t_quadlets_back_off_and_only_the_controller_restarts_on_health renders all four units with quadlet -dryrun: RestartSec=3s, RestartSteps=5, RestartMaxDelaySec=300s, `--health-on-failure none`. Synthetic as the plan's Evidence claim says; the live back-off is Stage 3 Task 3.3.

