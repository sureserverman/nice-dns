# Stage 2 demo — 2026-11-05-gui-update-bridges-restart-sub-02-bridges-off-images-plan

Environment: evaluated 2026-11-06 ~12:43–13:10 UTC from the laptop (Linux 7.0.0-42, cosign v3.1.4, gh logged in) at nice-dns 4021353 (branch images-bridges-off; release/images.lock sha256 d73f1c94…, blob a4fd6d78, same as d7910c0). Live targets read only: mint (Linux 6.17.0-23, Podman) and mac (macOS 27.2, arm64, Apple container). No install, uninstall, restart or stop was run anywhere. Plan-scope runs were not rerun (read from artifacts). No tests/run.sh was running during the evaluation (pgrep).

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: v2.16 and v2.12 exist on Docker Hub, signed; `release/images.lock` pins their digests with `bridges-mode/1`; a live install on each platform runs them.
Verdict: does not hold (partly). Hub, signatures and the lock hold for both images. tor-haproxy v2.16 runs from a live install on both platforms. tor-socat v2.12 has never run in a live install on either platform.
Evidence:
- Docker Hub API (`curl https://hub.docker.com/v2/repositories/sureserver/<repo>/tags/<tag>`):
  - tor-haproxy v2.16 = sha256:b47b200323d867775c5302d7c6c92b22ec3856860157432ea9de42ce1f8b110f. Pushed 2026-11-06T10:41:44Z. Platforms: amd64, arm64, arm/v7, riscv64.
  - tor-socat v2.12 = sha256:4feee0640ed17f3142b165ef527192456b46851659f17ce23ba1fceec0380992. Pushed 2026-11-06T10:41:51Z. Same four platforms.
- Signatures: `cosign verify --certificate-identity "https://github.com/sureserverman/<repo>/.github/workflows/main.yml@refs/tags/<tag>" --certificate-oidc-issuer https://token.actions.githubusercontent.com docker.io/sureserver/<repo>@<digest>`. I used the exact tag identity, which is stricter than the lock's prefix. Result: "VERIFIED" for tor-haproxy@v2.16 and for tor-socat@v2.12. The regexp form (the lock's prefix) also verifies both, with the transparency-log check performed.
- The released images carry the mode. I fetched the amd64 layers through the registry API. Each image's `bin/start.sh` mentions `TOR_BRIDGES` 5 times. Both Hub descriptions document `TOR_BRIDGES` `on`/`off`.
- Lock: `release/images.lock` pins tor-haproxy v2.16 @ b47b2003… (source 7bf2ae0c) and tor-socat v2.12 @ 4feee064… (source 165a127e). It has `provides proxy-haproxy bridges-mode/1`, `provides proxy-socat bridges-mode/1` and `requires proxy bridges-mode/1`. `scripts/update-images-lock.sh --lock <copy>` printed "The lock matches the registry." (exit 0).
- Live installs, read from the targets:
  - mint: `current` = 20261106T123721Z (activated 12:40:00Z). Its prepare.tsv shows lock sha256:d73f1c94… (the committed lock), variant haproxy, locked and pulled tor-haproxy@sha256:b47b2003…. `podman inspect tor-haproxy` shows ImageDigest b47b2003…, and the container is healthy. `dig @127.0.0.1 cloudflare.com` returns 104.16.132.229 and 104.16.133.229.
  - mac: `current` = 20261106T123844Z (activated 12:40:20Z). Same lock sha256. Variant haproxy, image tor-haproxy@b47b2003…. `container ls` shows tor-haproxy, unbound and pi-hole running at .252/.251/.250. `dig @172.31.240.250 cloudflare.com` answers. The runtime is back in gui/501, and the host resolver is pinned to 172.31.240.250.
  - Installers receipt 20261106T121314Z-4968f57c (40/40 pass). It has exactly two cells: `macos haproxy standard` and `linux haproxy standard`.
- The gap:
  - Every generation of 2026-11-06 on both targets is `variant haproxy` (mint 5 during the final run, 11 that day on mac).
  - `grep -l 4feee0640ed1 */prepare.tsv` finds nothing on mint or on mac.
  - The last socat installs on the targets were on 2026-10-31, with v2.11.
  - The transport run 20261106T104707Z-e29a32b8 (208/208) exercised socat. But it ran on the laptop fixture with `localhost/nd-test-tor-socat:bba0e892…`, built locally from 165a127e. That is the same source, not the released CI-built digest.
  - Task 2.3's claim names only "tor-haproxy v2.16 sha256:b47b2003".
  - So the released tor-socat v2.12 image has not been run by any install. A user who picks `socat` gets an image no live install has run.

## Outcome 2
> A CI build fails → the tag is not re-pointed; the failure is fixed on a new commit and a new patch tag.
Verdict: cannot reach by the user's route. No CI build failed in this stage. Causing one would mean pushing a broken public release tag, which is outside the safety limits. The policy was honoured where it can be observed. Not Blocking.
Evidence:
- `gh run list -R sureserverman/tor-haproxy -w main.yml`: v2.16 run 42204404454 on 7bf2ae0c48b8, success. `gh api …/actions/runs/42204404454` shows run_attempt=1. Jobs: build amd64/riscv64/arm/v7/arm64, merge and update-dockerhub-description all succeeded.
- tor-socat: v2.12 run 42204422411 on 165a127e08e8, success, run_attempt=1, same jobs all succeeded.
- `gh run list -b v2.16` / `-b v2.12` show exactly one run per tag. Nothing was re-run.
- Tag refs (`gh api …/git/matching-refs/tags/v2.1`, `git ls-remote --tags origin`):
  - tor-haproxy refs/tags/v2.16 → 7bf2ae0c48b8. That is the commit CI built and the lock's `source`.
  - tor-socat refs/tags/v2.12 → 165a127e08e8. Same match. Neither tag was re-pointed.
- History is consistent with the policy. The 2026-08-28 failures (tor-haproxy v2.11 on 676eb9dd, tor-socat v2.7 on 47dd3e8a) were followed by new tags v2.12 / v2.8 on new commits, not by moving the failed tags.

## Outcome 3
> cosign cannot verify a new digest → `scripts/update-images-lock.sh --write` refuses and the lock is unchanged.
Verdict: holds
Evidence:
- Scratch dir: /tmp/claude-1000/-home-user-dev-containers-nice-dns/74ed05b3-d163-4366-a918-ec8ca70af8a3/scratchpad/demo2/. I ran everything from the repo through `systemd-run --user --wait --pipe --quiet --same-dir … scripts/update-images-lock.sh`.
- Unsigned new digest. In `unsigned.lock` (a copy of the real lock) I changed the proxy-haproxy row's tag v2.16 → v1.9.9. That tag exists on Hub on all four platforms. `cosign verify` on it says "no signatures found". The script therefore sees a moved digest (b47b2003… → 5345963c…) that cosign cannot verify.
  - `--lock unsigned.lock --write` printed "proxy-haproxy: the signature of docker.io/sureserver/tor-haproxy@sha256:5345963c… does not verify for https://github.com/sureserverman/tor-haproxy/.github/workflows/main.yml@refs/tags/v", then the table (proxy-haproxy `moved`, the other three `current`), then "not updating the lock: see the errors above". Exit 2.
  - `cmp` before/after: UNCHANGED (sha256 4aed556a… both times).
- Positive control, to show the refusal is not vacuous. `drift-signed.lock` keeps tag v2.16 but has the old v2.15 digest da8b61da…. `--write` showed `moved da8b61da… -> b47b2003…` and "Wrote the new digests to …drift-signed.lock". Exit 0. Only line 35 changed, and the result is byte-identical to the committed lock.
- Unmodified copy (`control.lock`, report mode): "The lock matches the registry." Exit 0.
- The real `release/images.lock` was untouched. `git status --porcelain` shows only this demo.md.

## Outcome 4
> An install sees a lock without `bridges-mode/1` for a required interface → the existing interface check refuses before anything is interrupted.
Verdict: cannot reach by the user's route. The user's route is to run install-deb.sh or install-mac.sh with such a lock. Running a real installer is forbidden on this laptop, and installing on mint or mac is forbidden. If the check failed to refuse, the installer would replace a running stack. Equivalent evidence exists, so this is not Blocking.
Evidence (the repo's release-inputs group drives the real installers against install fakes; this is a test standing in for the user):
- Red run 20261106T104556Z-f84a2b27, the Task 2.2 claim's break. Only the `provides proxy-socat bridges-mode/1` row was removed. The real `install-deb.sh`, run in the fixture, stopped with: "nice-dns install: the locked tor-socat image does not provide bridges-mode/1, which this nice-dns needs; refusing before any change". Exit 1. In the same run `t_every_required_proxy_interface_is_provided` reported "proxy-socat provides bridges-mode/1: both are []".
- Green runs 20261106T104430Z-259d72a9 and 20261106T104526Z-017bb151: 10/10, including `t_missing_interface_is_refused` and `t_every_required_proxy_interface_is_provided`. They ran on a working tree whose lock blob a4fd6d78 equals the committed d7910c0 lock.
- In the passing `t_missing_interface_is_refused` (that case removes `route-probe/1` from haproxy), the fake call log of each of the four installers shows only `git -C …`, `uname -m`, `sw_vers` (mac) and `sudo bash …/custom-dns-deb check`. There is no podman, systemctl, container or launchctl call. So the refusal comes before anything is interrupted.
- The plan-scope runs (transport, installers) do not include the release-inputs group. No release-inputs run exists at clean d7910c0/4021353. The runs above were at b2f4124 with the lock change uncommitted, but byte-identical.

## Decisions check (judgment): DEC-005, DEC-009
Verdict: holds. No change contradicts a decision in force.
Evidence (I read `git log d613278..4021353` and `git diff d613278..4021353 -- . ':!proof'`; the diff touches only docs/release-inputs.md, release/images.lock and tests/integration/release-inputs.sh):
- DEC-005 (the legacy :853 route stays selectable, class `compat`): compared against the lock diff, the docs diff and the new test.
  - Nothing touches routes/providers.tsv, apply_route or route selection.
  - The images keep `provides … route-listeners/1` and `route-probe/1`, and the tree still requires them.
  - The transport run 20261106T104707Z-e29a32b8 (208/208) includes `t_legacy_853_fails_over_within_cloudflare_only` and `t_legacy_restart_flag_acknowledged`, both pass.
  - The installers receipt keeps the DEC-005 `limit route-mount` row ("the compat :853 route (DEC-005)").
- DEC-009 (a live gate rerun repeats only the cells that failed; harness changes are first run against one cell): compared against the Task 2.3 commit message and the run artifacts.
  - The first plan-installers run 20261106T110809Z-8be96488 failed only the macOS live cases (35/40). The rerun was the macOS cell alone: 20261106T120615Z-86db2e1f, 6/6. That run follows DEC-009.
  - The final run 20261106T121314Z-4968f57c re-executed both cells fresh. The receipt has no `reuse` row, and the mac generations 122745Z, 123041Z and 123844Z were created during it. Repeating more than the decision requires is costlier but does not break it: no executed cell was replaced, and no failure left the denominator.
  - The live harness was not changed in this stage, so the one-cell-first rule was not triggered.
  - The owner-approved move of the mac runtime into the ssh-visible launchd domain was an environment step. It was restored afterwards: verified, the runtime is in gui/501.
- No Supersedes citation appears in the commits.

## Findings
- **Blocking: tor-socat v2.12 was never run by a live install (Outcome 1).**
  - The installers plan runs only haproxy cells.
  - No generation on mint or mac pins 4feee064….
  - The only socat exercise was the laptop fixture, with a locally built image from the same source. The CI-built released image has not run anywhere.
  - Remedy: one `socat` live install per platform with the committed lock (a single-cell run in the DEC-009 style). Alternatively, an owner amendment that narrows the Outcome to the representative haproxy cell, citing DEC-008's shape.
- **Minor: the Task 2.3 claim-deviation text says "macOS cell reused per DEC-009 from 20261106T120615Z-86db2e1f".** The final receipt has no reuse row, and the mac cell ran fresh. The commit message says the harness ran the Linux cell again, but in fact both ran again. The record understates the evidence; it does not overstate it.
- **Minor: no release-inputs run exists at the committed tree.** The interface refusal's green and red runs were taken on b2f4124 with the lock change uncommitted. The blob is identical, so the evidence carries over, but the plan-scope runs never re-ran the group.
- **Minor (pre-existing, not this stage): neither live target has cosign.** So every live generation records `signature proxy-haproxy unverified-no-cosign`. The installed v2.16 was signature-checked by the lock refresh and by this demo, not by the installs. This is documented behaviour (`ND_INST_REQUIRE_SIGNATURES=1` makes it refuse instead).
- **Minor: v2.16 and v2.12 are lightweight tags; v2.11–v2.15 were annotated.** It is cosmetic. The signer identity and CI are unaffected.
- **Minor (scope, disclosed): the lock commit also moved `pihole-base` latest** (5b9c8cf5… → 30f803ad…, version 2026-11-06). It is disclosed in d7910c0 and was needed for "digests are current". The live installs ran with it.
- **Cosmetic:** when update-images-lock.sh refuses, it prints the signature error above the table header row it relates to.
