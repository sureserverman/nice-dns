# Stage 2 demo — 2026-11-05-gui-update-bridges-restart-sub-04-bridges-toggle-plan

Environment: mint (Linux Mint 22.3, podman 5.8.1) and the mac (macOS 27.2, container CLI 1.7.1), both running tor-socat. Live run 20261107T131054Z-8d4127f8, 2026-11-07 13:10–13:20 UTC, at a80530c; gate at 55a052b.

Evaluator: skipped — goal command `for f in deb/quadlet/tor-haproxy.container deb/quadlet/tor-socat.container deb/persistent-podman.sh mac/start-container.sh lib/recovery.sh lib/platform/macos.sh nice-dns; do grep -q 'TOR_BRIDGES' "$f" || exit 1; done` at 55a052b

Each Outcome is decided by the gate's receipt command. Its receipt comes from the live run on the real targets, which drove `nice-dns bridges off|on` the way the owner does. A demo would repeat that run by hand: four Tor bootstraps per platform.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: per platform, `off` restarts the proxy, the supervisor line says `direct (no bridges)`, a fresh name answers within 10 min, a forced refresh journals `skipped`; `on` brings `with N bridge(s)` back and a fresh name answers.
Verdict: holds
Decided by: `bash tests/run.sh receipt bridges-toggle` at 55a052b
Evidence:
```
receipt=bridges-toggle cells=2 scenarios=10 errors=0 limits=2 reused=0 file=.../receipts/bridges-toggle/20261107T131054Z-8d4127f8/receipt.tsv
linux-socat-standard switch-off: cli_exit 0; journal bridges-off-1794057274 bridges mode-change off, service acknowledged tor-socat restarted;
  supervisor tor-socat: spawned tor pid=10 generation=1 direct (no bridges); fresh_name NOERROR, elapsed_s 27
linux-socat-standard refresh: refresh_exit 0, refresh_result skipped, journal bridges skipped bridges off
linux-socat-standard switch-on: cli_exit 0; journal bridges-on-1794057339 mode-change on, service acknowledged;
  supervisor: spawned tor pid=28 generation=1 with 7 bridge(s); fresh_name NOERROR, elapsed_s 25
macos-socat-standard switch-off: cli_exit 0; journal bridges-off-1794057268 mode-change off, service acknowledged;
  supervisor: spawned tor pid=13 generation=1 direct (no bridges); fresh_name NOERROR, elapsed_s 39
macos-socat-standard refresh: refresh_exit 0, refresh_result skipped, journal bridges skipped bridges off
macos-socat-standard switch-on: cli_exit 0; journal bridges-on-1794057345 mode-change on, service acknowledged;
  supervisor: spawned tor pid=28 generation=1 with 7 bridge(s); fresh_name NOERROR, elapsed_s 38
```

## Outcome 2
> A target is unreachable → that check is `[~]` with the reason.
Verdict: holds
Decided by: `bash tests/run.sh receipt bridges-toggle` at 55a052b
Evidence:
```
receipt=bridges-toggle cells=2 scenarios=10 errors=0 limits=2 reused=0
Both targets were reached: one cell per platform (linux-socat-standard, macos-socat-standard), 10 scenarios, no check left [~].
The first run (20261107T111101Z-743b291d) reached both targets too; it failed the mac's install step (OD-8), and no check was marked as unreachable.
```
