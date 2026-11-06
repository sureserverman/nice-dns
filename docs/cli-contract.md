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
bytes. Implemented by `lib/status.sh` (`nd_status_rows`); `nice-dns status`
without `--tsv` prints the same rows as sections.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | The rows were printed. A stale controller is still exit 0; read `controller stale`. |
| 1 | Nothing is installed: `install installed no` and `install hint <the README's curl line>`. |
| 2 | The controller's state directory, or its observations file, cannot be read: `controller unreadable <reason>`. |

### Rows

Every row after the schema line is `<group><TAB><key><TAB><value>[<TAB><value>...]`,
except `obs`, which is the controller's observation record copied as written.
Rows of a group come together, in this order of groups.

| Group | Keys and values |
|---|---|
| `install` | `installed yes\|no`; when installed: `generation <id>`, `source_commit <sha or unknown>`, `branch <name>`, `variant haproxy\|socat`, `pihole standard\|hardened`, `platform linux\|macos`, `lock sha256:<digest of release/images.lock>`; when not: `hint <curl line>`. |
| `controller` | `mode active\|shadow\|not-installed`; `last_pass <epoch>\|never`; `verdict <text>\|unknown` — `OK`, `FAIL [<names>]` (optionally followed by ` indeterminate=(<names>)`) or `INDETERMINATE [<names>]`; `stale no\|<seconds>\|never` — a pass older than 300 s is stale, and its observations are still printed; `schedule loaded\|stopped`; when the state cannot be read, `unreadable <reason>`. |
| `obs` | The last pass's records, one per observation: `obs<TAB><name><TAB><verdict><TAB><ms><TAB><reason>`, with `<name>` like `container:pi-hole` or `route:cloudflare-onion` and `<verdict>` `healthy\|unhealthy\|indeterminate`. Absent when no pass was recorded. |
| `route` | `selected <route id> <state generation>`, from the controller's state. Absent before the controller has chosen a route. |
| `bridges` | `mode on\|off` (`on` unless the bridges toggle wrote `TOR_BRIDGES=off`); `count <n>` (bridge lines in `bridges.env`); `last_refresh <epoch>\|never`. |
| `update` | `result current\|available\|unknown`; with a cache, `checked_at <epoch>` and `remote_commit <sha>`; with none, `result unknown never-checked`. Only `nice-dns update --check` and `nice-dns update` write the cache. |
| `admin` | `url <Pi-hole admin URL>`; when installed, `password_path <file holding the admin password>` — the path, never the password. |
| `recent` | The last five rows of the controller's journal, oldest first: `recent<TAB><epoch><TAB><target><TAB><result>`. |

A reader ignores a group or key it does not know; a new key is added without a
schema change, a changed meaning bumps the schema.
