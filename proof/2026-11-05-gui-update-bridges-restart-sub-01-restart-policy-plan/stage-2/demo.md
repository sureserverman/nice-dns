# Stage 2 demo — 2026-11-05-gui-update-bridges-restart-sub-01-restart-policy-plan

Environment: fixtures on this host (tests/run.sh under a systemd user unit); the live proof on mint and mac is Stage 3 (plan: Task 3.1, 3.3).

Evaluator: skipped — goal command `! grep -l 'HealthOnFailure=restart' deb/quadlet/*.container && for f in deb/quadlet/*.container; do grep -q '^RestartSteps=' "$f" && grep -q '^RestartMaxDelaySec=' "$f" || exit 1; done` at 03cf9e1

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: Pi-hole fails its check (or `local-service`) three passes in a row → restarted alone on Linux, journaled requested, acknowledged, ready; two restarts, then one every 30 minutes; a healthy reading clears the streak.
Verdict: holds
Decided by: `bash tests/run.sh stage controller && bash tests/run.sh integration installers-persistence && shellcheck lib/policy.sh lib/recovery.sh lib/state.sh health/nice-dns-health` at 03cf9e1
Evidence:
unit/state-policy t_pihole_failing_restarts_it_on_the_third_pass: for container:pi-hole and for local-service alone, no-op, no-op, then restart-component pi-hole, the Tor ladder not charged. t_pihole_retries_every_half_hour_after_two_restarts: two restarts, the third and fourth no sooner than 1800 s after the last. t_pihole_healthy_reading_clears_and_indeterminate_holds: a healthy reading clears the streak. integration/recovery-actions t_pihole_restart_journals_requested_acknowledged_ready: linux runs only `systemctl --user restart pi-hole.service` (one systemctl call), journal pi-hole requested, acknowledged, then ready once local-service answers; macOS uses the stack kickstart (Task 3.2 qualifies a single-container restart).
The stage-scope command ran in full at 03cf9e1: run 20261105T165711Z-c52fa930 277/277 (unit/harness-contracts 68, unit/observations 48, unit/state-policy 71, integration/recovery-actions 45, integration/controller-interaction 13, unit/receipt-verifier 32), then integration/installers-persistence 3/3 (run 20261105T170824Z-d85d3dac) and shellcheck rc 0.


## Outcome 2
> A container is paused for two passes → unpaused on Linux (journaled); on macOS, which has no pause, the record escalates with the reason and nothing is restarted.
Verdict: holds
Decided by: `bash tests/run.sh stage controller && bash tests/run.sh integration installers-persistence && shellcheck lib/policy.sh lib/recovery.sh lib/state.sh health/nice-dns-health` at 03cf9e1
Evidence:
unit/state-policy t_a_paused_container_is_unpaused_after_two_passes: one paused pass is no-op, the second decides repair-runtime containers-paused naming unbound. integration/recovery-actions t_a_paused_container_is_unpaused_and_acknowledged: the fake podman records `unpause unbound`, journal runtime requested, acknowledged (`containers-paused: unbound running`), no unit started or restarted; macOS repair_runtime containers-paused exits 3, journal `runtime unsupported`, nothing run. unit/state-policy t_a_paused_container_escalates_where_no_unpause_exists: with the macOS repair list the decision is escalate `paused: tor-haproxy`, recovery_at unchanged. Round 1 capped the unpause (t_the_unpause_is_capped_and_never_starves_the_other_rules). The premise (podman pause/unpause works rootless) was checked live on mint (stage-2/premise.md).
The stage-scope command ran in full at 03cf9e1: run 20261105T165711Z-c52fa930 277/277 (unit/harness-contracts 68, unit/observations 48, unit/state-policy 71, integration/recovery-actions 45, integration/controller-interaction 13, unit/receipt-verifier 32), then integration/installers-persistence 3/3 (run 20261105T170824Z-d85d3dac) and shellcheck rc 0.


## Outcome 3
> A container's restart count rises → the controller starts its cooldown from that moment and issues no restart of its own; three rises within 10 minutes → one `crash-loop: <name>` escalation with one failure dump, repeated no more often than every 30 minutes; a count stable for 10 minutes clears it.
Verdict: holds
Decided by: `bash tests/run.sh stage controller && bash tests/run.sh integration installers-persistence && shellcheck lib/policy.sh lib/recovery.sh lib/state.sh health/nice-dns-health` at 03cf9e1
Evidence:
unit/state-policy t_a_restart_count_rise_holds_a_due_pihole_restart: a rise sets recovery_at to that pass and holds a due Pi-hole restart until the rise is 600 s old. t_three_rises_escalate_once_as_a_crash_loop: the third rise escalates `crash-loop: tor-haproxy ...; first escalation of this loop`, none over the next 24 rises, one again past 1800 s. t_a_crash_loop_never_gets_a_controller_restart: no tor, proxy or stack restart and no start by name during the loop. t_a_stable_count_clears_the_loop_and_a_fall_is_a_new_baseline. integration/controller-interaction t_a_crash_loop_is_escalated_once_with_one_dump_by_real_ticks: real CLI ticks, one escalation on the third rise, one failure-*.log, no unit started. integration/bridge-lifecycle t_a_crash_looping_proxy_is_not_restarted_to_adopt_a_set (round 1; ran at fix-scope 19/19 before 03cf9e1, its files unchanged since).
The stage-scope command ran in full at 03cf9e1: run 20261105T165711Z-c52fa930 277/277 (unit/harness-contracts 68, unit/observations 48, unit/state-policy 71, integration/recovery-actions 45, integration/controller-interaction 13, unit/receipt-verifier 32), then integration/installers-persistence 3/3 (run 20261105T170824Z-d85d3dac) and shellcheck rc 0.


## Outcome 4
> Startup allowance or cooldown → the restart waits; the journal says why.
Verdict: holds
Decided by: `bash tests/run.sh stage controller && bash tests/run.sh integration installers-persistence && shellcheck lib/policy.sh lib/recovery.sh lib/state.sh health/nice-dns-health` at 03cf9e1
Evidence:
t_pihole_startup_and_cooldown_hold_the_restart: inside the startup allowance and the cooldown no restart, reason `Pi-hole failed N checks in a row, inside the startup allowance or cooldown`. t_a_paused_container_waits_out_the_cooldown: reason `paused: pi-hole, inside the recovery cooldown`. t_a_crash_loop_never_gets_a_controller_restart: the held passes say `restart count rose` or `restarting on its own`. The tick's reason row is journaled by the CLI (lib/recovery.sh nd_recovery_tick).
The stage-scope command ran in full at 03cf9e1: run 20261105T165711Z-c52fa930 277/277 (unit/harness-contracts 68, unit/observations 48, unit/state-policy 71, integration/recovery-actions 45, integration/controller-interaction 13, unit/receipt-verifier 32), then integration/installers-persistence 3/3 (run 20261105T170824Z-d85d3dac) and shellcheck rc 0.


## Outcome 5
> The check could not run → indeterminate, no action.
Verdict: holds
Decided by: `bash tests/run.sh stage controller && bash tests/run.sh integration installers-persistence && shellcheck lib/policy.sh lib/recovery.sh lib/state.sh health/nice-dns-health` at 03cf9e1
Evidence:
t_pihole_healthy_reading_clears_and_indeterminate_holds: container:pi-hole and local-service indeterminate leave pihole_fail at 2 and the action no-op; a pass with no record changes nothing. Container records read indeterminate are neither paused nor running (lib/policy.sh, cobs stays '-'), so they neither count nor clear a paused streak; an unreadable restart count ("restarts ?") is no rise (t_policy_is_pure_through_a_crash_loop and the unit/observations indeterminate cases).
The stage-scope command ran in full at 03cf9e1: run 20261105T165711Z-c52fa930 277/277 (unit/harness-contracts 68, unit/observations 48, unit/state-policy 71, integration/recovery-actions 45, integration/controller-interaction 13, unit/receipt-verifier 32), then integration/installers-persistence 3/3 (run 20261105T170824Z-d85d3dac) and shellcheck rc 0.

