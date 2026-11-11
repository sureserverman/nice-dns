# The `nice-dns` command contract

What scripts and the GUIs may rely on. The GUIs pin to this file: a change to a
row, a key or an exit code here is a change to the contract.

## `nice-dns status [--tsv]`

Schema line: `schema<TAB>nice-dns-status/1`, always the first row of `--tsv`.

`status` reads files only: the install's current generation, the controller's
receipt, its last observations (`observations.tsv`, which the controller writes
after every pass), its state and journal, the bridge files and the update-check
cache. It runs no probe, no container runtime, no scheduler and no network
call, so it answers in well under a second and may be polled every few seconds.
Values never carry control characters (tabs included); each is at most 200
characters. `obs` rows keep their tab separators and are cut at 400 characters.
A file `status` reads that is there but cannot be read — permissions, a parent
directory that cannot be entered, the wrong kind of file, or content that is not
what the controller writes — is never read as absent: its group gets a
`<group> unreadable <reason>` row (the reason names the file, under `~/`) and the
exit code is 2. Implemented by `lib/status.sh` (`nd_status_rows`); `nice-dns status`
without `--tsv` prints the same rows as sections.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | The rows were printed. A stale controller is still exit 0; read `controller stale`. |
| 1 | Nothing is installed: `install installed no` and `install hint <the README's curl line>`. |
| 2 | A file `status` reads cannot be read (see the `unreadable` rows; 2 wins over 1, and the `install hint` row is still printed). Also, with nothing on stdout, a usage error, or an installed command whose kept source predates `status` (the message on stderr says to reinstall). |

### Rows

Every row after the schema line is `<group><TAB><key><TAB><value>[<TAB><value>...]`,
except `obs`, which is the controller's observation record copied as written.
Rows of a group come together, in this order of groups.

| Group | Keys and values |
|---|---|
| `install` | `installed yes\|no`; when installed: `generation <id>`, `source_commit <sha or unknown>`, `branch <name>`, `variant haproxy\|socat`, `pihole standard\|hardened`, `platform linux\|macos`, `lock sha256:<digest of release/images.lock>`; when not: `hint <the README's install line>`, which the `nice-dns` command adds (the library itself names no command). |
| `controller` | `mode active\|shadow\|not-installed`; `last_pass <epoch>\|never`; `verdict <text>\|unknown` — `OK`, `FAIL [<names>]` (optionally followed by ` indeterminate=(<names>)`) or `INDETERMINATE [<names>]`; `stale no\|<seconds>\|never\|future` — a pass older than 300 s is stale, and its observations are still printed; `future` is a pass dated after the clock (the clock moved back), also stale; `schedule loaded\|stopped` — `stopped` when the schedule is not installed or `nice-dns-health stop` stopped it (on macOS the stop keeps the agent's plist and leaves `schedule-stopped` beside the controller's receipt; `start` and an install remove it); when the state cannot be read, `unreadable <reason>`. |
| `obs` | The last pass's records, one per observation: `obs<TAB><name><TAB><verdict><TAB><ms><TAB><reason>`, with `<name>` like `container:pi-hole` or `route:cloudflare-onion` and `<verdict>` `healthy\|unhealthy\|indeterminate`. Absent when no pass was recorded. |
| `route` | `selected <route id> <state generation>`, from the controller's state. Absent before the controller has chosen a route. |
| `bridges` | `mode on\|off` (`on` unless the bridges toggle wrote `TOR_BRIDGES=off`); `count <n>` (bridge lines in `bridges.env`); `last_refresh <epoch>\|never`. |
| `update` | `result current\|available\|unknown`; with a cache, `checked_at <epoch>` and `remote_commit <sha>`; with none, `result unknown never-checked`. Only `nice-dns update --check` and `nice-dns update` write the cache, and the controller's twice-daily `nice-dns-health update-check`, which runs `nice-dns update --check` and keeps a check that did not finish as `unknown`. `auto loaded\|stopped` — `loaded` when that twice-daily check is scheduled (Linux: the `nice-dns-health-update.timer` enable link; macOS: the `org.nice-dns.health-update` plist with no `schedule-stopped` mark); `stopped` when it is not installed (shadow mode, or an install from before it) or `nice-dns-health stop` stopped it. |
| `helper` | `path <where nice-dns-helper is installed>` (`/usr/libexec/nice-dns-helper` on Linux, `/usr/local/libexec/nice-dns-helper` on macOS); `installed yes\|no` (the file is there and executable; it is never run); `version <v>`, what the current generation recorded after it installed or found the helper (`absent`; `unknown` when there is no generation or it recorded none). The version is the installed file's, whether or not this tree can use it. Actions without a terminal (the GUIs) need it. |
| `admin` | `url <Pi-hole admin URL>`; when installed, `password_path <file holding the admin password>` — the path, never the password. |
| `recent` | The last five rows of the controller's journal, oldest first: `recent<TAB><epoch><TAB><target><TAB><result>`. |

A reader ignores a group or key it does not know; a new key is added without a
schema change, a changed meaning bumps the schema.

## `nice-dns update --check [--branch B]` and `nice-dns update [--force] [haproxy|socat] [--hardened|--standard] [--branch B]`

The check asks GitHub for the newest commit of the recorded branch (or `B`)
with `git ls-remote --heads` and compares it with the installed source commit.
`available` means the two DIFFER — usually the branch is newer, but an install
from a local commit the branch does not have reads as `available` too, and
`update` then installs the branch's commit. The check is the only part of
`status` and `update` that uses the network. Where `timeout` exists (Linux, and
macOS 27) it is the hard bound, 55 s, so the answer comes within a minute; without it, git's low-speed limit ends
only a transfer that has started, not a stalled name lookup or connection.

### Exit codes and output

The last line on stdout is the answer. Without `--check`, the installer's own
output comes before it.

| Code | Last line on stdout | Meaning |
|---|---|---|
| 0 | `current` | `--check`: the installed commit is the branch's. |
| 10 | `available <first 12 hex>` | `--check`: the branch has a different commit. |
| 1 | `unknown: <reason>` | Nothing is installed; the remote could not be reached; the branch does not exist there; git is missing; or the installed source was not a clean commit (`source_commit` not 40 hex, or `source_dirty` not 0). Nothing is installed by `update`, even with `--force`; without `--check`, stderr names `nice-dns reinstall`. |
| 0 | `already current` | Without `--check`, nothing different and no `--force`: nothing is installed. |
| 0 | `updated to <first 12 hex>` | Without `--check`: the branch's commit (with `--force`, even the same one) was installed like `nice-dns reinstall`, from a clone of the checked branch with the recorded choices (options override them; the branch only changes when `--branch` says so), and a second check says `current`. |
| 11 | `installed; the check now says <answer>` | The install finished, but the second check did not say `current` (the branch moved meanwhile, or the new record is not a clean commit). The stack runs what was installed. |
| 3 | — | The install failed (stderr names the installer's exit); the installer kept or restored the running stack, and stderr names `nice-dns reinstall --local`. |
| 2 | — | A usage error: `--local` (update installs the branch, not the kept source), `--check` with `--force` or a choice. |

### The cache `status` reads

A check of the recorded branch writes `update-check.tsv` in the controller's
state directory (0600, renamed over a temporary file):
`schema<TAB>nice-dns-update-check/1`, `checked_at <epoch>`, `branch <name>`,
`local_commit <40-hex sha, or - when the record names none>`, `remote_commit <sha or ->`,
`result current|available|unknown`. A check of another branch (`--branch`) keeps
nothing, and nothing is kept while the controller has no state directory.
`status` prints the cache as the `update` rows; it never asks the remote itself.

## `nice-dns bridges on|off|status`

The bridges mode is one line, `TOR_BRIDGES=on` or `TOR_BRIDGES=off`, in
`~/.config/nice-dns/bridges-mode.env` (0644, no secret). An absent file means
`on`. `on` and `off` write it, renamed over a temporary file in the same
directory. When the mode changed they then restart the proxy (macOS: the whole
stack) as `restart` does: the controller's schedules held and its state lock
taken, the restart journalled (`bridges mode-change <mode>`, then the service
restart's `requested` and `acknowledged`; the controller's next pass adds
`ready`), then a wait for DNS; the schedules are released on every exit. An
unchanged mode is written again and restarts nothing. They never touch `bridges.env`,
the bridge pool, so `on` uses the last good set again. Nothing reads the mode
file as shell: it is parsed for the `TOR_BRIDGES` line only.

With bridges off, the ISP no longer sees obfs4 traffic. It sees plain
connections to Tor guards: it can tell Tor is in use, though still not what is
looked up. `off` says so before its answer.

### Exit codes and output

The last line on stdout is the answer.

| Code | Last line on stdout | Meaning |
|---|---|---|
| 0 | `Bridges are <mode>; the proxy restarted and DNS is answering.` | `on` or `off` changed the mode: the file holds it, the proxy restarted with it and DNS answers. `off` prints the note about what the ISP sees before it. |
| 0 | `Bridges are already <mode>; nothing restarted.` | `on` or `off` asked for the mode already in force (an absent file is `on`). |
| 0 | `last_refresh <epoch>\|never` | `status`: the `bridges` rows of `status --tsv` without the group column, in order: `mode<TAB>on\|off`, `count<TAB><n>` (bridge lines in `bridges.env`), `last_refresh<TAB><epoch>\|never`. |
| 1 | — | Nothing is installed (stderr: ``nice-dns is not installed; run `nice-dns install` ``); the mode file is not written. Or `on`/`off` would change the mode on an install whose proxy launcher does not pass `TOR_BRIDGES` (stderr: `predates the bridges switch` and ``Run `nice-dns update` first``): nothing is written or restarted. Or `on`/`off` could not write the mode file: stderr names its path, and the mode and everything else are unchanged. Or the controller stayed busy (stderr: `still busy`): the mode is unchanged. Or the restart failed (stderr: the mode is written and takes effect at the next proxy start; `nice-dns restart` applies it now, since asking for the same mode again restarts nothing) or DNS did not answer after it (stderr: `not answering yet`). |
| 2 | — | A usage error (no subcommand, another word, or more than one), with nothing on stdout; or `status` found a file it reads there but unreadable (an `unreadable<TAB><reason>` line, as in `status`). |

## `nice-dns switch proxy haproxy|socat` and `nice-dns switch pihole standard|hardened`

A switch reinstalls the source kept at the last install
(`~/.local/share/nice-dns/source`) with that one choice changed: the recorded
branch and the other recorded choice stay. It runs what `reinstall --local`
runs, through the install transaction and its rollback (DEC-018). It never
clones, and the installed commit (`source_commit`) does not change. The
GUIs' actions `proxy-haproxy`, `proxy-socat`, `pihole-standard` and
`pihole-hardened` (gui/share/actions.tsv) run these four commands.

### Exit codes and output

The last line on stdout is the answer; the installer's own output comes before it.

| Code | Last line on stdout | Meaning |
|---|---|---|
| 0 | `Switched: the proxy is now tor-<variant>, and DNS is answering.` or `Switched: Pi-hole is now the <flavour> one, and DNS is answering.` | The install with the new choice finished: the installer returns only after DNS answers through the new stack. `status` shows the new `variant` or `pihole`. |
| 0 | `Already <choice>; nothing changed.` | The choice asked for is the one installed; no installer ran. |
| 1 | — | Nothing is installed (stderr: ``nice-dns is not installed; run `nice-dns install` ``), or there is no kept source (stderr names the missing directory and ``nice-dns reinstall``), or the record names no variant or flavour. Nothing ran. |
| 2 | — | A usage error (no word, an unknown word, or more than two), with nothing on stdout. Nothing ran. |
| 3 | — | The install failed (stderr: `the switch did not happen`, and which proxy or Pi-hole still runs): the installer kept or restored the running stack. |

## Consumers: `nice-dns-gui` (Linux)

`nice-dns-gui` (`gui/linux`, GTK 4 and libadwaita; installed by the Linux
installer from a release asset, `docs/release-inputs.md`) reads this contract
and nothing else:

- It runs `nice-dns status --tsv` when its window opens and every 5 s, and
  refuses any schema but `nice-dns-status/1`. Exit 1 (or 2 with
  `install installed no`) is the not-installed page with the hint; exit 2
  with rows of an installed stack lists the `unreadable` rows; anything else
  is one error page naming what went wrong.
- Every button, the bridges switch and the update banner is a row of
  `gui/share/actions.tsv`: the command words it runs as a subprocess of
  `nice-dns` or `nice-dns-health` (the first on `PATH`, else where the
  installer put them), with no shell. It reads exits and last lines as the
  tables above say: `update --check` 0 and 10 are answers, `update` 11 is an
  install whose re-check disagreed, and a root step a person dismissed or
  could not authorise shows `authorisation cancelled` or `not authorised`.
- The Installed section's Proxy selector (haproxy, socat) and Pi-hole
  selector (standard, hardened) are the rows `proxy-haproxy`, `proxy-socat`,
  `pihole-standard` and `pihole-hardened` (`nice-dns switch ...`). Each shows
  the `install variant` / `install pihole` row; a missing or other value
  disables it and shows `unknown`. Picking the other value asks first; while
  the switch runs the selector shows the new value, and a failed switch (or
  Not now) puts it back on the installed one. No row is drawn in two places.
- One action runs at a time (both selectors are disabled while one runs);
  uninstall (typed), reinstall, update and a switch ask first.

Its hooks are for tests and live proofs, not for people:

| Hook | What it does |
|---|---|
| `--check` | Reads the status once with no display; prints one line; exit 0 installed, 1 not installed or no `nice-dns` (the line names the path looked for), 2 otherwise. |
| `--screenshot <png>` | Shows the window for the status, renders it into `<png>` and exits (needs a display; Xvfb will do). |
| `--run-action <id> --exit` | Runs one action of the table with no dialog, prints the log pane and exits with the action's status. |
| `--probe <id>` | Clicks `id` as a person would and prints what the window shows before, during and after (the test suite's hook). For a selector id it prints the question with its dialog open, then answers Switch, so the switch really runs; with `NICE_DNS_GUI_PROBE_ANSWER=cancel` it answers Not now. |
| `--version` | `nice-dns-gui <version>`. |

`NICE_DNS_GUI_STATUS_CMD` replaces the status command for the fixture tests.

## Consumers: `nice-dns.app` (macOS)

The menu-bar app (`gui/mac`, Swift; installed by the macOS installer into
`~/Applications/nice-dns.app` from a release asset, `docs/release-inputs.md`)
reads this contract the same way as the Linux GUI: `nice-dns status --tsv`
when it starts and every 5 s, schema `nice-dns-status/1` only, and every
menu item, button and the bridges switch is a row of its bundled copy of
`gui/share/actions.tsv` (checked against the shared table at build time). It
finds `nice-dns` on `PATH`, else in `~/.local/bin`, else where the installer
falls back to; the commands it runs get `~/.local/bin`, `/opt/homebrew/bin` and
`/usr/local/bin` on their `PATH`. The menu-bar glyph is grey when nothing is
installed; red when the status cannot be shown, the controller's verdict is
`FAIL` or an observation is `unhealthy`; amber when the controller is stale,
its verdict is not `OK`, an observation is not `healthy` or a file status reads
is unreadable; green otherwise (gui/mac/Sources/NiceDNSKit/Session.swift). The window's
Proxy and Pi-hole pickers and the menu's two submenus (a check mark on the
installed value) are the same four `switch` rows, set and reverted as on
Linux. One action runs at a time; uninstall (typed), reinstall and a switch
ask first.

Its hooks are for tests and live proofs. The program is
`~/Applications/nice-dns.app/Contents/MacOS/NiceDNSGUI`; over ssh, run it in
the user's gui domain (`launchctl asuser`), where the stack's commands see the
container runtime.

| Hook | What it does |
|---|---|
| `--check` | Reads the status once; prints one line; exit 0 installed (`installed: generation <g>; controller <verdict>, <freshness>`), 1 not installed or no `nice-dns` (the line names the path looked for), 2 otherwise. |
| `--screenshot <png>` | Draws the window for the current status into `<png>` from an off-screen window (no Screen Recording permission) and exits. |
| `--run-action <id> --exit` | Runs one action of the table with no dialog, prints the output pane and exits with the action's status; an action that runs no command (`open-admin`, `show-password-path`) is refused with exit 2. |
| `--version` | `nice-dns-gui <version>` (the release tag without its `v`). |

`NICE_DNS_GUI_STATUS_CMD` replaces the status command for the fixture tests.
