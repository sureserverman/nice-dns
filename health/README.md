# `nice-dns-health`

Health controller for the nice-dns DNS chain. Runs every minute via a
systemd-user timer (Linux) or a LaunchAgent (macOS), refreshes the Tor
bridges once a day, and on failure dumps the diagnostic info needed to
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
- Fallback: `~/.local/state/nice-dns-health/bin/nice-dns-health`
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
```

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
| `dns-owner` | Linux: `/etc/resolv.conf` names only `nameserver 127.0.0.1`. macOS: every enabled network service (`networksetup`) and `scutil --dns` resolver #1 use `172.31.240.250` |
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
  the proxy at once (macOS: the stack) so the bad bridge stops carrying
  queries. DNS fails closed for that gap: 14 to 17 s in the live tests on
  Linux, no query leaves the machine meanwhile. At most one such restart per
  refresh.

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
  the checks, `OnCalendar=daily` (`Persistent=true`) for the bridge refresh.
  Calendar timers fire after a suspend, where `OnUnitActiveSec` would pause.
- **macOS**: an empty `StartCalendarInterval` (every minute) plus
  `RunAtLoad=true` for the checks, `StartCalendarInterval` at 04:17 for the
  bridge refresh. launchd starts a calendar job on wake; `StartInterval`
  would miss the intervals spent asleep.
