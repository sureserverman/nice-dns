# Stage 2 demo — 2026-11-05-gui-update-bridges-restart-sub-03-status-and-update-plan

Environment: the laptop (Linux 7.0.0-42-generic, git 2.43.0), checkout /home/user/dev/containers/nice-dns at 20c3fe0 (branch status-update, clean apart from this file), 2026-11-06 ~20:30–20:45 UTC. Every `nice-dns` run was `./nice-dns ...` from the checkout with a scratch HOME under the session scratchpad (`HOME=<scratch> XDG_STATE_HOME= XDG_CONFIG_HOME= XDG_DATA_HOME=`). Each scratch HOME looked like an installed Linux host: `.local/state/nice-dns-install/current` naming `generations/<gen>/prepare.tsv` (variant haproxy, pihole standard, branch main, source_origin clone, source_commit, source_dirty) and `.local/state/nice-dns/controller/` (0700). One scratch HOME used a read-only copy of the laptop's real prepare.tsv (commit 0fe6c628…, clean). GitHub was asked for real; at the time `refs/heads/main` = 986b76f415ab83fc4b5cb444e0f8ccc778399f01 and `refs/heads/dev` = c5dc3fca6f8a…. Nothing was installed anywhere (OD-3, OD-6). No plain `update` was run where the check could say `available`.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: `nice-dns update --check` prints `current` (exit 0) or `available <short remote commit>` (exit 10) and writes the cache; `nice-dns update` checks, then reinstalls the recorded branch when available, then re-checks and prints the new commit.
Verdict: holds — install part shown by fixture (OD-6)
Evidence:
- Live, record = an older clean commit of main (0fe6c628…), before any check: `status --tsv` → `update	result	unknown	never-checked`, exit 0.
- `./nice-dns update --check` → stdout `available 986b76f415ab`, exit 10, 0.8 s. Cache `controller/update-check.tsv` written, mode `-rw-------`, the only file in the dir (no temporary left over):
  `schema	nice-dns-update-check/1` / `checked_at	1793997138` / `branch	main` / `local_commit	0fe6c628…bfcf` / `remote_commit	986b76f4…3f01` / `result	available`.
  `status --tsv` then shows `update	result	available`, `update	checked_at	1793997138`, `update	remote_commit	986b76f4…3f01`, exit 0.
- Live, record = main's current commit 986b76f4…: `update --check` → `current`, exit 0; cache `result	current`, local_commit = remote_commit.
- Live, `update --check --branch dev` on the older record → `available c5dc3fca6f8a`, exit 10; cache `branch	dev`, `remote_commit	c5dc3fca…`.
- Live, copy of the laptop's real prepare.tsv: `update --check` → `available 986b76f415ab`, exit 10; `status --tsv` shows the install rows (generation 20261104T064129Z-0fe6c62809e3, source_commit 0fe6c628…, branch main, haproxy, standard, linux, `lock sha256:c6d93a…`), the update rows, and `admin password_path` as a path only.
- Install half — shown by fixture (OD-6): tests/integration/nice-dns-cli.sh `t_update_installs_the_recorded_choices_when_available` (a fake remote with a newer commit; `nice-dns update` calls `installer[clone] install-<os>-hardened.sh socat main` — the recorded variant, flavour and branch from a clone — prints `updated to fedcba987654`, and the cache re-check says `current`) and `t_update_from_a_checkout_still_installs_the_branch` (a checkout's update installs a clone of the branch, not itself). Both `pass` in run ~/.local/state/nice-dns-tests/runs/20261106T202227Z-f942c5dc (`tests/run.sh integration nice-dns-cli`, status pass, 43/43; receipt git_head 32ab781, git_dirty yes — see Residuals).

## Outcome 2
> Nothing new → `nice-dns update` prints `already current` and installs nothing; `--force` reinstalls anyway.
Verdict: holds — install part shown by fixture (OD-6)
Evidence:
- Live, record = main's current commit 986b76f4…, online: `./nice-dns update` → exit 0; stdout two lines `current` then `already current`; stderr empty. Cache rewritten (`checked_at` moved 1793997149 → 1793997160, `result	current`). `find <scratch>` afterwards: only `current`, `prepare.tsv` and `update-check.tsv` — no clone, no new generation, nothing else written.
- `--force` half — shown by fixture (OD-6): `t_update_current_installs_nothing_unless_forced` (current remote: `already current`, no installer call, no clone; `update --force`: exit 0, `installer[clone] install-<os>.sh haproxy main`), pass in run 20261106T202227Z-f942c5dc. Not run live: with a current record `--force` would install.

## Outcome 3
> The remote cannot be reached (DNS down, offline) within 60 s → `unknown: <reason>`, exit 1, the cache says `unknown`, nothing changes.
Verdict: does not hold — the answer, exit code, cache and "nothing changes" all hold, but when the network drops or stalls the answer comes after 90 s, not within 60 s
Evidence:
- Refused proxy (`HTTPS_PROXY=http://127.0.0.1:9`), older record, `update --check` → stdout `unknown: could not reach https://github.com/sureserverman/nice-dns.git (is DNS down?)`, exit 1, 0.04 s, stderr empty. Cache `remote_commit	-`, `result	unknown`. Scratch HOME still holds only its three files.
- Unresolvable host (git env `url.https://github.invalid/.insteadOf=https://github.com/` via GIT_CONFIG_COUNT/KEY/VALUE) → same line, exit 1, 0.04 s, cache `unknown`.
- Plain `update` while offline (refused proxy, record = main): `update --check` first → `unknown: could not reach …`, exit 1; then `./nice-dns update` → exit 1, stdout `unknown: could not reach https://github.com/sureserverman/nice-dns.git (is DNS down?)`, stderr `nice-dns: nothing was installed. \`nice-dns reinstall\` installs the branch without a check.`; cache `result	unknown`; no file but the cache written.
- A branch the remote does not have (`update --check --branch no-such-branch-xyz`) → `unknown: the remote has no branch 'no-such-branch-xyz'`, exit 1, cache `unknown`, `remote_commit	-`.
- **The 60 s bound fails when the network is silent:**
  - Proxy that accepts the connection and never answers (a local python listener, stopped and reaped afterwards) → `unknown: could not reach …`, exit 1, cache `unknown`, after **90.03 s**.
  - Packets to GitHub dropped (`http.curloptResolve=github.com:443:192.0.2.1`, a reserved test address) → same answer after **90.02 s**.
  - git's low-speed limit did not end either case; the 90 s `timeout` did. docs/cli-contract.md documents "bounded by git's low-speed limit and, where `timeout` exists, by 90 s", so the contract and the Outcome disagree. No git process was left behind.

## Outcome 4
> The install fails → the existing rollback; the message names `nice-dns reinstall --local`.
Verdict: holds — install part shown by fixture (OD-6)
Evidence:
- No live route without installing (OD-3, OD-6): an install failure needs a real install.
- Shown by fixture (OD-6): `t_update_a_failed_install_names_reinstall_local`. A fake remote with a newer commit and an installer that exits 3: `update` exits 3 (the installer's code), stderr matches `nice-dns reinstall --local`, and the cache still says `available`. Also `t_failed_clone_names_local_and_changes_nothing`. Both pass in run 20261106T202227Z-f942c5dc.
- The rollback itself belongs to the installer and is not exercised by these fixtures (the installer is a fake). Premise 4 records it as live-proven before this stage.

## Outcome 5
> A local (dirty or unknown) source commit was recorded → `unknown: the installed source was not a clean commit`.
Verdict: holds
Evidence:
- Record source_commit = main's 986b76f4…, `source_dirty 1`: `update --check` → `unknown: the installed source was not a clean commit`, exit 1, stderr empty; cache `local_commit	986b76f4…`, `remote_commit	-`, `result	unknown`.
- Record `source_commit unknown`: same line, exit 1; cache `local_commit	unknown`, `result	unknown`.
- Record `source_commit 0fe6c628` (short, not 40 hex): same line, exit 1; cache `local_commit	0fe6c628`, `result	unknown`.
- Plain `./nice-dns update` on the dirty record and on the unknown record: exit 1, stdout `unknown: the installed source was not a clean commit`, stderr `nice-dns: nothing was installed. \`nice-dns reinstall\` installs the branch without a check.` Scratch HOME still holds only its 3 files.
- `status` (human form) on the unknown record answers in 0.09 s with `Update / result unknown / checked_at 1793997431 / remote_commit -`.

## Other checks
- Nothing installed (empty scratch HOME): `update --check` → exit 1, stdout empty, stderr `nice-dns: nice-dns is not installed; run \`nice-dns install\``, no file written. `status --tsv` → `install	installed	no`, `install	hint	curl -fsSL …/install-deb.sh -o install-deb.sh && bash install-deb.sh`, `update	result	unknown	never-checked`, exit 1.
- `update --local` → `nice-dns: --local reinstalls the kept source; update installs the branch` plus usage, exit 2. `update --bogus` → `unknown option '--bogus' for update` plus usage, exit 2.
- Schema line: `status --tsv` prints `schema	nice-dns-status/1` first; docs/cli-contract.md line 8 says `schema<TAB>nice-dns-status/1`. They match.
- Status is read-only: on a scratch HOME, a `find -printf '%P %s %T@'` listing before and after `status --tsv` was identical. Following the brief, status was always run against scratch HOMEs, never the laptop's real HOME. One scratch HOME used a copy of the laptop's real record.
- Real state untouched: a listing of ~/.local/state/nice-dns and ~/.local/state/nice-dns-install taken before and after the demo differs only in the mtime of `controller/state.tsv`. That file is the installed controller's own, rewritten by its pass. No `update-check.tsv` appeared in the real controller dir, and `current` still names 20261104T064129Z-0fe6c62809e3. The repo is unchanged apart from this file.

## Findings
**Blocking**
- B1 (Outcome 3): when the network drops or stalls (a silent proxy, or packets to GitHub dropped), `update --check` answers `unknown` only after 90 s, not within 60 s. git's low-speed limit does not end the wait; the 90 s `timeout` does. The contract documents 90 s, so either the bound goes to 60 s or less, or the owner amends the Outcome to 90 s. Refused connections, unresolvable names and missing branches answer in 0.04 s.

**Material**
- none

**Minor**
- M1: `update --check` with nothing installed prints nothing on stdout (the reason goes to stderr) and writes no cache. The contract's exit-1 row gives `unknown: <reason>` as the stdout and lists "nothing is installed at all" under the same row, so a GUI reading stdout gets an empty line.
- M2: the contract says the cache's `local_commit` is `<sha or ->`. The cache copies the record's value as written: `unknown` and the short `0fe6c628` were both seen.
- M3: with `--check`, an `unknown` answer prints nothing on stderr. The contract's exit-1 row says "stderr names `nice-dns reinstall`", which only plain `update` does. The row is ambiguous between the two forms.
- M4: `--help` says status exits 2 "when the controller's state is unreadable". The contract says 2 for any file status reads that cannot be read.
- M5: status passes recorded values through without checking them against the contract's enumerations. A record with `variant haproxy$(touch …)` prints that text as `install variant`, and a tampered cache's `remote_commit` prints backtick text. Nothing was executed (no marker file was created), and a tampered `result` was shown as `unknown`.

**Residuals / notes**
- The fixture evidence comes from run 20261106T202227Z-f942c5dc: receipt git_head 32ab781, git_dirty yes, 43/43 pass. That is before the 2.3 commit (20c3fe0), and the run right after it (202326Z) failed `t_update_current_installs_nothing_unless_forced`. This looks like the alternating red/green of mutation proofs. The plan-scope run now in progress at HEAD is the authoritative proof for the install parts.
- Not run live: `update --force` with an `unknown` answer (the contract says nothing is installed). The session's permission classifier refused that command. It is covered by the fixture `t_update_unknown_installs_nothing` (pass).
- A minimal record with no `lock` or `credential` rows prints `install lock` and `admin password_path` with empty values. The copy of the real record fills both.

## Decisions
- DEC-001 (one policy owner; state never sourced as shell; no direct public resolver as fallback): nothing contradicts it. Shell text placed in the record's `variant` and `branch` and in the cache's `local_commit`, `remote_commit` and `result` was never executed by `status` or `update --check`; no marker file appeared. The recorded branch went to `git ls-remote` as a literal name and came back `unknown: the remote has no branch '…'`. Offline, the check said `unknown` and fell back to nothing. Its only network use is `git ls-remote` to github.com.
- DEC-018 (drift detected and warned, never re-rendered unattended): nothing contradicts it. `status` changed no file, and `update --check` wrote only the cache. Every update path seen live (`current`, `already current`, `unknown` online and offline, dirty or unknown source, nothing installed) installed and re-rendered nothing. An install happens only on an explicit `nice-dns update` with a newer commit or `--force`; the fixture shows it going through the installer.
- DEC-019 (the Linux installer drives Mullvad's DNS setting; update adds no Mullvad logic): nothing contradicts it. No update path seen touched or mentioned Mullvad, and the fixtures show `update` handing the install to `install-<os>.sh` from a clone.
- DEC-022 (the controller owns every container restart): nothing contradicts it. No update or status path seen restarts, starts or stops a container or calls a container runtime. The real install's state is unchanged apart from the controller's own `state.tsv`.
