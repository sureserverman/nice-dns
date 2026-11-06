# Close-out demo: Bridges-off mode in the proxy images

Evaluator: close-out evaluator (did not build this; no source or diffs read).
Date: 2026-11-06, 17:50-18:15 UTC, on the laptop, plus read-only checks on mint and mac.

What was used:

- Images as released on Docker Hub: `docker.io/sureserver/tor-haproxy:v2.16` and `docker.io/sureserver/tor-socat:v2.12`, pulled, not built.
- The pulled index digests are the locked ones: `tor-haproxy@sha256:b47b2003…f110f` and `tor-socat@sha256:4feee064…80992`.
- nice-dns on branch `images-bridges-off`. The branch moved while I ran:
  - start: `8e5b3a5`;
  - `0ca4239` (three empty record commits);
  - `fe22485` "update-images-lock.sh says when it cannot list an image's platforms" (17:58 UTC).
  - `scripts/update-images-lock.sh` was also run from `git archive` exports of `0ca4239` and `fe22485`, in scratch folders. Results are the same on both.
  - `release/images.lock` data rows are the same in all of these.
- The user documents: `doc/DOCKERHUB.md` and README in both image repos; `docs/release-inputs.md` in nice-dns.
- Throwaway containers ran on podman's default network, never on dnsnet. All are removed (see the end).
- Bridges for the on-mode runs: the public Tor Browser built-in set. `scripts/fetch-bridges.sh` fetched it with `XDG_CONFIG_HOME` pointed at a scratch folder. Bridge lines are redacted below.

## Stage 1 Outcome 1

> Works: with `TOR_BRIDGES=off` the supervisor logs `direct (no bridges)`, launches Tor with `UseBridges 0` and no `Bridge` lines, and the route probes answer once bootstrapped.

Verdict: holds

Evidence:

- `podman run --name ev-ho-off -e TOR_BRIDGES=off docker.io/sureserver/tor-haproxy:v2.16`, and the same for `ev-so-off` on tor-socat:v2.12. Logs:
  ```
  tor-supervisor: spawned tor pid=9 generation=1 direct (no bridges)
  tor-supervisor: bootstrapped after 7 s, a stream works after 9 s (exit)      # haproxy
  tor-supervisor: bootstrapped after 6 s, a stream works after 7 s (exit)      # socat
  ```
- Tor's command line in all four off-mode containers (`/proc/<pid>/cmdline`): `tor UseBridges 0`.
- `/etc/tor/torrc` has `UseBridges 1` and no `Bridge` line (`grep -c '^bridge '` gives 0). The command line overrides `UseBridges`.
- No `lyrebird` process ran.
- Tor's state file lists `20 Guard in=default` and no bridge guards. Tor connected direct.
- `nice-dns-route-probe` inside each container after bootstrap:
  ```
  ev-ho-off  port=853   name=tor.cloudflare-dns.com result=ok rcode=NOERROR ms=980
             port=18531 name=tor.cloudflare-dns.com result=ok rcode=NOERROR ms=1230
             port=18532 name=one.one.one.one        result=ok rcode=NOERROR ms=460
             port=18533 name=dns.quad9.net          result=ok rcode=NOERROR ms=470
  ev-so-off  853 ok 1190 ms, 18531 ok 1830 ms, 18532 ok 550 ms, 18533 ok 550 ms
  ```
- `ev-ho-ign` and `ev-so-ign` (Outcome 4) gave the same answers. One exception: the first 853 probe on `ev-so-ign`, 30 s after start, gave `result=no-answer … error=timeout`, with a stray `Killed` on stderr. Three retries all gave `ok` (1430–1850 ms). I count it as first-circuit warm-up, not a defect of this plan.

## Stage 1 Outcome 2

> `TOR_BRIDGES` unset or `on` → today's path: at least one bridge required, the same refusal message.

Verdict: holds

Evidence:

- `podman run --rm` with no bridges, with `TOR_BRIDGES` unset, `on` or empty (`TOR_BRIDGES=`). Both images gave the same output:
  ```
  Waiting for Tor to bootstrap...
  ERROR: no usable bridges (supply BRIDGE1.. at runtime, or enable bridge-eval)
  tor-supervisor: REFUSING to launch tor on invalid/empty bridges
  exit=1
  ```
- The previous releases (`tor-haproxy:v2.15`, `tor-socat:v2.11`), unset, print the same three lines and exit 1. The message did not change.
- With the 7 public bridges:
  - unset on tor-haproxy:v2.16 (`ev-ho-on`) and `TOR_BRIDGES=on` on tor-socat:v2.12 (`ev-so-on`) both log `spawned tor pid=27 generation=1 with 7 bridge(s)`.
  - Tor's argv is `tor Bridge <obfs4-line> ×7`. Tor uses `UseBridges 1` from torrc. `lyrebird` runs, and the state file has `7 Guard in=bridges`.
  - `ev-so-on` bootstrapped after 68 s. Its probes gave 853 `ok` 390 ms and 18533 `ok` 410 ms.
  - `ev-ho-on` did not bootstrap in 5 minutes (`WARNING: Tor did not bootstrap in 5 minutes.`).
    - A fresh `ev-ho-on2`, tor-haproxy:v2.16 with the same bridges, logged `bootstrapped after 187 s, a stream works after 188 s`. Its probes gave 853 `ok` 340 ms, 18531 `ok` 6630 ms, 18533 `ok` 270 ms, and the state file had `7 Guard in=bridges`.
    - A tor-haproxy:v2.15 control with the same bridges had not bootstrapped after about 4 minutes when I stopped it.
    - This is slow public obfs4 bridges, which hit the old release too. It is not a change in v2.16's on path.

## Stage 1 Outcome 3

> `TOR_BRIDGES` is anything else → exit 1 with `TOR_BRIDGES must be on or off`.

Verdict: holds

Evidence: `podman run --rm -e TOR_BRIDGES=<v>` on both images:
```
TOR_BRIDGES=bogus → ERROR: TOR_BRIDGES must be on or off (got 'bogus')   exit=1
TOR_BRIDGES=OFF   → ERROR: TOR_BRIDGES must be on or off (got 'OFF')     exit=1
```
The value is case-sensitive. An empty value counts as unset (Outcome 2). That matches the Hub table, which says the default is `on`.

## Stage 1 Outcome 4

> `off` with `BRIDGEn` or `BRIDGE_EVAL` set → one log line each saying they are ignored.

Verdict: holds

Evidence:

- `ev-ho-ign`: `TOR_BRIDGES=off`, `BRIDGE1`, `BRIDGE2`, `BRIDGE_EVAL=auto`. `ev-so-ign`: `TOR_BRIDGES=off`, `BRIDGE1`, `BRIDGE_EVAL=force`. The bridge lines were TEST-NET placeholders.
  ```
  tor-supervisor: bridges off: BRIDGE1..16 ignored
  tor-supervisor: bridges off: BRIDGE_EVAL=auto ignored      (socat: BRIDGE_EVAL=force ignored)
  tor-supervisor: spawned tor pid=9 generation=1 direct (no bridges)
  ```
- Each container has exactly two `bridges off:` lines, and no bridge-eval run. After a restart the lines did not repeat.
- Tor's argv was `tor UseBridges 0`. The probes answered, so the placeholder bridges were not used.
- Single-variable cases:
  - `BRIDGE_EVAL=moat` alone (socat) gave exactly `bridges off: BRIDGE_EVAL=moat ignored`.
  - `BRIDGE16` alone (haproxy) gave exactly `bridges off: BRIDGE1..16 ignored`.
- Pure `off` with nothing else set (`ev-ho-off`, `ev-so-off`) gave zero `bridges off:` lines.

## Stage 1 Outcome 5

> The in-image restart contract respawns Tor the same way in both modes (the contract: writing to /app/data/control inside the container; see the image's doc/DOCKERHUB.md for how a user drives it).

Verdict: holds

Evidence: I followed the README section "Restarting Tor without restarting the container". The Hub doc only says "see the README", which is finding F2. As the image user `app`, I ran:

```
cd /app/data/control && echo <id> > .r.tmp && mv .r.tmp tor-restart-request
```

| container | mode | ack | Tor argv after | log |
|---|---|---|---|---|
| ev-ho-off | off | `request_id eval-off-1 / status respawned / generation 2 / tor_pid 645` | `tor UseBridges 0` | `restart request eval-off-1 accepted` … `spawned tor pid=645 generation=2 direct (no bridges)`, `bootstrapped after 2 s` |
| ev-so-off | off | `eval-off-1 respawned generation 2 tor_pid 600` | `tor UseBridges 0` | same sequence, `generation=2 direct (no bridges)` |
| ev-ho-ign | off, legacy `touch /tmp/tor-restart-flag` | `request_id legacy respawned generation 2 tor_pid 709` | `tor UseBridges 0` | same sequence |
| ev-so-on | on | `eval-on-1 respawned generation 2 tor_pid 1537` | `tor Bridge <obfs4-line> ×7` | `spawned tor pid=1537 generation=2 with 7 bridge(s)`, `bootstrapped after 5 s` |
| ev-ho-on | on | `eval-on-ho respawned generation 2 tor_pid 2739` | `tor Bridge <obfs4-line> ×7` | `spawned tor pid=2739 generation=2 with 7 bridge(s)` |

- `tor-generation` matched each ack.
- After the restart, the off-mode probes answered again: haproxy 853 `ok` 4250 ms and 18533 `ok` 540 ms; socat 853 `ok` 3800 ms and 18533 `ok` 540 ms.
- Both modes use the same accept → SIGTERM → respawn sequence and the same ack format. Each respawn keeps the mode it started in.

## Stage 2 Outcome 1

> Works: v2.16 (sureserver/tor-haproxy) and v2.12 (sureserver/tor-socat) exist on Docker Hub, signed; `release/images.lock` pins their digests with `bridges-mode/1`; a live install on each platform runs them.

Verdict: holds

Evidence:

- **On Docker Hub.** `podman search --list-tags` lists `v2.16` (tor-haproxy) and `v2.12` (tor-socat). The pulled RepoDigests include the locked index digests. The image labels say `org.opencontainers.image.version=v2.16`, revision `7bf2ae0c…`, and `v2.12`, revision `165a127e…`. These match the lock's `source` column and the tags at the image repos' HEADs.
- **Signed.** `cosign verify` (v3.1.4) passes for each locked digest. The checks pinned:
  - the issuer `https://token.actions.githubusercontent.com`;
  - the exact identity `https://github.com/sureserverman/<repo>/.github/workflows/main.yml@refs/tags/v2.16` (or `v2.12`);
  - `--certificate-github-workflow-sha` set to the source commit.
  - Output: "Existence of the claims in the transparency log was verified offline"; "The code-signing certificate was verified using trusted certificate authority certificates".
- **Pinned in the lock.**
  - `release/images.lock` has `image proxy-haproxy … v2.16 sha256:b47b2003… … v2.16` and `image proxy-socat … v2.12 sha256:4feee064… … v2.12`.
  - It has `provides proxy-haproxy bridges-mode/1`, `provides proxy-socat bridges-mode/1` and `requires proxy bridges-mode/1`.
  - Every `requires proxy` interface (route-listeners/1, route-probe/1, control-restart/1, bridges-mode/1) has a `provides` row for both proxies.
  - `scripts/update-images-lock.sh` in report mode, under `systemd-run --user` because podman needs it on this host: `proxy-haproxy … v2.16 current`, `proxy-socat … v2.12 current`, the two bases `current`, "The lock matches the registry.", exit 0.
- **Live installs.** Read-only checks on mint and mac:
  - mint, current generation `20261106T150833Z`: `variant socat`, `lock sha256:d73f1c94…`, `locked proxy-socat docker.io/sureserver/tor-socat@sha256:4feee064… …@165a127e… v2.12`.
    - The running `tor-socat` container's image digest is `sha256:4feee064…`.
    - `dig @127.0.0.1 example.com` returns NOERROR.
    - Earlier activated generations on mint pin `tor-haproxy@sha256:b47b2003…` with the same lock, for example `20261106T125917Z`, activated 13:01:50Z.
  - mac, current generation `20261106T144422Z`, activated 14:45:48Z, pins `tor-socat@sha256:4feee064…`.
    - `container list`/`inspect`: `tor-socat` runs digest `sha256:4feee064…` at 172.31.240.252.
    - `dig @172.31.240.250 example.com` returns NOERROR. `scutil --dns` shows nameserver 172.31.240.250.
    - Activated haproxy generations pin `tor-haproxy@sha256:b47b2003…`: `20261106T122745Z`, `…123041Z`, `…123844Z`.
  - Lock `d73f1c94…` is the lock at commit `d7910c0`. Its data rows are identical to the lock at the current HEAD; only the header comment changed in `326ab03`.
  - Every live generation records `signature proxy-* unverified-no-cosign`, because the targets have no cosign. See finding F3.

## Stage 2 Outcome 2

> A CI build fails → the tag is not re-pointed; the failure is fixed on a new commit and a new patch tag.

Verdict: cannot reach by the user's route

Reason:

- No CI build failed for these releases.
- Reaching this path means pushing a failing tag to a sibling repo, which is forbidden.

What I observed:

- `gh run list`: one `torhaproxyci` push run for `v2.16` (7bf2ae0, success) and one `torsocatci` push run for `v2.12` (165a127, success). No failed or repeated release runs.
- `git ls-remote --tags` puts `v2.16` at 7bf2ae0 and `v2.12` at 165a127.
- The signing certificates name those same commits (see Stage 2 Outcome 1). The tags were not re-pointed.

## Stage 2 Outcome 3

> cosign cannot verify a new digest → `scripts/update-images-lock.sh --write` refuses and the lock is unchanged.

Verdict: holds

Evidence: I ran the script from `git archive` exports in scratch folders, never in the real checkout. I ran it on `0ca4239` and again on `fe22485`, with the same results.

- **Setup.** In each copy, the `proxy-haproxy` digest was set back to an older one (`sha256:59b393bf…`), so the registry's v2.16 digest is a new digest to the script.
- **Negative case.** The row's signer was also changed to the tor-socat workflow identity, so cosign cannot verify the new digest:
  ```
  proxy-haproxy: the signature of docker.io/sureserver/tor-haproxy@sha256:b47b2003… does not verify for https://github.com/sureserverman/tor-socat/…
  proxy-haproxy   docker.io/sureserver/tor-haproxy:v2.16 moved  sha256:59b393bf… -> sha256:b47b2003…
  not updating the lock: see the errors above
  exit=2; lock sha256 before e677c499… after e677c499… (unchanged; haproxy row still 59b393bf…)
  ```
- **Control, signer left correct.** The same `--write` records the move: "Wrote the new digests to …", exit 0. The lock's sha256 goes from 5cebe8c7… to 90abe910…, which is byte-identical to the committed lock. So the refusal above comes from the cosign check alone.
- **Without cosign on PATH**: "cosign is required to refresh the lock (signatures are checked on every signed image)", exit 2, lock unchanged.

## Stage 2 Outcome 4

> An install sees a lock without `bridges-mode/1` for a required interface → the existing interface check refuses before anything is interrupted.

Verdict: cannot reach by the user's route

Reason:

- The user's route is a nice-dns install against a lock that lacks the row.
- Every install and doctored-lock install is forbidden on every machine. I did not run one.

What I observed:

- `docs/release-inputs.md` step 3 says the install refuses before interrupting anything when the chosen proxy lacks a `requires`d interface. It names `bridges-mode/1` and v2.16/v2.12 as the first providers.
- The committed lock has `requires proxy bridges-mode/1`, and both proxy rows provide it.
- The images carry no `bridges-mode` label. The interface exists only as a reviewed lock row, as the doc says (finding F4).

## Findings

- **F1 (Material: process, not product).** The branch changed while this close-out was running.
  - New commits `0ca4239` and `fe22485` landed between 17:55 and 17:58 UTC.
  - Uncommitted, staged edits to `scripts/update-images-lock.sh` and `tests/integration/release-inputs.sh` were present for a few minutes.
  - `tests/run.sh integration release-inputs` ran at the same moment.
  - The close-out was meant to judge a finished build. I re-ran Stage 2 Outcome 3 on `fe22485` with the same result, so no verdict changes. The owner should know the evaluated HEAD is `fe22485`.
- **F2 (Minor).** `doc/DOCKERHUB.md`, the Hub page, does not describe the restart contract. It says "Tor restarts in place on request, with an acknowledgement (see the README)". A Hub user has to go to GitHub to learn how to use `/app/data/control`. The plan's Outcome 5 text expects the Hub doc to explain it. The README section is complete and correct.
- **F3 (Minor, residual).** The live installs on mint and mac never ran the install-time signature check. Every generation records `unverified-no-cosign`, because the targets have no cosign. This is documented behaviour. The signatures themselves verify (checked here on the laptop).
- **F4 (Minor).** The images declare route-listeners, the probe and the restart through `org.nice-dns.transport.*` labels, but nothing declares `bridges-mode/1`. The lock is the only place that claims it. The docs say the check compares lock rows, so this is consistent.
- **F5 (Minor, fixed during the run).** At `0ca4239`, `update-images-lock.sh` behaved badly when run from a plain shell where podman cannot start:
  - it printed Python `JSONDecodeError` tracebacks;
  - it said "has no linux/amd64 build" for every platform;
  - it showed each row as `current`;
  - it still refused (exit 2).
  `fe22485` replaced this with "cannot list the platforms of … (podman manifest inspect failed)". I confirmed the new message from a plain shell. Nothing left to do.
- **Observation, not graded.** `podman healthcheck run` reports no healthcheck on these pulled images under podman's OCI format. This is outside the plan's Outcomes.

## Overall

**PASS**, with recorded residuals F1–F5. There is no Blocking finding.

- Stage 1 goal met: `TOR_BRIDGES=off` gives direct Tor and working routes in both released images. Unset or `on` behaves exactly as v2.15/v2.11 did.
- Stage 2 goal met: nice-dns pins the signed v2.16/v2.12 digests with `bridges-mode/1`. Live generations on mint and mac ran them. The lock updater refuses an unverifiable digest.
- Stage 2 Outcomes 2 and 4 could not be reached by the user's route within the owner's limits (no failing release, no install).

Cleanup: every throwaway container is removed (`ev-*`: none left; no `ev-*` user units). Both background waits ended: the first finished by itself, and the second (the v2.15 comparison) I stopped with TaskStop. The laptop's own stack (tor-haproxy, unbound, pi-hole) was not touched and is still healthy. Nothing in any repo was edited except this file.
