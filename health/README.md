# `nice-dns-health`

Periodic health-check for the nice-dns DNS chain. Runs every 30 minutes
via systemd-user timer (Linux) or LaunchAgent (macOS); on failure, dumps
all the diagnostic info needed to pinpoint the culprit.

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

## Manage the schedule

```sh
nice-dns-health start      # (re)start the timer / load LaunchAgent
nice-dns-health stop       # pause the timer / unload LaunchAgent
nice-dns-health status     # schedule + last 5 health.log entries
nice-dns-health run        # run a check now
nice-dns-health logs       # cat the rolling log
nice-dns-health failures              # list recent failure dumps
nice-dns-health failures --last       # print the most recent dump
```

## Logs

| Platform | Rolling log | Failure dumps |
|---|---|---|
| Linux | `$XDG_STATE_HOME/nice-dns-health/health.log` (default `~/.local/state/...`) | same dir, `failure-YYYYMMDD-HHMMSS.log` |
| macOS | `~/Library/Logs/nice-dns-health/health.log` | same dir |

Rolling log rotates at 10 MiB → `health.log.1`. Failure dumps are
pruned to the most recent 10.

## What it checks

| # | Check | Pass condition |
|---|---|---|
| 1 | `/etc/resolv.conf` | line `nameserver 127.0.0.1` is present |
| 2 | container runtime (`podman` on Linux, Apple `container` on macOS) | binary on PATH |
| 3 | expected containers | `pi-hole`, `unbound`, and one of `tor-haproxy` / `tor-socat` are running |
| 4 | `dig @127.0.0.1 pi.hole` | exactly one A record (FTL alive on :53) |
| 5 | `dig @127.0.0.1 cloudflare.com` | a real, non-zero A record (chain works end-to-end) |
| 6 | `dig @127.0.0.1 doubleclick.net` | `0.0.0.0` (gravity blocklist active) |

## What a failure dump contains

- Per-check verdict (`OK` / `FAIL <reason>`)
- `/etc/resolv.conf` snapshot
- `<runtime> ps -a`
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

- **Linux**: `OnBootSec=2min` for first fire after boot, then
  `OnUnitActiveSec=30min`. `Persistent=true` makes systemd run a missed
  check at most once after a long downtime (avoiding a stampede).
- **macOS**: `StartInterval=1800` plus `RunAtLoad=true` for an immediate
  first check on install/login.
