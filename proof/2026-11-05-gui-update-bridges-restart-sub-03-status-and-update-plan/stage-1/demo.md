# Stage 1 demo — 2026-11-05-gui-update-bridges-restart-sub-03-status-and-update-plan

Environment: laptop (Linux 7.0.0-42-generic, bash), checkout /home/user/dev/containers/nice-dns on branch
status-update at 97ae7b0, 2026-11-06 ~19:20 UTC. Evaluator did not read lib/status.sh, the `nice-dns` source or the diff;
only the user route (`./nice-dns status [--tsv]` from the checkout), docs/cli-contract.md and README.md.
Real install: read-only `status` only. Failure cases: scratch HOME made with `mktemp -d` (under the session scratchpad),
populated by read-only copies of `~/.local/state/nice-dns-install/`, `~/.local/state/nice-dns/controller/{state.tsv,recovery.tsv}`
and `~/.local/share/nice-dns-health/install.tsv`. No bridge file and no secret was copied or printed; a synthetic
`bridges.env` with RFC 5737 fake lines stood in. A hand-written `observations.tsv` stood in for a controller pass.
Every scratch run: `HOME=<S> XDG_STATE_HOME= XDG_CONFIG_HOME= XDG_DATA_HOME= ./nice-dns status [--tsv]`.
Scratch directories removed at the end.

Plan goal command (`grep -q 'nice-dns-status/1' docs/cli-contract.md && grep -q 'nice-dns-status/1' lib/status.sh && ./nice-dns status --tsv | head -n 1 | grep -q 'nice-dns-status/1'`): exit 0.
Blocking-command gate grep (`grep -Ec '(podman|container|dig|curl|git) ' lib/status.sh`): 0 matches, exit 1 (gate passes).
`strace -f -e execve ./nice-dns status --tsv`: children are only awk, cut, tr, date, id, uname, cat, dirname (plus PATH lookups for bash).
No podman, systemctl, dig, curl or git. Wall time on the real install: 0.107 s.

| Outcome | Verdict |
|---|---|
| 1 Works: sections + `--tsv` rows | holds |
| 2 Not installed → `installed no`, curl line, exit 1 | holds |
| 3 Stale / never-run controller | holds |
| 4 State directory unreadable → `controller unreadable`, exit 2 | holds (one variant falls short, see Material 1) |
| 5 No update check → `update unknown never-checked` | holds |

## Outcome 1
> Works: `nice-dns status` prints sections (install, controller, containers, routes, bridges, update, admin, recent actions); `--tsv` prints the same as `schema nice-dns-status/1` rows.
Verdict: holds
Evidence:
Real install, `./nice-dns status` → exit 0, sections in order: Install, Controller, Containers, Routes, Bridges, Update, Admin, Recent actions.
```
Install
  installed       yes
  generation      20261104T064129Z-0fe6c62809e3
  source_commit   0fe6c62809e35dd8a631680a4177e288baefbfcf
  branch          main
  variant         haproxy
  pihole          standard
  platform        linux
  lock            sha256:c6d93a0d...d863
Controller
  mode            active
  last_pass       never
  verdict         unknown
  stale           never
  schedule        loaded
Containers (stale: no pass recorded)
  (none observed)
Routes (stale: no pass recorded)
  selected               cloudflare-onion (generation 30983)
Bridges
  mode            on
  count           7
  last_refresh    1793860831
Update
  result          unknown never-checked
Admin
  url             http://localhost:8880/admin
  password_path   /home/user/.local/state/nice-dns/secrets/pihole/pihole_webpassword
Recent actions
  1793950588  route:cloudflare-exit      acknowledged
  ... (5 rows, oldest first) ...
  1793951043  route:cloudflare-onion     ready
```
(`last_pass never` on the real laptop is expected: its installed controller predates this work — Premise 4.)

Real install, `./nice-dns status --tsv | cat -A` → exit 0, first row `schema<TAB>nice-dns-status/1`, then the same
values as tab-separated rows: `install installed yes` … `controller schedule loaded`, `route selected cloudflare-onion 30983`,
`bridges mode on / count 7 / last_refresh 1793860831`, `update result unknown never-checked`, `admin url …`,
`admin password_path …` (path only, no password), five `recent <epoch> <target> <result>` rows. Every field tab-separated, no stray characters.

Scratch HOME with a fresh stand-in pass (`pass <now-30> OK`, four `obs` rows) → exit 0:
```
Controller
  last_pass       1793992570
  verdict         OK
  stale           no
Containers
  pi-hole                healthy       ok
  unbound                healthy       ok
  tor-haproxy            healthy       ok
Routes
  selected               cloudflare-onion (generation 30984)
  cloudflare-onion       healthy       answered
```
and `--tsv` carried the four `obs<TAB>…` rows verbatim between the `controller` and `route` groups, as the contract orders them.
`./nice-dns status --bogus` → `nice-dns: unknown option '--bogus' for status` + usage, exit 2 (see Minor 1).

## Outcome 2
> Not installed → `installed no` and the README's curl line; exit 1.
Verdict: holds
Evidence:
Empty scratch HOME (`mktemp -d`, nothing in it), `./nice-dns status` → exit 1:
```
Install
  installed       no
  hint            curl -fsSL https://raw.githubusercontent.com/sureserverman/nice-dns/main/install-deb.sh -o install-deb.sh && bash install-deb.sh
Controller
  mode            not-installed
  last_pass       never
  ...
Update
  result          unknown never-checked
Admin
  url             http://localhost:8880/admin
Recent actions
  (none)
```
`--tsv` → exit 1, rows `schema nice-dns-status/1`, `install installed no`, `install hint curl -fsSL … && bash install-deb.sh`,
`controller mode not-installed`, …; no `password_path` row. The hint matches README.md line 45 byte for byte.
The empty HOME was still empty afterwards (status wrote nothing). The macOS hint (README line 48) cannot be reached on this Linux host.

## Outcome 3
> The controller has not run, or its last pass is older than 5 minutes → `controller stale <seconds>` and the observations are marked stale, still printed.
Verdict: holds
Evidence:
Older than 5 minutes: scratch `observations.tsv` with `pass <now-600> FAIL [unbound] indeterminate=(route:cloudflare-onion)` and four obs rows → exit 0:
```
Controller
  last_pass       1793992008
  verdict         FAIL [unbound] indeterminate=(route:cloudflare-onion)
  stale           600
Containers (stale: last pass 600 s ago)
  pi-hole                healthy       ok
  unbound                unhealthy     timeout
  tor-haproxy            healthy       ok
Routes (stale: last pass 600 s ago)
  selected               cloudflare-onion (generation 30984)
  cloudflare-onion       indeterminate no-answer
```
`--tsv`: `controller stale 600` and all four `obs` rows still printed.
Boundary: pass 299 s old → `controller stale no`; 301 s old → `controller stale 301`.
Has not run: real install and scratch HOME without `observations.tsv` → `last_pass never`, `verdict unknown`,
`stale never`, sections headed `(stale: no pass recorded)`, exit 0. With no pass there are no seconds to report; the
contract documents `stale never` for this case (Minor 2 on wording).

## Outcome 4
> The state directory is unreadable → `controller unreadable <reason>`; exit 2.
Verdict: holds
Evidence:
Scratch `~/.local/state/nice-dns/controller` set to mode 000 → exit 2 in both forms:
```
Controller
  mode            active
  unreadable      cannot read <S>/.local/state/nice-dns/controller
  last_pass       never
  ...
```
`--tsv`: `controller<TAB>unreadable<TAB>cannot read <S>/.local/state/nice-dns/controller`, exit 2; install, bridges,
update and admin rows still printed.
Scratch `observations.tsv` set to mode 000 → `controller unreadable cannot read <S>/…/controller/observations.tsv`, exit 2.
Shortfall: the parent `~/.local/state/nice-dns` set to mode 000 (controller dir then unreachable) → exit 0, `last_pass never`,
no `unreadable` row, route and recent rows silently gone (Material 1).

## Outcome 5
> No update check yet → `update unknown never-checked`.
Verdict: holds
Evidence:
Real install (no update cache), scratch HOME and empty HOME all printed `Update / result unknown never-checked`,
and in `--tsv` `update<TAB>result<TAB>unknown<TAB>never-checked`. No cache-present case was tried: only Stage 2's
`nice-dns update [--check]` writes the cache.

## Findings

Blocking: none.

Material
1. An unreachable controller state shows as "never ran" with exit 0. With `~/.local/state/nice-dns` unreadable
   (mode 000), status prints `last_pass never`, `stale never`, no `controller unreadable` row, and drops the `route`
   and `recent` rows, exit 0. A GUI would tell the owner the controller has never run while its state exists.
   The contract's exit 2 covers "the controller's state directory … cannot be read"; this variant reaches the same
   state directory through an unreadable parent and is not caught.
2. An unreadable `state.tsv` (mode 000, controller dir readable) drops the `route selected` row with exit 0. Per the
   contract an absent `route` row means "the controller has not chosen a route", so the reader is misled.
   A garbled `observations.tsv` (one non-TSV line) is likewise reported as `last_pass never`, exit 0, with no hint
   that the file exists but is unusable.

Minor
1. A usage error (`status --bogus`) also exits 2, the code the contract reserves for "controller unreadable". A script
   cannot tell a bad flag from an unreadable state by exit code alone.
2. Outcome 3's wording says `controller stale <seconds>` for "has not run"; the product prints `stale never` (as the
   contract documents). Behaviour is sensible; the outcome text and contract differ.
3. With the controller dir unreadable, the human view prints `Routes (stale: no pass recorded)` with an empty body
   and `Recent actions (none)`; "unknown" would be more honest than "none".
4. The `unreadable` reason carries the full absolute path. With a long HOME it nears the contract's 200-byte value
   cap (here about 150 bytes).
5. Not verified, not a finding: `bridges mode off`. Writing `TOR_BRIDGES=off` into a synthetic `bridges.env` still
   gave `mode on`, and synthetic `Bridge obfs4 …` lines gave `count 0` (real install shows `count 7`). The contract
   does not say which file the toggle writes or the exact bridge-line format, so the synthetic input may simply be wrong.
   The contract could name the file.
