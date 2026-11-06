# Stage 3 demo — 2026-11-05-gui-update-bridges-restart-sub-01-restart-policy-plan

Environment: evaluator on the Linux workstation, repo /home/user/dev/containers/nice-dns, branch restart-policy, HEAD 8244acb, 2026-11-05 ~20:00Z. Read-only route: no ssh to mint or mac, no `tests/run.sh live ...`, no target.sh ops. Receipt verified: /home/user/.local/state/nice-dns-tests/receipts/container-faults/20261105T190652Z-fbcf098f (product b7cc6f3; `git diff --stat b7cc6f3 HEAD` touches only docs/workflows/dns-lifecycle.md, health/README.md and two proof claim files, so the receipt still covers the product at HEAD). A separate plan-scope run started by the executor (`tests/run.sh stage controller ...`) was running throughout; it was not touched.

Gate command checks, run from the repo root:
- `! grep -l 'HealthOnFailure=restart' deb/quadlet/*.container && for f in deb/quadlet/*.container; do grep -q '^RestartSteps=' "$f" && grep -q '^RestartMaxDelaySec=' "$f" || exit 1; done` -> exit 0. All four quadlets (pi-hole, unbound, tor-haproxy, tor-socat): `HealthOnFailure=none`, `Restart=on-failure`, `RestartSec=3s`, `RestartSteps=5`, `RestartMaxDelaySec=300s`.
- `bash tests/run.sh receipt container-faults` -> exit 0: `receipt=container-faults cells=2 scenarios=5 errors=0 limits=1 reused=0`.
- `! grep -rn 'HealthOnFailure=restart' README.md health/README.md docs/workflows/dns-lifecycle.md CLAUDE.md` -> exit 0, no match.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: a receipt per platform shows a frozen Pi-hole restarted, a paused Unbound unpaused (Linux), a crash loop held with one escalation and back-off visible (Linux), and a stopped container repaired (macOS), each without human action.
Verdict: holds
Evidence:
- `bash tests/run.sh receipt container-faults` -> exit 0, receipt.tsv names two cells, both `observed`, adapter `real`: `linux haproxy standard mint` and `macos haproxy standard mac`. Five scenarios, all `pass`: CF-PIHOLE (mac), CF-STOP (mac), CF-PIHOLE (mint), CF-PAUSE (mint), CF-CRASH (mint).
- `sha256sum cells/*/*.tsv` matches every hash in receipt.tsv (f2492e72..., d5e9ae1c..., 079f3f2d..., b2ea4a4d..., 773c7d81...).
- Frozen Pi-hole, Linux (cells/linux-haproxy-standard/fault-pihole.tsv): injected 1793906448; `fresh_during_fault timeout` (the fault was real); journal `pi-hole requested restart` at +155 s, `acknowledged pi-hole restarted` 11 s later with a new container id, `ready observed working 30s after the acknowledgement`; `generation_changed yes`; fresh name `NOERROR`. In the run dir (container-faults/mint/fault-before.tsv) Unbound and the proxy keep their 19:10 start times, so Pi-hole restarted alone.
- Frozen Pi-hole, macOS (cells/macos-haproxy-standard/fault-pihole.tsv): `fresh_during_fault timeout`; journal `requested` at +173 s, `acknowledged` 9 s later (start 19:08:02Z -> 19:21:35Z), `ready` 32 s after; fresh name `NOERROR`. Tick log: `action=restart-component target=pi-hole result=acknowledged ... reason=Pi-hole failed 3 checks in a row: local-service: dig timed out at 172.31.240.250#53 (pi.hole)`.
- Paused Unbound, Linux (fault-pause.tsv): `fresh_during_fault timeout`; journal `repair of containers-paused: unpause unbound (exit 0)` at +90 s, `acknowledged unbound running`, `ready` 60 s after; `generation_changed no` (unpaused, not restarted); fresh name `NOERROR`.
- Crash loop, Linux (fault-crash.tsv): tor-haproxy killed 4 times, every 75 s; `nrestarts_before 0`, `nrestarts_after 4`; `delays_s 3 8 19 47`, `backoff_growing yes`; `crash_escalations 1` with journal `controller escalated crash-loop: tor-haproxy restarted 3 times in 600 s (restarts 3); the controller adds no restart; first escalation of this loop`; `controller_proxy_restarts 0`; `unit_state_after active`; fresh name `NOERROR`.
- Stopped container, macOS (fault-stop.tsv): `fresh_during_fault timeout`; journal `runtime requested repair of containers-missing: exit 0` at +31 s, `acknowledged the runtime answers and the stack runs`, `ready` 52 s after; fresh name `NOERROR`. The run dir names the container: ops.log `stop-container --component unbound`; tick `repair-runtime target=containers-missing ... containers-missing: unbound (running: tor-haproxy pi-hole)`.
- No human action: each recovery is a controller journal entry (requested -> acknowledged -> ready) between the injection and the final fresh-name probe. results.tsv shows t_01..t_09 all `pass`.

## Outcome 2
> The macOS per-container restart keeps the container's address and the chain resolves → Unbound and Pi-hole restart alone on macOS from now on; BL-038 is updated.
Verdict: does not hold (the other branch; Outcome 3 holds instead, so this is not Blocking)
Evidence:
- proof/.../3.2/demo.md: `container stop unbound` then `container start unbound` with the controller quiesced. Unbound came back at `172.31.240.253/29`, not `.251`: `address_kept unbound no (172.31.240.253)`, `fresh_name unbound timeout after_s 314`, `qualified no`. Repaired by `nice-dns restart` (stack kickstart).
- The Pi-hole leg was not run. The reason is given: the Unbound result already shows that the allocator moves addresses.

## Outcome 3
> It does not → the kickstart stays, the finding is recorded on BL-038, nothing else changes.
Verdict: holds
Evidence:
- The kickstart stays, per the receipt's run artifacts. On the mac, after the Pi-hole fault, all three containers carry one start time (container-faults/mac/fault-before.tsv: pi-hole 19:21:35Z, unbound 19:21:35Z, tor-haproxy 19:21:36Z). After the Unbound stop they all share a new one (fault-after.tsv: 19:49:13Z/19:49:13Z/19:49:14Z). So each macOS repair rebuilt the whole stack. Each was followed by `fresh proxy ... select cloudflare-exit`.
- BL-038 (/mnt/vault/Portfolio/containers/nice-dns/backlog.md:231) has `Progress 2026-11-05 (restart-policy plan, Task 3.2)`. It records the move to .253, the missing `--ip` (apple/container#282), the 314 s outage, "Unbound and Pi-hole restarts on macOS keep the stack kickstart", and that the item stays open. It cites the 3.2 demo.
- The docs agree. health/README.md says Unbound "on macOS the restart rebuilds the stack" and Pi-hole "rebuild the stack on macOS. A single container restarted there comes back at another address". WF-DNS-002 step 6 says "macOS rebuilds the stack, since a single container restarted there comes back at another address (BL-038)". The baseline says "the stack kickstart on macOS" and, for Unbound, "on macOS it rebuilds the stack (BL-038)".
- Nothing else changes: from the user's side, no doc or backlog text claims a macOS per-container restart. The source was not inspected (out of scope for this evaluator).

## Outcome 4
> A target is unreachable → that check is `[~]` with the reason; the plan cannot close as completed without a `Blocked-accepted` line.
Verdict: holds (not triggered: no target was unreachable)
Evidence:
- receipt.tsv: both cells `observed`, `errors=0`. No `[~]` and no unreachable target. Both mint and mac have ops.tsv and snapshot.tsv in the run dir.
- The one `limit` line is `mac-gui-context scope=BL-052 the macOS install ran in the GUI context (launchctl asuser), not from plain ssh or Terminal`. That is a declared scope limit. It is not an unreachable target.
- Platform-inapplicable steps are recorded with reasons, not silently skipped: mint `cf_stop.not-run.tsv` ("Linux restarts a stopped unit's container through the runtime repair already proven by command-recovery CR-PROXY"); mac `cf_crash.not-run.tsv` ("Apple container restarts nothing by itself...") and `cf_pause.not-run.tsv` ("Apple container has no pause"). These match the outcome's "(Linux)" and "(macOS)" scoping.
- So no `Blocked-accepted` line is needed.

## Findings

Blocking: none.

Material: none.

Minor:
1. The macOS CF-STOP receipt artifact (cells/macos-haproxy-standard/fault-stop.tsv) does not name the stopped container. Linux fault-crash.tsv has a `component` line; this file does not. The docs say "a stopped Unbound". Confirming that needs the run dir (container-faults/mac/ops.log), which is not in the receipt.
2. The macOS CF-PIHOLE journal line reads `pi-hole restarted`, but the whole stack was rebuilt (all three start times moved). The receipt cell alone does not show that the kickstart (Outcome 3) is what ran. Only the run-dir start times and the following `fresh proxy` route switch show it.
3. The 3.2 qualification tested only Unbound. Applying the result to Pi-hole is an inference, though a stated and plausible one (same vmnet allocator, hardcoded .250/.251).
4. The receipt's product sha is b7cc6f3, not HEAD 8244acb. The later commits touch only docs and proof claim files, so this does not make the receipt stale. Still, the owner has to check that themselves.

_Note (executor, Stage 3 gate round 1): the 3.2 evidence cited above moved to docs/qualification.md, section "macOS per-container restart (2026-11-05, not qualified)" (5090f6d); its content is unchanged._
