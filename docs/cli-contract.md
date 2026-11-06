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

## `nice-dns update [--check] [--force] [haproxy|socat] [--hardened|--standard] [--branch B]`

The check asks GitHub for the newest commit of the recorded branch (or `B`)
with `git ls-remote --heads` and compares it with the installed source commit.
It is the only part of `status` and `update` that uses the network, bounded by
git's low-speed limit and, where `timeout` exists, by 90 s.

### Exit codes and output

| Code | Output (stdout) | Meaning |
|---|---|---|
| 0 | `current` | `--check`: the installed commit is the branch's newest. |
| 10 | `available <first 12 hex of the commit>` | `--check`: the branch has a newer commit. |
| 1 | `unknown: <reason>` | The remote could not be reached, the branch does not exist there, or the installed source was not a clean commit (`source_commit` not 40 hex, or `source_dirty` not 0). Nothing is installed, even with `--force`; stderr names `nice-dns reinstall`. Also: nothing is installed at all. |
| 0 | `already current` | Without `--check`, with nothing newer and no `--force`: nothing is installed. |
| 0 | `updated to <first 12 hex>` | Without `--check`: the newer commit (or, with `--force`, the same one) was installed like `nice-dns reinstall`, from a clone of the checked branch with the recorded choices (options override them; the branch is never widened unless `--branch` says so), and a second check says `current`. |
| the installer's | — | The install failed; the installer kept or restored the running stack and stderr names `nice-dns reinstall --local`. |
| 2 | — | A usage error (`--local` is refused: update installs the branch, not the kept source). |

### The cache `status` reads

Every check writes `update-check.tsv` in the controller's state directory
(0600, renamed over a temporary file): `schema<TAB>nice-dns-update-check/1`,
`checked_at <epoch>`, `branch <name>`, `local_commit <sha or ->`,
`remote_commit <sha or ->`, `result current|available|unknown`. `status`
prints it as the `update` rows; it never asks the remote itself.
