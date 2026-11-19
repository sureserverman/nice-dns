# Plan demo — 2026-11-18-backlog-sweep-sub-02-controller-bridges-plan

Environment: (see below)

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

# Stage 1

## Outcome 1
> Works: a refresh that must restart the proxy does so under the controller's lock, and the journal shows the request, the acknowledgement and the time, as for any restart
Verdict: not shown here
Evidence:
Not caused on mint. An adoption restart is due only when the running Tor still uses a bridge it judged weak (`listed=1`, at least 20 uses, under 90% success) and a set is pending. mint's bridge counters are all healthy (27/27, 38/38 successes, `listed=0`).
Both real refreshes run here (08:43:38 and 08:45:06 UTC, `systemctl --user start nice-dns-health-bridges.service` with bridges on) ended `result changed / dropped 0 / adopted -`. The journal said `bridges changed 1f0fa05855c3160f -> c1f634d01682fd70 (7 bridges); adopted at the proxy's next start, no restart`.
For comparison, the journal's restart rows on this host have the shape the Outcome expects. `nice-dns bridges on` gave `bridges mode-change on`, then `service requested proxy restart for tor-socat; container before: ...`, then `service acknowledged tor-socat restarted: ...`, all under the id `bridges-on-1795077638`, with epoch times.
To show it: a bridges-on host whose running Tor carries a bridge with at least 20 uses and under 90% stream success.


## Outcome 2
> Works: when the controller is busy, the refresh restarts nothing; the new set waits and the proxy takes it at its next start
Verdict: not shown here
Evidence:
Needs an adoption to be due (see Outcome 1) at the same moment the controller holds its state lock for a long action. Neither can be arranged on mint by the user's route.
To show it: a bridges-on host with a weak running bridge, and a refresh that lands while the minute pass is running a restart.


## Outcome 3
> Works: `nice-dns bridges off` during a refresh is respected: the refresh restarts nothing afterwards
Verdict: holds
Evidence:
On mint, 08:45:06 UTC, with bridges on (turned on by me at 08:40:37 with `nice-dns bridges on`, rc 0 after 153 s):
- `systemctl --user start --no-block nice-dns-health-bridges.service`. 15 s later the unit was `activating` (bridge-eval running).
- 08:45:21 `nice-dns bridges off` printed "Bridges are off; the proxy restarted and DNS is answering." rc 0 after 15 s.
- The refresh ended at 08:46:08 with `Result=success`, status 0.
- Journal rows from that window:
  `1795077921 bridges-off-1795077921 bridges mode-change off`
  `1795077922 ... service requested proxy restart for tor-socat`
  `1795077924 ... service acknowledged tor-socat restarted: b95cc2cc...`
  `1795077966 ... service ready observed working 41s after the acknowledgement; Unbound resolves over its route`
  `1795077967 br-1795077967 bridges changed c1f634d01682fd70 -> e48dc13aeb6742f3 (7 bridges); adopted at the proxy's next start, no restart`
- Afterwards `podman ps` still showed the tor-socat started by `bridges off` (created 08:45:23, "Up 46 seconds"). `dig @127.0.0.1 example.com` answered.
The refresh restarted nothing after the switch. Caveat: no adoption was due in this run (dropped 0). So the guard that stops a due adoption after `off` was not itself exercised. The refresh still wrote a new `bridges.env` after `off`. The docs say the set is kept while off, so this is harmless.


## Outcome 4
> Works: a bridge judged weak once is left out of the new set at once, but is remembered for 30 days only when the next refresh judges it weak again
Verdict: not shown here
Evidence:
Both real refreshes on mint reported `dropped 0`. No bridge in mint's Tor state is weak, and no `bridges.weak.once` or `bridges.weak` file was written.
To show it: a bridges-on host where Tor has used one bridge at least 20 times at under 90% success, then two refreshes on separate days.


## Outcome 5
> Works: when dropping weak bridges would leave fewer than 3, the refresh keeps the set and reports `weak_blocked` with the count
Verdict: not shown here
Evidence:
Needs enough weak bridges that dropping them leaves fewer than 3. mint has none (dropped 0 on both refreshes).
To show it: a bridges-on host whose set holds 5 or more weak bridges, or a set of 3 with one weak.


# Stage 2

## Outcome 6
> Works: a controller that meets a state key it does not know keeps running and says so once in the journal
Verdict: holds
Evidence:
On mint, 08:32:29 UTC, between minute passes, I appended one well-formed row `future_key<TAB>some-value-from-a-newer-bundle` to `~/.local/state/nice-dns/controller/state.tsv`. This is the file a rollback would leave behind.
- `nice-dns status --tsv` with the row present: `controller verdict OK`, `route selected cloudflare-exit 12943`, rc 0.
- The next timer pass (08:33) gave `Result=success`, status 0. The journal recorded once:
  `1795077184 nd-1795077184-12944 controller state-skipped unknown state keys skipped (written by a newer bundle?): future_key`
  The same pass went on to act normally: `route:cloudflare-onion requested / acknowledged / ready`.
- The second pass (08:34) gave `Result=success`. No second `state-skipped` row was written. `state.tsv` no longer held `future_key`.
- `nice-dns status --tsv` then listed `recent 1795077184 controller state-skipped`, `controller verdict OK`, `stale no`.


## Outcome 7
> Works: a proxy on warm onion circuits keeps the onion route when the query for its generation fails or times out
Verdict: not shown here
Evidence:
The user's route is Unbound starting (its quadlet runs route-start) while the podman query fails. On a live host that cannot be arranged without breaking podman for Unbound's own start.
Supplementary only, not the user's route: I ran the documented `nice-dns-health route-start` by hand on mint at 08:40, on the warm onion route (generation 12944, proxy_gen 29c7ab1f3316533c). Three runs:
- With no sha256sum/shasum on PATH: `result kept`, `route cloudflare-onion`, `detail the proxy could not be asked (tor-socat: its generation cannot be hashed): its onion circuits may be warm; kept until the controller's pass decides`, rc 0.
- With `XDG_RUNTIME_DIR=/nonexistent` (podman cannot load its configuration): `result kept`, `detail the proxy could not be asked (tor-socat: Failed to obtain podman configuration: lstat /nonexistent: no such file or directory): ...kept until the controller's pass decides`, rc 0.
- Normal: `result kept`, `detail the proxy is not fresh (generation 29c7ab1f3316533c, ...): its onion circuits are warm; kept`.
After all three, `state.tsv` still said `route cloudflare-onion`, and the files in `unbound-route/` were unchanged (08:33 mtimes).
To show it by the route: a disposable host where podman's query can be made to fail or hang during Unbound's ExecStartPre.


## Outcome 8
> Works: the journal names the missing tool, the unit that is missing, and a visibility timeout as what they are
Verdict: not shown here
Evidence:
These journal reasons come from a restart's acknowledgement path. Causing them needs one of three faults: an Unbound image without dig, a removed quadlet unit, or a container that never becomes visible. None of these can be caused on mint without breaking its images or units.
The one related thing seen: no journal row written in this session carried podman's storage-driver warning. The warning appeared on podman's stderr in my ssh output, but in no `recovery.tsv` row.
To show it: a disposable host with a rebuilt Unbound image lacking dig, or with one quadlet removed, followed by a restart the controller decides.


## Outcome 9
> Works: on mint, reinstalled from the branch, the controller's verdict is OK and a bridge refresh started by hand ends inside its limit
Verdict: holds
Evidence:
mint runs generation `20261119T082542Z-a8c1151a5cdb`, branch `sweep-controller`, variant socat.
- `ssh mint '~/.local/bin/nice-dns status --tsv'` at 08:30 and again at 08:47: `controller verdict OK`, `stale no`, `schedule loaded`. The gate's grep for `^controller<TAB>verdict<TAB>OK` matched.
- Unit limit: `TimeoutStartUSec=12min 30s` (750 s).
- Refresh by hand with bridges off (mint's normal mode), 08:39:22: `systemctl --user start nice-dns-health-bridges.service` rc 0 after 0 s. Output `result skipped`, `detail bridges off`, `Result=success`. Journal row `bridges skipped bridges off`.
- Refresh by hand with bridges on, 08:43:38: rc 0 after 75 s. Start 08:43:38, exit 08:44:53, `Result=success`. bridge-eval found "57 reachable / 65 total", pruned 2, and wrote 7 bridges. Output `result changed / dropped 0 / adopted -`.
- The second refresh (Outcome 3) took 62 s. Both ended far inside 750 s.


## Outcome 10
> A host with neither `sha256sum` nor `shasum` → the controller and the installer say the hash is unknown and stop that step; no two bridge sets compare equal by accident
Verdict: not shown here
Evidence:
Executor note: the evaluator wrote "holds (controller); not shown here (installer)". The Outcome names both, so its one verdict is not shown here; the controller half held, as below.
On mint I built a PATH with every tool from /usr/local/bin, /usr/bin, /bin, /usr/sbin and /sbin except sha256sum and shasum. `command -v` found neither on it.
- `PATH=<that> nice-dns-health observe` (read-only): `obs proxy indeterminate 128 unknown: no sha256sum or shasum to hash the generation`. Every other row stayed healthy.
- With bridges on, 08:43:22: `PATH=<that> nice-dns-health bridges-refresh` printed `result not-applied`, rc 1 after 0 s. Journal row: `br-1795077802 bridges not-applied the running bridge set cannot be hashed (no sha256 tool answered); nothing is evaluated`. The hashes of `bridges.env` and `bridge-pool.tsv` were unchanged.
- `nice-dns-health route-start` with that PATH said the generation "cannot be hashed" and kept the route (Outcome 7).
Installer half: not run. Installs on mint are forbidden in this session and the laptop must not be touched. To show it: a disposable host without sha256sum/shasum running install-deb.sh.


## Outcome 11
> A state file with a bad value for a known key → refused as today, with the key named
Verdict: holds
Evidence:
On mint, 08:34:20 UTC, I changed `outage_restarts 0` to `outage_restarts abc` in `state.tsv`.
- Each timer pass from 08:35 to 08:38 was refused. The systemd journal said `state line 8: bad value for outage_restarts`, then `Main process exited, code=exited, status=2/INVALIDARGUMENT`. Nothing was acted on, and no `recovery.tsv` row was written.
- I put the saved file back at 08:38:10. The 08:39 pass gave `Result=success` (`TICK active action=no-op ... route cloudflare-onion stays selected`).
See Minor finding 1 for what `status` showed during the refused passes.

# Findings

No Blocking finding. Outcomes 3, 6, 9 and 11 hold, and so does the controller half of 10, all on mint by the user's route. Outcomes 1, 2, 4, 5, 7 and 8, and the installer half of 10, are not shown here (residuals).

Static gate checks, read-only, run in the repo:
- Goal loop: every BL id is found, rc 0. BL-021 in scheduling, bridge-lifecycle and install-prepare. BL-022 in route-transition. BL-030 in recovery-actions and bridge-lifecycle. BL-031 in bridge-lifecycle. BL-036 in unit/state-policy. BL-054 in recovery-actions, install-prepare, unit/observations and unit/state-policy.
- Hash grep: rc 0.
- shellcheck over the seven scripts: rc 0.
The test suites (mawk run and plan scope) were not run by this evaluator.

## Minor
1. While every pass was refused for the bad `outage_restarts` value (08:35-08:38), `nice-dns status --tsv` at 08:37:34 still printed `controller verdict OK` and `stale no`, with `last_pass` 3.5 min old. `health.log` wrote only `TICK active =`, with no reason. The key is named only in the systemd journal. A person reading `nice-dns status` or the GUIs sees nothing wrong until the stale threshold passes. This is pre-existing ("refused as today").
2. A refresh that evaluated nothing still updates `last_refresh`. The no-sha refresh (`not-applied ... nothing is evaluated`) wrote `bridges.last`, and `nice-dns bridges status` then showed `last_refresh 1795077802`. A refresh skipped for `bridges off` does not update it. The status can therefore claim a refresh that did not happen.
3. Out of plan scope: after the 08:25 reinstall from `sweep-controller`, `status` still showed `update result current` with `remote_commit d769e954...`. That answer comes from the 00:06 check against the old branch, and the installed commit is a8c1151. The answer kept from before the reinstall is not cleared.

## What I changed on mint, and put back
- `state.tsv`: I added an unknown key, which the controller dropped itself. I set a bad value, and restored the saved file at 08:38:10. Passes have succeeded since 08:39.
- Bridges mode: on at 08:40:37, back off at 08:45:21 with `nice-dns bridges off`. `bridges-mode.env` is byte-identical to before (`TOR_BRIDGES=off`). Only its mtime changed.
- The two real refreshes rewrote `bridges.env`, `.prev`, `bridge-pool.tsv` and `bridges.last`, and created `bridges.pending`. I restored all four from copies taken before (the sha256 values match) and removed `bridges.pending`. `nice-dns bridges status` reads `off / 7 / 1794398584`, as at the start.
- The proxy restarted twice (bridges on, bridges off). It is now a fresh tor-socat on route cloudflare-exit, and the controller will re-promote the onion after 5 healthy passes. At 08:47 the verdict was OK.
- The scratch dir `~/demo-eval` (backups and the no-sha PATH) has been removed.

## Material
1. The tree changed while this demo ran, and the changes were not mine. At session start `git status` showed only this demo.md as untracked. At 08:49 there were ten uncommitted modified files, with mtimes 08:39:40-08:41:08: docs/qualification.md, lib/install.sh, lib/recovery.sh, tests/integration/{install-prepare,recovery-actions,scheduling}.sh, tests/manifests/{scenarios,stage-scenarios}.tsv and tests/unit/{observations,state-policy}.sh (91+/28-). I did not read that diff.
   - The live demo on mint is not affected: mint runs the installed a8c1151 build.
   - The static checks above (goal loop, hash grep, shellcheck) ran at about 08:47, so they cover that uncommitted tree, not HEAD 75f94f1.
   - lib/recovery.sh and lib/install.sh changed after the mint reinstall. The code the gate finally names may therefore differ from what mint demonstrated. Re-check against the commit the gate is run on.
