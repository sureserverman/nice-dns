# `nice-dns-health`

Health controller for the nice-dns DNS chain. Runs every minute via a
systemd-user timer (Linux) or a LaunchAgent (macOS), refreshes the Tor
bridges once a day, checks for a nice-dns update twice a day, and on failure
dumps the diagnostic info needed to
pinpoint the culprit.

## Install / uninstall

From a `nice-dns/` checkout:

```sh
./health/nice-dns-health install      # set up + start the schedule
./health/nice-dns-health uninstall    # tear down + remove logs
```

`install` copies the script to a user-stable path so the timer/agent
keeps working even if the repo is moved or deleted:

- Primary:  `~/.local/bin/nice-dns-health` (when user-writable)
- Fallback: `~/.local/state/nice-dns-health/bin/nice-dns-health` on Linux,
  `~/Library/Logs/nice-dns-health/bin/nice-dns-health` on macOS
  (used when `~/.local/bin` is owned by root, e.g. on Ubuntu hosts where
  apt-installed `xdg-utils` claimed it)

It also copies the libraries the checks come from (`lib/health.sh`,
`lib/platform/{linux,macos}.sh`, `routes/providers.tsv`) to
`${XDG_DATA_HOME:-~/.local/share}/nice-dns-health/` (Linux) or
`~/Library/Application Support/nice-dns-health/` (macOS). Run from a
checkout, the script reads them from `../lib` and `../routes`. Either way it
refuses to load a library through a symlink, or from a file or directory
that is writable by group or others or owned by another user.

## Manage the schedule

```sh
nice-dns-health start      # (re)start the timer / load LaunchAgent
nice-dns-health stop       # pause the timer / unload LaunchAgent
nice-dns-health status     # schedule + last 5 health.log entries
nice-dns-health run        # run a check now
nice-dns-health observe    # print the observations as TSV (read-only)
nice-dns-health logs       # cat the rolling log
nice-dns-health failures              # list recent failure dumps
nice-dns-health failures --last       # print the most recent dump
nice-dns-health bridges-refresh       # the daily bridge refresh, now
nice-dns-health update-check          # the twice-daily update check, now
```

`start`, `stop`, `install` and `uninstall` act on all three schedules
(checks, bridge refresh, update check) together. Shadow mode installs only
the minute checks.

`update-check` runs the published `nice-dns update --check` under a 60 s
bound. It only checks and never installs: the result lands in the cache
`nice-dns status` reads (its `update` rows), and a failed or timed-out check
is kept as `unknown`, with the time, until the next one. There is no switch
to turn it off; `stop` stops it with the other schedules.

## Logs

| Platform | Rolling log | Failure dumps |
|---|---|---|
| Linux | `$XDG_STATE_HOME/nice-dns-health/health.log` (default `~/.local/state/...`) | same dir, `failure-YYYYMMDD-HHMMSS.log` |
| macOS | `~/Library/Logs/nice-dns-health/health.log` | same dir |

Rolling log rotates at 10 MiB → `health.log.1`. Failure dumps are
pruned to the most recent 10.

## What it checks

The checks are the observations of `lib/health.sh`. Each is `healthy`,
`unhealthy` or `indeterminate` (it could not be observed: a deadline, dig's
own timeout, a missing tool). `observe` prints them as
`obs<TAB>name<TAB>verdict<TAB>duration_ms<TAB>reason` after a
`schema<TAB>nice-dns-observations/1` line. Pi-hole's endpoint is
`127.0.0.1:53` on Linux and `172.31.240.250:53` (dnsnet) on macOS.

| Observation | Healthy when |
|---|---|
| `runtime` | the runtime CLI (`podman`; Apple `container`, also at `/opt/homebrew/bin/container`) answers and `pi-hole`, `unbound` and one of `tor-haproxy` / `tor-socat` run |
| `container:<name>` | one per stack container (`pi-hole`, `unbound`, the running proxy): it runs, and podman's own health check (Linux) is not unhealthy. The reason ends `restarts N`, the unit's restart count (Linux `NRestarts`; macOS 0). Paused is unhealthy `paused`, any other stop `exited: rc N`; a transient state (created, stopping) or a failed inspect is indeterminate |
| `dns-owner` | Linux: `/etc/resolv.conf` names only `nameserver 127.0.0.1`. macOS: every enabled network service (`networksetup`) and `scutil --dns` resolver #1 use `172.31.240.250` |
| `install-drift` | Linux only: an install generation is recorded and the installed quadlets (with their drop-ins) declare host port 53 on loopback only. Otherwise `install-security-drift`, unhealthy, logged at err once a day per reason; indeterminate while an install is under way. Reported, never acted on: nothing is re-rendered (`nice-dns-health status` / `drift`) |
| `local-service` | `pi.hole` has an A record (FTL alive) |
| `filtering` | every A record of `doubleclick.net` (after CNAMEs) is `0.0.0.0` |
| `local-cache` | Pi-hole answers `cloudflare.com` (NOERROR or NXDOMAIN). This can be a cached answer: it is not upstream health |
| `route:<id>` | one per route in `routes/providers.tsv`: the proxy image's `nice-dns-route-probe` gets an authenticated answer on the route's port and TLS name (NXDOMAIN counts) |

`run` passes only when every observation is healthy. It logs `FAIL [...]`
with the unhealthy names, or `INDETERMINATE [...]` when nothing is known
to be broken but something could not be observed. `chain-resolves` fails
when no route answered and at least one failed. When a later run still sees
it after the 300 s grace (`NICE_DNS_RESTART_GRACE_SECS`), that run triggers
the Tor restart described in the script.

The `unbound` observation reads Unbound itself: its control socket, then its
route in a fresh session. Three failures in a row restart it, with the routes
healthy or not when the control socket is what failed. A failed route check
during a full outage is left to the Tor restarts below, since Unbound is telling
the truth. After two restarts it retries every 30 minutes, and a passing check
right after a restart does not reset that. Pi-hole and the proxy keep running on
Linux; on macOS the restart rebuilds the stack.

Pi-hole is read the same way. A pass fails it when `container:pi-hole` or
`local-service` is unhealthy, or when `pi.hole` timed out while a route
answered: FTL answers that name itself, so a silent one is hung. Three
failures in a row restart Pi-hole alone on Linux (`systemctl --user restart
pi-hole.service`) and rebuild the stack on macOS. A single container restarted
there comes back at another address. After two restarts it retries every 30
minutes. The controller is Pi-hole's one restart owner: `pi-hole.container` is
`HealthOnFailure=none`, so podman's check only reports.

A container read `paused` in two passes in a row is unpaused (Linux, `podman
unpause`), so a short deliberate pause is not undone within a minute. After two
unpauses it retries every 30 minutes. macOS has no pause; the reading escalates.

A crash loop is held, not fought. Every container unit backs off by itself:
`RestartSteps=5` and `RestartMaxDelaySec=300s` stretch the delay between starts
from 3 s towards 300 s (systemd 254+; on mint the first four were 3, 8, 19 and
47 s). When a container's restart count rises, the controller treats it as a
restart that already happened: the cooldown starts from it, and for 10 minutes
nothing restarts that container or the stack. Three rises within 10 minutes
escalate once, `crash-loop: <name>`, with one failure dump. A count stable for
10 minutes clears it. The hold lasts at most 30 minutes from the loop's first
rise. After that the loop no longer holds the stack: a full outage, or a
container that stays missing, restarts the stack, then again every 30 minutes,
and the loop escalates again every 30 minutes while it lasts. The looping
container itself is never restarted by name. Apple containers do not restart
themselves, so on macOS the count stays 0.

A full outage restarts Tor, then the proxy. After that the whole stack restarts
every 30 minutes until a route answers, and the first escalation of the outage
writes one failure dump. A missing container is started by name. If its unit last
exited 125 or 126, podman could not start it, so the user service manager is
re-executed first, and the pod restarts if that start still fails, at most once
every 30 minutes. After three repairs with no healthy reading, whatever the routes
say, the whole stack restarts at once and then every 30 minutes, and the passes
between log the escalation. Every action is a row in `recovery.tsv`.

## Bridge refresh

Once a day (Linux `OnCalendar=daily`; macOS at 04:17), and at most once an
hour during an outage, the controller re-evaluates the Tor bridge pool with
the proxy image's `bridge-eval` and writes the result to
`~/.config/nice-dns/bridges.env`:

- A bridge can pass `bridge-eval` (its obfs4 handshake works) and still
  carry streams badly. The controller reads the running Tor's own per-bridge
  counters and leaves out every bridge with at least 20 stream uses and
  under 90% success. It remembers such a bridge for 30 days
  (`bridges.weak` in its state directory, fingerprints only), because Tor's
  counters do not survive every restart (macOS drops Tor's state when the
  bridge set changes).
- Fewer than 3 bridges left after that: nothing changes, the last good set
  stays.
- A changed set is normally used at the proxy's next start. When the running
  proxy still uses a bridge the new set leaves out, the refresh restarts
  the proxy at once so the bad bridge stops carrying queries. On Linux that
  is the proxy alone (Unbound only `Wants=` it, so it keeps running); on
  macOS the whole stack is rebuilt. DNS fails closed for that gap: 14 to
  17 s in the live tests on Linux, no query leaves the machine meanwhile.
  At most one such restart per refresh.

With `nice-dns bridges off` (`TOR_BRIDGES=off` in
`~/.config/nice-dns/bridges-mode.env`), Tor runs without bridges, so every
refresh is skipped: the journal gets `bridges skipped bridges off`, nothing
is evaluated, `nice-dns-health bridges-refresh` exits 0, and `bridges.env`
is kept for `nice-dns bridges on`.

The journal (`recovery.tsv` in the state directory) records each refresh,
the bridges left out (by a 12-character fingerprint prefix) and any restart.

## What a failure dump contains

- Per-check verdict (`OK` / `FAIL` / `???` for indeterminate, with reason)
  and the raw observation records
- `/etc/resolv.conf` snapshot
- `podman ps -a` (Linux) or `container ls -a` (macOS)
- For each expected container: `inspect` state (status / health /
  restart count / pid) and the last 50 log lines
- `dig` output for the chain test and the blocked-domain test
- Linux: `systemctl --user list-units` for the nice-dns services,
  full `nice-dns-pod.service` status with last 30 journal lines,
  port 53 owner from `ss`, `custom-dns-deb.service` status,
  last 30 `journalctl --user` lines for `nice-dns-health.service`
- macOS: `launchctl list | grep nice-dns`, `lsof` for port 53,
  per-network-service `networksetup -getdnsservers`

A new dump is written each time `run` reports a failure; the rolling
log records the path so you can find it weeks later.

## Schedule semantics

- **Linux**: `OnCalendar=minutely` (`AccuracySec=5s`, `Persistent=true`) for
  the checks, `OnCalendar=daily` (`Persistent=true`) for the bridge refresh,
  `OnCalendar=*-*-* 00/12:00:00` (`RandomizedDelaySec=30m`,
  `Persistent=true`) for the update check
  (`nice-dns-health-update.timer`). Calendar timers fire after a suspend,
  where `OnUnitActiveSec` would pause. The first update check comes at the
  next 12-hour slot: systemd.timer(5) does not say whether `Persistent=true`
  fires on a first activation, so nothing relies on it.
- **macOS**: an empty `StartCalendarInterval` (every minute) plus
  `RunAtLoad=true` for the checks, `StartCalendarInterval` at 04:17 for the
  bridge refresh, an array of two `StartCalendarInterval` entries (04:47 and
  16:47) for the update check (`org.nice-dns.health-update`). launchd starts
  a calendar job on wake; `StartInterval` would miss the intervals spent
  asleep.
