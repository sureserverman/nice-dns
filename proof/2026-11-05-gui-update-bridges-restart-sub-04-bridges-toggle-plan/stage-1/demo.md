# Stage 1 demo — 2026-11-05-gui-update-bridges-restart-sub-04-bridges-toggle-plan

Environment: the laptop (Linux, kernel 7.0.0-42), branch bridges-toggle at eeb4cc2, 2026-11-07 09:13–09:20 UTC.
Re-demo from scratch (the earlier demo at e125299 failed Outcome 5).
The product was not read. Every run used the checkout's `./nice-dns` with a scratch HOME (`mktemp -d` under the session scratchpad).
XDG_STATE_HOME, XDG_CONFIG_HOME and XDG_DATA_HOME were empty. XDG_RUNTIME_DIR pointed into scratch. DBUS_SESSION_BUS_ADDRESS pointed at a dead path.
PATH started with stub `systemctl`, `podman`, `container`, `launchctl`, `dig`, `journalctl`, `loginctl` and `sudo`. Each stub only logged its arguments. The podman stub reported a new tor-haproxy start ID after a stubbed `systemctl restart`, and dig answered `104.16.132.229`.
Scratch HOME contents:
- read-only copies of the real install record (`~/.local/state/nice-dns-install/`) and controller state;
- a synthetic `bridges.env` (7 bridges, 192.0.2.11-17) and `bridge-pool.tsv` (9 lines, 192.0.2.11-19). The real bridge files were never copied or printed;
- the HEAD quadlets copied into `~/.config/containers/systemd/`;
- the source from `git archive HEAD`;
- the controller, installed with its own `nice-dns-health install` (stubbed systemctl).
The real stack, the real DNS and the real config were not touched. The only real-HOME reads were `./nice-dns bridges status`, `./nice-dns status` and file listings.
No real proxy start was possible here. That is Stage 2's job on mint and the Mac. There is no Mac here, so the macOS consumers were not exercised.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: `nice-dns bridges off` writes the mode and prints what the ISP will now see; `nice-dns bridges status` prints `off` and the pool size; the proxy's next start runs Tor direct; refreshes journal `skipped`.
Verdict: holds
Note (moved from the verdict line by the executor, unchanged): the real proxy start could not be reached here; it is shown up to the rendered unit and the locked image's contract
Evidence:
```
$ ./nice-dns bridges status            # before; no mode file yet
mode	on
count	7
last_refresh	never
exit=0
$ ./nice-dns bridges off
Bridges are off. Your ISP will see plain Tor guard connections instead of
obfs4 traffic: it can tell you use Tor, though still not what you look up.
Restarting the proxy...
Waiting for the DNS chain to come up at 127.0.0.1 (Tor bootstrap takes 1-4 min)...
Chain is resolving, and Unbound resolves over its authenticated route.
Bridges are off; the proxy restarted and DNS is answering.
exit=0
stub log: systemctl --user stop nice-dns-health.timer / stop nice-dns-health-bridges.timer
          podman inspect ... tor-haproxy   (start id before)
          systemctl --user restart tor-haproxy.service
          podman inspect ... tor-haproxy   (new start id = the acknowledgement)
          dig @127.0.0.1 +time=3 +tries=1 +short cloudflare.com
          podman exec --user unbound unbound /usr/local/bin/nice-dns-unbound-start probe-route .
          systemctl --user start nice-dns-health.timer / start nice-dns-health-bridges.timer
$ cat ~/.config/nice-dns/bridges-mode.env
TOR_BRIDGES=off
bridges.env: byte-identical to before (cmp)
$ ./nice-dns bridges status
mode	off
count	7
last_refresh	never
exit=0
```
My first run's podman stub never reported a new start, so the proxy never "came back". That run printed the same two ISP lines and then:
`nice-dns: bridges off is written, but the proxy restart failed (exit 1: no new start of tor-haproxy within 120s); it takes effect at the next proxy start.` / `nice-dns: Check `nice-dns-health status`.`
It exited 1 after 2m01s and put the timers back. So a restart that is never acknowledged is reported as a failure, not as success.

Next proxy start (Linux). I rendered the HEAD quadlets read-only with `QUADLET_UNIT_DIRS=<scratch copy of deb/quadlet> /usr/libexec/podman/quadlet -dryrun -user`. Both proxy units have `EnvironmentFile=-%h/.config/nice-dns/bridges-mode.env` in [Service]. Both have `--env TOR_BRIDGES` on the `podman run` line:
`ExecStart=/usr/bin/podman run --name tor-haproxy ... --env-file %h/.config/nice-dns/bridges.env ... --pod nice-dns --env TOR_BRIDGES docker.io/sureserver/tor-haproxy:latest` (tor-socat renders the same way).
This branch's `release/images.lock` pins tor-haproxy v2.16 (commit 7bf2ae0) and tor-socat v2.12 (commit 165a127). Both are declared `provides ... bridges-mode/1`. Those commits' `start.sh` read `TOR_BRIDGES="${TOR_BRIDGES:-on}"`. Their docs say `off` runs Tor direct and ignores BRIDGE1..16.
Not reached: a real container start that shows Tor bootstrapping with no bridges.

Refreshes while off (the timer's own command, from the generated `nice-dns-health-bridges.service`):
```
$ nice-dns-health bridges-refresh
result	skipped
detail	bridges off
exit=0
health.log: 2026-11-07T09:17:11+0000 BRIDGES result=skipped
stub log: only `podman ps`; no bridge-eval, no restart; ~/.config/nice-dns unchanged (diff -r)
```
Status prints `count 7`, the size of the active set in bridges.env. It does not print the 9-line pool (see Minor 2).

## Outcome 2
> `nice-dns bridges on` → the last good set is used again at the next start; refreshes resume.
Verdict: holds
Note (moved from the verdict line by the executor, unchanged): next start shown up to the rendered unit, as in Outcome 1
Evidence:
```
$ ./nice-dns bridges on
Restarting the proxy...
Waiting for the DNS chain to come up at 127.0.0.1 (Tor bootstrap takes 1-4 min)...
Chain is resolving, and Unbound resolves over its authenticated route.
Bridges are on; the proxy restarted and DNS is answering.
exit=0
(stub log: the same locked, acknowledged sequence as `off`)
bridges-mode.env: TOR_BRIDGES=on
bridges.env: byte-identical to the set from before `off` (cmp) -> the unit's --env-file feeds the same 7 bridges
$ ./nice-dns bridges status
mode	on
count	7
exit=0
$ ./nice-dns bridges on          # again, no change
Bridges are already on; nothing restarted.
exit=0                           (no restart in the stub log)
$ nice-dns-health bridges-refresh
result	not-applied
dropped	0
adopted	-
exit=1
stub log: podman run --rm --user 0:0 --pull=missing -v ~/.config/nice-dns:/pool --entrypoint /bin/bridge-eval docker.io/sureserver/tor-haproxy:latest -pool /pool/bridge-pool.tsv -out /pool/.bridges.env.candidate.NNN -count 7 -window 150 -grace 20
health.log: 2026-11-07T09:17:38+0000 BRIDGES result=not-applied
```
The refresh runs the evaluator again, so refreshes resume. It answered `not-applied` because the stub evaluator wrote no candidate. A stub that wrote one gave `result changed` and the set was adopted.

## Outcome 3
> Not installed → the usual not-installed message, exit 1.
Verdict: holds
Evidence:
Run with an empty scratch HOME:
```
$ ./nice-dns bridges off      -> nice-dns: nice-dns is not installed; run `nice-dns install`   exit=1
$ ./nice-dns bridges on       -> same line, exit=1
$ ./nice-dns bridges status   -> same line, exit=1
$ ./nice-dns restart          -> same line, exit=1   (the usual message, for comparison)
```
No stub was called. No file was created; the HOME stayed empty (find).

## Outcome 4
> A bad argument → usage, exit 2.
Verdict: holds
Evidence:
Each of these printed one error line and then the full usage, on stderr (0 lines on stdout), and exited 2:
- `bridges` (no argument) and `bridges on extra` -> `nice-dns: bridges takes one of on, off, status`
- `bridges status --tsv` -> the same line
- `bridges maybe`, `bridges OFF`, `bridges --help`, `bridges off=1`, `bridges ''` -> `nice-dns: unknown option '<arg>' for bridges`

`bridges maybe` with nothing installed also gives usage and exit 2, because the argument is checked first.
No stub was called. The mode file stayed byte-identical.

## Outcome 5
> The mode file cannot be written → the error names the path; nothing else changes.
Verdict: holds
Evidence:
5a. This is the re-demo case: `~/.config/nice-dns/bridges-mode.env` is a directory, and the mode was on.
```
$ ./nice-dns bridges off
nice-dns: could not write <scratch HOME>/.config/nice-dns/bridges-mode.env: it is a directory; the bridges mode is unchanged
exit=1
stub log: is-active/stop nice-dns-health.timer, is-active/stop nice-dns-health-bridges.timer,
          start nice-dns-health.timer, start nice-dns-health-bridges.timer   (no podman, no restart, no dig)
snapshot of ~/.config/nice-dns (names, modes, sizes, sha256 of bridges.env and pool): identical before/after
bridges-mode.env: still an empty directory (nothing moved inside it)
$ ./nice-dns bridges on        -> same error line, exit=1
$ ./nice-dns bridges status
unreadable	cannot read ~/.config/nice-dns/bridges-mode.env
mode	on
count	7
last_refresh	never
exit=2
```
5b. `~/.config/nice-dns` was made read-only (chmod 500).
`bridges off` printed `nice-dns: could not write <scratch HOME>/.config/nice-dns/bridges-mode.env; the bridges mode is unchanged` and exited 1. The stub log showed only the timer stop and start, with no restart. The snapshot was identical.

5c. Timers stopped by the owner (the stub `is-active --quiet` exits 3), with the mode file a directory.
`bridges on` and `bridges off` each failed with the 5a line, exit 1. The stub log showed only the two `is-active` checks. No timer was started, so the stopped timers stayed stopped.
A successful switch in this state also left them stopped.

5d. This is an edge case and not a failure: the mode file itself was read-only (0400) in a writable directory.
`bridges off` succeeded (exit 0, restart acknowledged). The file was replaced and now reads `TOR_BRIDGES=off` with mode 0644. That is expected, because the directory lets the file be replaced.

## Findings

Blocking: none.

Material:
1. The checkout's command reports a switch that an older install cannot honour.
   - What I ran: the checkout's `./nice-dns bridges off` against an install made before this branch. The fixture was the laptop's real install record (tor-haproxy v2.15) plus a copy of its installed `tor-haproxy.container`.
   - What it printed: "Bridges are off. Your ISP will see plain Tor guard connections…", then "Bridges are off; the proxy restarted and DNS is answering." It exited 0.
   - Why that is wrong: the rendered old unit has no TOR_BRIDGES and no bridges-mode.env (0 mentions). Locked tor-haproxy v2.15 (commit 1933059) has no TOR_BRIDGES in start.sh. So the proxy keeps using bridges, while the command says off and `bridges status` says `off`.
   - Scope: the laptop's real install is in exactly this state. Its installed quadlet, installed command and prepare.tsv know nothing of the bridges mode. A user who updates through `nice-dns update`/`reinstall` gets matching units and images, so the normal route is not affected.

Minor:
1. A second `bridges on|off` started while the first was still restarting the proxy did wait for the first: its podman and restart calls began only after the first finished.
   - Its timer `is-active`/`stop` calls ran before it waited, while the first switch was mid-restart.
   - The first switch then restarted the timers while the second still had its own restart to do (stub log 09:18:38 stop, 09:18:44 start, 09:18:48 the second's restart).
   - The minute `tick` answered `result=busy` during a switch, so no controller restart fought it.
   - A manual `nice-dns-health bridges-refresh` did run its evaluator during a switch, without waiting. It did not restart anything in my runs. I could not show whether an adopting refresh would restart the proxy then.
2. The Outcome asks for "the pool size". `bridges status` prints `count`, which is the number of bridges in bridges.env (7). It is not the size of bridge-pool.tsv (9 lines). The help text says "the number of bridges", so the output matches the help but not the Outcome's wording.
3. `bridges-mode.env` is written 0644, while its neighbours in ~/.config/nice-dns are 0600. It holds no secret.

Not reached here: a real proxy start in either mode, the macOS consumers (mac/start-container.sh, lib/platform/macos.sh), and the GUIs. These are left to Stage 2's live switch on mint and the Mac.
