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
| `controller` | `mode active\|shadow\|not-installed`; `last_pass <epoch>\|never`; `verdict <text>\|unknown` — `OK`, `FAIL [<names>]` (optionally followed by ` indeterminate=(<names>)`) or `INDETERMINATE [<names>]`; `stale no\|<seconds>\|never\|future` — a pass older than 300 s is stale, and its observations are still printed; `future` is a pass dated after the clock (the clock moved back), also stale; `schedule loaded\|stopped`; when the state cannot be read, `unreadable <reason>`. |
| `obs` | The last pass's records, one per observation: `obs<TAB><name><TAB><verdict><TAB><ms><TAB><reason>`, with `<name>` like `container:pi-hole` or `route:cloudflare-onion` and `<verdict>` `healthy\|unhealthy\|indeterminate`. Absent when no pass was recorded. |
| `route` | `selected <route id> <state generation>`, from the controller's state. Absent before the controller has chosen a route. |
| `bridges` | `mode on\|off` (`on` unless the bridges toggle wrote `TOR_BRIDGES=off`); `count <n>` (bridge lines in `bridges.env`); `last_refresh <epoch>\|never`. |
| `update` | `result current\|available\|unknown`; with a cache, `checked_at <epoch>` and `remote_commit <sha>`; with none, `result unknown never-checked`. Only `nice-dns update --check` and `nice-dns update` write the cache. |
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
directory; the proxy reads it at its next start. They never touch `bridges.env`,
the bridge pool, so `on` uses the last good set again. Nothing reads the mode
file as shell: it is parsed for the `TOR_BRIDGES` line only.

With bridges off, the ISP no longer sees obfs4 traffic. It sees plain
connections to Tor guards: it can tell Tor is in use, though still not what is
looked up. `off` says so before its answer.

### Exit codes and output

The last line on stdout is the answer.

| Code | Last line on stdout | Meaning |
|---|---|---|
| 0 | `takes effect at the next proxy start` | `on` or `off`: the mode file now holds that mode. `off` prints the note about what the ISP sees before it. |
| 0 | `last_refresh <epoch>\|never` | `status`: the `bridges` rows of `status --tsv` without the group column, in order: `mode<TAB>on\|off`, `count<TAB><n>` (bridge lines in `bridges.env`), `last_refresh<TAB><epoch>\|never`. |
| 1 | — | Nothing is installed (stderr: ``nice-dns is not installed; run `nice-dns install` ``); the mode file is not written. Or `on`/`off` could not write the mode file: stderr names its path, and the mode and everything else are unchanged. |
| 2 | — | A usage error (no subcommand, another word, or more than one), with nothing on stdout; or `status` found a file it reads there but unreadable (an `unreadable<TAB><reason>` line, as in `status`). |
