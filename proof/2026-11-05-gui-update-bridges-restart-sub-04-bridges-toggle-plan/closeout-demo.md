# Close-out demo: Sub-plan 4, Bridges on/off toggle

Evaluator run on 2026-11-07, 21:32 to 21:42 UTC. Branch bridges-toggle, HEAD b437075.
Targets: mint (`ssh mint`, Linux, Podman, tor-socat) and mac (`ssh mac`, Apple container, tor-socat).
Both started with bridges on, 7 bridges, the supervisor line `with 7 bridge(s)`, and a fresh name answering.
No source or diff was read. README.md and health/README.md were read.
No bridge line, fingerprint or bridge file was printed. Hex strings of 12+ characters in journal rows were redacted to `<hex>`.

Mac commands ran inside the gui session (BL-052):
`ssh mac 'sudo -n launchctl asuser $(id -u) sudo -n -u $(id -un) env HOME=$HOME PATH=/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin <cmd>'`.
(zsh on the Mac does not word-split a `$W` variable, so the wrapper went into a local helper script that sends the full line.)

Mac journal: `~/Library/Application Support/nice-dns/controller/recovery.tsv`. Mint journal: `~/.local/state/nice-dns/controller/recovery.tsv`.

## Outcome S1-1

> Works: `nice-dns bridges off` writes the mode and prints what the ISP will now see; `nice-dns bridges status` prints `off` and the pool size; the proxy's next start runs Tor direct; refreshes journal `skipped`.

Verdict: holds (both targets). On mint, `off` could not restart the proxy over plain ssh (finding F1). The next proxy start still ran direct.

Evidence:

mint, `ssh mint '~/.local/bin/nice-dns bridges off'` (21:36:09 UTC):
```
rc=1 elapsed=1s
-- stdout:
Bridges are off. Your ISP will see plain Tor guard connections instead of
obfs4 traffic: it can tell you use Tor, though still not what you look up.
Restarting the proxy...
-- stderr:
nice-dns: bridges off is written, but the proxy restart failed (exit 1: service restart of tor-socat exited 1); it takes effect at the next proxy start.
nice-dns: Check `nice-dns-health status`.
```
Journal:
```
1794087369 bridges-off-1794087369 bridges mode-change off
1794087369 bridges-off-1794087369 service requested proxy restart for tor-socat; container before: <hex> 2026-11-07 13:15:40... running
1794087369 bridges-off-1794087369 service not-acknowledged the service restart of tor-socat exited 1: Failed to connect to bus: No medium found
```
`nice-dns bridges status` -> `mode off`, `count 7`, `last_refresh never`.
The plain ssh session has `XDG_RUNTIME_DIR` empty, though `/run/user/1000/bus` exists and linger is on. `systemctl --user` fails there with the same "No medium found". The existing `nice-dns restart` fails the same way over plain ssh: `nice-dns: the stack restart failed (exit 1): Failed to connect to bus: No medium found`.
Next proxy start: `ssh mint 'export XDG_RUNTIME_DIR=/run/user/$(id -u); ~/.local/bin/nice-dns restart'` -> rc=0 after 18s, `nice-dns restarted; DNS is answering.` Supervisor line: `tor-supervisor: spawned tor pid=10 generation=1 direct (no bridges)`.
Fresh name `nd-eval-<ts>.example.com` -> `status: NOERROR` on the first try. `cloudflare.com` -> 104.16.132.229.
Forced refresh `~/.local/bin/nice-dns-health bridges-refresh` -> rc=0, `result skipped`, `detail bridges off`. Journal: `1794087456 br-1794087456 bridges skipped bridges off`.

mac, `nice-dns bridges off` in the gui session (21:39:45 UTC):
```
rc=0 elapsed=22s
Bridges are off. Your ISP will see plain Tor guard connections instead of
obfs4 traffic: it can tell you use Tor, though still not what you look up.
Restarting the proxy...
Waiting for the DNS chain to come up at 172.31.240.250 (Tor bootstrap takes 1-4 min)...
Chain is resolving, and Unbound resolves over its authenticated route.
Bridges are off; the proxy restarted and DNS is answering.
```
Supervisor: `tor-supervisor: spawned tor pid=13 generation=1 direct (no bridges)`. All three containers restarted at 21:39:52-53Z.
Journal: `mode-change off`, `service requested stack restart for tor-socat`, `service acknowledged tor-socat restarted ... 21:39:53Z`, `service ready observed working 16s after the acknowledgement`.
`nice-dns bridges status` -> `mode off`, `count 7`, `last_refresh never`.
Fresh name @172.31.240.250 -> `status: NOERROR`.
Forced refresh `nice-dns-health bridges-refresh` -> rc=0, `result skipped`, `detail bridges off`. Journal: `1794087615 br-1794087615 bridges skipped bridges off`.

## Outcome S1-2

> `nice-dns bridges on` → the last good set is used again at the next start; refreshes resume.

Verdict: holds (both targets).

Evidence:

mint, `export XDG_RUNTIME_DIR=/run/user/$(id -u); ~/.local/bin/nice-dns bridges on` (21:37:47 UTC):
```
rc=0 elapsed=14s
Restarting the proxy...
Waiting for the DNS chain to come up at 127.0.0.1 (Tor bootstrap takes 1-4 min)...
Chain is resolving, and Unbound resolves over its authenticated route.
Bridges are on; the proxy restarted and DNS is answering.
```
Supervisor: `tor-supervisor: spawned tor pid=28 generation=1 with 7 bridge(s)`. The same count as before `off`, so the kept pool was reused.
Journal: `mode-change on`, `service requested proxy restart`, `service acknowledged tor-socat restarted ... 21:37:49`, `service ready observed working 22s after the acknowledgement`.
Forced refresh -> rc=0 after 86s, `result changed`, `dropped 0`. Journal: `br-1794087574 bridges changed <hex> -> <hex> (7 bridges); adopted at the proxy's next start, no restart`. Refreshes resumed.

mac, `nice-dns bridges on` in the gui session (21:40:22 UTC):
```
rc=0 elapsed=15s
Restarting the proxy...
Waiting for the DNS chain to come up at 172.31.240.250 (Tor bootstrap takes 1-4 min)...
Chain is resolving, and Unbound resolves over its authenticated route.
Bridges are on; the proxy restarted and DNS is answering.
```
Supervisor: `tor-supervisor: spawned tor pid=28 generation=1 with 7 bridge(s)`. Journal: `mode-change on`, `stack restart` requested, acknowledged, then `ready observed working 18s after the acknowledgement`.
Forced refresh -> rc=0 after 41s, `result changed`, `dropped 0`. Journal: `br-1794087686 bridges changed ... (7 bridges); adopted at the proxy's next start, no restart`.

On both targets, `bridges status` still printed `last_refresh never` after these refreshes (finding F3).

## Outcome S1-3

> Not installed → the usual not-installed message, exit 1.

Verdict: holds (both targets).

Evidence: each command ran with `HOME=$(mktemp -d)`, with stdout and stderr captured apart.

mint:
| command | rc | stdout | stderr |
|---|---|---|---|
| `bridges status` | 1 | (empty) | ``nice-dns: nice-dns is not installed; run `nice-dns install` `` |
| `bridges off` | 1 | (empty) | same |
| `bridges on` | 1 | (empty) | same |
| `restart` (reference) | 1 | (empty) | same |
| `status` (reference) | 1 | status rows (`install installed no`, hint) | same |

The throwaway HOME was still empty afterwards. The real mode file was still `TOR_BRIDGES=on`.

mac (gui session, `env HOME=<mktemp -d>`): `bridges status`, `bridges off`, `bridges on` and `restart` each gave rc=1, empty stdout, and the same stderr line. The throwaway HOME stayed empty. The real mode file was still `TOR_BRIDGES=on`.

## Outcome S1-4

> A bad argument → usage, exit 2.

Verdict: holds (both targets).

Evidence:

mint:
| command | rc | first stderr line |
|---|---|---|
| `nice-dns bridges` | 2 | `nice-dns: bridges takes one of on, off, status` |
| `nice-dns bridges maybe` | 2 | `nice-dns: unknown option 'maybe' for bridges` |
| `nice-dns bridges OFF` | 2 | `nice-dns: unknown option 'OFF' for bridges` |
| `nice-dns bridges off extra` | 2 | `nice-dns: bridges takes one of on, off, status` |
| `nice-dns bridges --help` | 2 | `nice-dns: unknown option '--help' for bridges` |

In each case the full usage followed on stderr. Usage includes `bridges on|off|status` and its description. Stdout was empty. The mode stayed `on`, and the supervisor line was still `with 7 bridge(s)`, pid 28.

mac: `bridges`, `bridges maybe` and `bridges off extra` gave rc=2, the same first lines and a 32-line usage that includes the `bridges on|off|status` entry. The mode stayed `on`, and the supervisor line was unchanged.

## Outcome S1-5

> The mode file cannot be written → the error names the path; nothing else changes.

Verdict: holds (mint; the brief limits this to mint).

Evidence:
```
orig dir mode=700
644 1794057339 15 /home/user/.config/nice-dns/bridges-mode.env      (mode, mtime, size before)
tor-socat StartedAt 2026-11-07 13:15:40.652954953 +0000 UTC
4 entries in ~/.config/nice-dns
chmod a-w ~/.config/nice-dns  -> 500
== nice-dns bridges off
rc=1
-- stdout: (empty)
-- stderr:
nice-dns: could not write /home/user/.config/nice-dns/bridges-mode.env; the bridges mode is unchanged
chmod 700 restored -> 700
644 1794057339 15 .../bridges-mode.env  (unchanged), content TOR_BRIDGES=on
4 entries (no temp file left behind)
tor-socat StartedAt unchanged; supervisor line unchanged (with 7 bridge(s))
bridges status -> mode on, count 7
```
bridges.env was not touched.

## Outcome S2-1

> Works: per platform, `off` restarts the proxy, the supervisor line says `direct (no bridges)`, a fresh name answers within 10 min, a forced refresh journals `skipped`; `on` brings `with N bridge(s)` back and a fresh name answers.

Verdict: holds on mac. On mint it holds except for one claim: "`off` restarts the proxy" was not shown. Over plain ssh, `off` wrote the mode, but its restart failed with `Failed to connect to bus: No medium found` (F1). The pre-existing `nice-dns restart` fails the same way in that session. To keep to one off/on pair, `off` was not re-run in a session that has the user bus. Every other mint claim was observed.

Evidence:
- mac: see S1-1 and S1-2. `off` restarted the stack and printed `direct (no bridges)`. A fresh name answered right after the 22s command, and the forced refresh journaled `skipped`. `on` restarted the stack and printed `with 7 bridge(s)`. A fresh name answered (`status: NOERROR`).
- mint: the restart for `off` failed (S1-1 evidence). `nice-dns restart` in a session with `XDG_RUNTIME_DIR=/run/user/1000` then started the proxy `direct (no bridges)`. A fresh name answered at once, and the forced refresh journaled `skipped`. `on` in the same kind of session restarted only the proxy: tor-socat StartedAt moved 21:37:18 -> 21:37:49, and the journal shows `proxy restart` requested, acknowledged, ready. It printed `with 7 bridge(s)`, and a fresh name answered `NOERROR`.

## Outcome S2-2

> A target is unreachable → that check is `[~]` with the reason.

Verdict: cannot reach by the user's route.

Evidence: this outcome is about the receipt that `bash tests/run.sh receipt bridges-toggle` produces. The brief forbids running the repo's test suite, and no other user route makes a receipt. No unreachable target was caused.
Read-only context, not a substitute: `~/.local/state/nice-dns-tests/receipts/bridges-toggle/20261107T111101Z-743b291d/receipt.tsv` has `cell macos socat standard mac generation= failed`. Its `cells/macos-socat-standard/cell.tsv` holds only cell/proxy/source_sha/adapter/target rows, with no reason. No file under that receipts tree contains `[~]`. Whether the Mac was unreachable in that run, and how the rendered receipt shows it, could not be seen.

## Final state (checked last, 21:41:57 UTC)

- mint: `bridges status` -> `mode on`, `count 7`. Mode file `TOR_BRIDGES=on`. Dir 700, file 644 (as before). Supervisor `with 7 bridge(s)`. All four containers up and healthy. A fresh name answers `NOERROR`.
- mac: `bridges status` -> `mode on`, `count 7`. Mode file `TOR_BRIDGES=on`. Supervisor `with 7 bridge(s)`. A fresh name @172.31.240.250 answers `NOERROR`.

## Findings

- F1 (Material): on mint, plain `ssh mint '~/.local/bin/nice-dns bridges off'` cannot restart the proxy. The session has no `XDG_RUNTIME_DIR`, and `systemctl --user` fails with "No medium found". The command handles this well: it writes the mode, says the restart failed and that the mode takes effect at the next proxy start, and exits 1. The cause is the session, not the toggle. `nice-dns restart` fails the same way, and `nice-dns-health status` shows "Last service run: Failed to connect to bus". The brief said plain ssh works on mint; it did not this time. A receipt cell that drives mint over plain ssh would hit the same failure.
- F2 (Material): after a failed restart, `bridges status` says `off`, but the running proxy still uses 7 bridges. Running `nice-dns bridges off` again prints "Bridges are already off; nothing restarted." and exits 0. The error does not say how to apply the mode. The way out is `nice-dns restart` (the whole stack), and neither the error nor the README names it.
- F3 (Material): `last_refresh` stays `never` in `nice-dns bridges status` and in `nice-dns status`, on both targets. It stayed `never` even after a forced refresh journaled `bridges changed` (mint 21:39:34, mac 21:41:26 UTC). The README says `bridges status` "prints the mode, the bridge count and the last refresh."
- F4 (Minor): on macOS, `bridges off|on` prints "Restarting the proxy..." and "the proxy restarted". It actually restarts the whole stack: all three containers got new start times, and the journal says `stack restart`. The README says "(on macOS, the whole stack)".

No Blocking finding comes from a product failure. S2-2 is "cannot reach by the user's route" only because the brief forbids running the receipt. The mint `off` restart claim in S2-1 was not shown in a session with the user bus.
