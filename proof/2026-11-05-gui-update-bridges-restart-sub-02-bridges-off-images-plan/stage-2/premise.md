# Stage 2 premises — 2026-11-05-gui-update-bridges-restart-sub-02-bridges-off-images-plan

Goal: nice-dns installs the released images that carry the mode, and refuses an older lock.
Risk: MEDIUM — releases are public and immutable; the live installs replace the targets' stacks.

Outcomes:
- Works: v2.16 and v2.12 exist on Docker Hub, signed; `release/images.lock` pins their digests with `bridges-mode/1`; a live install on each platform runs them.
- A CI build fails → the tag is not re-pointed; the failure is fixed on a new commit and a new patch tag.
- cosign cannot verify a new digest → `scripts/update-images-lock.sh --write` refuses and the lock is unchanged.
- An install sees a lock without `bridges-mode/1` for a required interface → the existing interface check refuses before anything is interrupted.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: A `v*` tag push runs the release workflow (build four platforms, push to Docker Hub, sign keyless), as it did for the pinned releases.
Checked: 2026-11-06 `gh run list -R sureserverman/<repo> -w main.yml -L 3`
Result: tor-haproxy v2.15/v2.14/v2.13 and tor-socat v2.11/v2.10/v2.9 all `push success`; `gh secret list` shows DOCKERHUB_TOKEN and DOCKERHUB_USERNAME in both repos.
Verdict: holds

## Premise 2
Assumption: The plan's cosign check verifies a release signed by the tag workflow with this host's cosign.
Checked: `cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity-regexp 'github.com/sureserverman/<repo>/.github/workflows/main.yml@refs/tags/v' docker.io/sureserver/<repo>:<tag>` for tor-haproxy:v2.15 and tor-socat:v2.11 (cosign v3.1.4)
Result: exit 0 for both.
Verdict: holds

## Premise 3
Assumption: The release CI can build the images on every platform it builds (linux/amd64, arm64, arm/v7, riscv64): the Dockerfile's hard pin `lyrebird=0.8.1-r7` from alpine/edge/community resolves on all four.
Checked: each arch's APKINDEX: `curl -fsSL https://dl-cdn.alpinelinux.org/alpine/<repo>/community/<arch>/APKINDEX.tar.gz | tar -xzO APKINDEX` for repo edge and v3.24, arch x86_64 aarch64 armv7 riscv64
Result: edge: x86_64/aarch64/armv7 `0.8.1-r7`, riscv64 `0.8.1-r6` (index last-modified 2026-10-15, stalled); v3.24: `0.8.1-r7` on all four. Neither r6 nor r7 from edge resolves on all four platforms.
Verdict: false

## Premise 4
Assumption: After the owner's decision (2026-11-06, "1": install lyrebird from Alpine v3.24/community instead of edge), the pinned `lyrebird=0.8.1-r7` resolves on all four release platforms.
Checked: per arch, in alpine:3.24.1: `apk fetch --arch <arch> --no-cache --allow-untrusted --repositories-file /dev/null -X https://dl-cdn.alpinelinux.org/alpine/v3.24/community -o /tmp/o lyrebird`, then `.PKGINFO` arch; Dockerfiles switched in tor-haproxy 9a39088, tor-socat 37b3306; both images rebuilt and tests/run.sh green.
Result: x86_64, aarch64, armv7, riscv64 each downloaded `lyrebird-0.8.1-r7.apk` with the matching arch.
Verdict: holds
