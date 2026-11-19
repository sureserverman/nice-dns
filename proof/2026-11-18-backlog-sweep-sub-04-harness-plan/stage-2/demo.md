# Plan demo — 2026-11-18-backlog-sweep-sub-04-harness-plan

Environment: this checkout at 59b1f9e (branch sweep-harness), run 2026-11-19
~21:05Z from the laptop. Targets from tests/live/targets.env: `mint` (Linux
Mint 22.3, podman 5.8.1, tor-socat) and `mac` (macOS 27.2.1, container CLI
1.7.1, tor-socat), over ssh. Bounds: read-only target ops only; no
`tests/run.sh` groups; no suspend, fault, install-cell or command op. Every
remote call wrapped in `timeout 120`. No background job was started by the
evaluator.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

# Stage 1

## Outcome 1
> A live group's privacy case fails when the run left no report to scan, so a green privacy line means evidence was scanned.
Verdict: not shown here
Evidence:
- Needs: a live group run (`tests/run.sh live <group> --live`) on mint or mac
  whose run leaves no report. Live group runs are out of bounds for this
  session (they are Sub-plan 5's).
- What was seen by the operator's route: every changed group's `--dry-run`
  lists its privacy case, e.g. `all tl_privacy      no bridge material,
  session or hash in the evidence` (transport-live), `all bt_privacy ...`
  (bridges-toggle), `cr_privacy ...` (command-recovery), `gm_privacy ...`
  (gui-mac). The dry-run text does not say an empty scan fails.
- The record the goal names exists: docs/qualification.md line 307-312,
  "the live privacy cases ... fail a run that left no report to scan
  (BL-057). A 12-character fingerprint prefix is allowed in evidence ...".

## Outcome 2
> A bridges switch fails unless the spawn line it judges is of the generation it started, and, with bridges on, names at least one bridge.
Verdict: not shown here
Evidence:
- Needs: a live `bridges-toggle` run on mint or mac (it switches bridges on
  the target), plus a target whose proxy does not respawn, to see the fail.
  Out of bounds here.
- `bash tests/live/bridges-toggle.sh --dry-run` (rc 0) states the judgment:
  `bt_off ... proxy-supervisor-lines: the latest spawn, of the container that
  row names, is direct (no bridges)` and `bt_on ... the latest spawn, of the
  container that row names, is with N>=1 bridge(s)`.
- The read-only input it judges, `target.sh proxy-supervisor-lines <alias>
  --targets tests/live/targets.env` (rc 0 on both):
  - mint: `supervisor_line tor-socat tor-supervisor: spawned tor pid=12 generation=1 direct (no bridges)`
  - mac: `supervisor_line tor-socat tor-supervisor: spawned tor pid=28 generation=1 with 7 bridge(s)`
  So the spawn lines carry a generation and a bridge count to judge.

## Outcome 3
> An install cell or a command op that never returns ends at its outer limit with `timeout` and the op's name, and the cell fails.
Verdict: not shown here
Evidence:
- Needs: an `install-cell` or `command` op against a target that never
  returns (a hung remote), run to its outer limit. Both ops change a target
  and are out of bounds here.
- Seen: `target.sh install-cell` and `target.sh command` with no alias are
  refused before anything is sent: `target.sh: usage: target.sh install-cell
  ALIAS --targets FILE` / `... command ALIAS --targets FILE`, rc 2.

# Stage 2

## Outcome 4
> After a suspend on a Linux target with no default route, the harness brings the Wi-Fi back once and notes `wifi-recovered`, or fails the cell with `no default route after the wake`.
Verdict: not shown here
Evidence:
- Needs: `collect --after-sleep` on mint (it suspends mint), with the Wi-Fi
  left down after the wake. Suspending mint is out of bounds (its Wi-Fi can
  stay down for hours).
- No operator doc names `wifi-recovered` or `no default route after the
  wake` (grep over docs/ found neither).

## Outcome 5
> `target.sh collect --after-sleep SECS --first-answer CAP` prints a `first_answer` row and the route and proxy generation before the sleep and after the answer; the frozen one-query wake sample is unchanged.
Verdict: not shown here
Evidence:
- Needs: a real `collect --after-sleep 30 --first-answer N` on mint or mac
  (it suspends the target). Out of bounds here.
- The options exist and are guarded before anything is sent. Run against a
  scratch targets file whose `mint` host is `demo-unreachable.invalid`, so
  nothing could reach a real machine:
  - `--after-sleep abc` -> `target.sh: --after-sleep must be 30..600 (seconds)`, rc 2
  - `--after-sleep -5` -> same message, rc 2
  - `--after-sleep 30 --first-answer abc` -> `target.sh: --first-answer must be 30..600 (seconds)`, rc 2
  - `--first-answer 30` alone -> `target.sh: --first-answer needs --after-sleep`, rc 2
  - `--bogus` -> `target.sh: unknown option '--bogus'`, rc 2
- The route and generation that the row would carry are readable today:
  `route-report` mint `desired cloudflare-onion 12957`, `readback
  cloudflare-onion 12957 127.0.0.1`; mac `desired cloudflare-onion 13000`,
  `readback cloudflare-onion 13000 172.31.240.252`; both `client_fresh NOERROR`.

## Outcome 6
> `tests/run.sh live transport-live` exists with a fixture twin, and its three scenarios fail on a target that does not validate DNSSEC, listens on TCP 8953, or answers under a wrong TLS name.
Verdict: not shown here (the "exists with a fixture twin" half holds; the "fails on a bad target" half is not shown)
Evidence:
- `bash tests/run.sh --list`: `live transport-live live cases=7 OK
  tests/live/transport-live.sh` and `integration transport-live-dryrun local
  cases=7 OK tests/integration/transport-live-dryrun.sh`.
- Gate grep for the six twins in tests/manifests/groups.tsv: rc 0.
- `bash tests/live/transport-live.sh --dry-run` (rc 0) prints `dry run: no
  target is touched` and, per platform, `tl_before`, `tl_dnssec` (TL-DNSSEC:
  signed and unsigned answer, dnssec-failed.org SERVFAIL, `ad` at Unbound on
  the signed name only), `tl_control` (no TCP 8953 listener, control is a
  Unix socket that answers), `tl_tls_negative` (fault-route --mode tls-name,
  fresh name SERVFAIL 3 tries, heal-route, answers within 600 s),
  `tl_after`; then `tl_privacy`, `tl_receipt`.
- The read-only op the first two scenarios read, `target.sh transport-report
  <alias> --targets tests/live/targets.env`, rc 0 on both, identical shape:
  mint (route generation 12957) and mac (13000):
  `dnssec unbound signed cloudflare.com NOERROR ad`,
  `dnssec unbound unsigned neverssl.com NOERROR noad`,
  `dnssec client bogus dnssec-failed.org SERVFAIL noad`,
  `control tcp_8953 none`, `control interface /run/unbound/control.sock`,
  `control socket unix`, `control answers yes`.
  So both healthy targets would pass; the report gives the fields a failing
  target would trip on.
- Needs, to show the fail half: a target that does not validate DNSSEC or
  has a TCP 8953 listener (a deliberately misconfigured Unbound), and a
  `fault-route --mode tls-name` run (changes the target). Out of bounds here.

# Gate checks run by the evaluator (read-only)

- Goal grep (`BL-025 026 042 057 060` in tests/integration|unit, and
  `fingerprint prefix` in docs/qualification.md): rc 0.
- Twin grep over tests/manifests/groups.tsv: rc 0.
- `shellcheck` over the six changed scripts: rc 0, no output.
- The mawk run and the plan-scope pass were not run here (a pass was
  already running in the background; bounded out).

# Findings

- Minor: `target.sh collect` with no alias prints `usage: target.sh collect
  ALIAS --targets FILE`; it does not name `--after-sleep` or
  `--first-answer`. `target.sh --help` is refused as an unknown operation.
  The operator finds the new options only from their refusals.
- Minor: `bash tests/live/install-lifecycle.sh --dry-run` (this branch adds
  4 lines to it) prints `line 61: /tests/live/fault-lib.sh: No such file or
  directory` and exits 0. On main the same call printed nothing and exited
  0, so the direct call was never a working route. The other changed groups
  dry-run fine when run directly. controller-wake.sh and tune-idle-wake.sh
  show the same missing-path error on main and here (not this plan's).
- No Blocking finding: no outcome was seen to not hold. All six are "not
  shown here" because each needs a live run, suspend or fault this session
  may not do.
