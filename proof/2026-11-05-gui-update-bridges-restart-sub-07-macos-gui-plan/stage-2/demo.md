# Stage 2 demo — 2026-11-05-gui-update-bridges-restart-sub-07-macos-gui-plan

Environment: mac (`ssh mac`, macOS 27.2, build 26B123, Apple silicon). The tree under test was HEAD 2fe2312, copied with `git archive 2fe2312 | ssh mac 'tar -x -C ~/nd-demo'`. Every mac command ran in the owner's gui domain (`sudo -n launchctl asuser $(id -u) sudo -n -u $(whoami) env HOME=… PATH=… <cmd>`). Run on 2026-11-10, 13:51–14:04 UTC, after the executor's plan-scope run (pid 3876080) had ended at 13:51:02Z. Screen Recording and Accessibility are not granted over ssh, so the menu bar itself was not seen.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: after `nice-dns install` on macOS, `~/Applications/nice-dns.app` exists without quarantine and launches; uninstall removes it.
Verdict: holds
Evidence:
- `cd ~/nd-demo && ./nice-dns install socat` (13:51:22Z–13:55:04Z): rc=0. The screen showed `▸ Fetching nice-dns-gui (macos/arm64)`, `All done. DNS is set to 172.31.240.250 (pi-hole).` and `The nice-dns menu-bar app: open /Users/user/Applications/nice-dns.app`.
- `xattr -lr ~/Applications/nice-dns.app` printed nothing: no `com.apple.quarantine` and no other xattr. `codesign --verify --deep --strict` passed, with an ad-hoc signature (`Identifier=org.nice-dns.gui`). `spctl -a` says `rejected`. That has no effect here because the bundle is not quarantined.
- The release asset matches the lock. `curl` of `v1.2.0/nice-dns-gui-macos-arm64.zip` gives sha256 `6974b711…cf24`, the value `release/assets.lock` pins. The installed `NiceDNSGUI` (sha256 `c3efcd62…a745`) is the same file as the one in that zip.
- Launch: `open ~/Applications/nice-dns.app` returned rc=0. Process `NiceDNSGUI` (pid 72932) ran and started `bash /Users/user/.local/bin/nice-dns status --tsv` as its child, so it reads status the way the contract says. A `quit` AppleEvent to `org.nice-dns.gui` ended it with rc=0.
- Uninstall: I reopened the app (pid 74402), then ran `nice-dns uninstall` (13:56:01Z–13:57:59Z). rc=0, and the screen showed `Uninstalled.` / `nice-dns uninstalled.` `~/Applications` then held only `Claude Code URL Handler.app`, so the bundle was gone. **But the open app kept running** (finding M1). pid 74402 was still alive 2:21 later. A `quit` AppleEvent by bundle id returned rc=0 and did not stop it. It took `kill -TERM`.
- Premise check: the release workflow (run 42821770400, tag v1.2.0, success) built `nice-dns-gui-macos-arm64` on `Image: macos-15-arm64`. It ran `swift test && swift run KitCheck` (`Executed 9 tests, with 0 failures`, `Executed 6 tests, with 0 failures`) and then `make VERSION="${TAG#v}"`.

## Outcome 2
> The download fails or the sha256 differs → the install continues and says `GUI not installed`.
Verdict: holds
Evidence:
- sha256 differs. In mac's copy only, I changed the `asset gui macos arm64` sha256 to end in `…cf25`. Starting from the uninstalled state, `./nice-dns install socat` (13:58:42Z–14:00:24Z) returned rc=0. Line 7 of the output and the line after `All done.` both said: `! The nice-dns-gui download's sha256 is not the one release/assets.lock pins; it was not installed: GUI not installed; reinstall with network to add it.` `~/Applications` had no `nice-dns.app`. `dig @172.31.240.250 cloudflare.com` answered `104.16.133.229 104.16.132.229`.
- Download fails. I restored the sha256 and pointed the URL at `…/v1.2.0/nice-dns-gui-macos-arm64-absent.zip` (curl gives `http 404`). `./nice-dns install socat` (14:00:41Z–14:01:53Z) returned rc=0. Line 5 and the line after `All done.` said: `! The nice-dns-gui download failed (curl exit 56): GUI not installed; reinstall with network to add it.` No app was installed, and DNS answered.
- Both times, the stack install went on to `Generation … is active` and `All done.`

## Outcome 3
> A target is unreachable → that check is `[~]` with the reason.
Verdict: holds (the product's part). The `[~]` mark itself is written by hand under the planning rule; nothing in the product writes it.
Evidence:
- Route: the owner's live command, `bash tests/run.sh live gui-mac --live --targets tests/live/targets.env --platforms macos`. I ran it from a clean clone of 2fe2312 in scratch, with `NICE_DNS_TEST_ARTIFACTS` set to a scratch dir so the executor's receipts were not touched. To make mac unreachable, a PATH `ssh`/`scp` wrapper added `-o ProxyCommand="nc -w 8 192.0.2.1 22"`. The target name, its address (`ssh -G mac` → `192.168.0.149`) and its pinned key stayed as they are, and the TCP connection went to a black hole.
- The first case on screen named the cause: `FAIL t_01_before … ASSERT FAIL: could not reach mac to snapshot it: Connection to UNKNOWN port 65535 timed out`. Every later case said `mac: no cell recorded (t_1_before failed); gm_<x> not run`. The result was `collected=10 passed=1 failed=9`, `result=fail`, `live rc=1`. `ops.log` holds the same timeout.
- The gate check cannot go green. `bash tests/run.sh receipt gui-mac` against that receipt gave `cells=0 scenarios=0 errors=8`, `rc=1`. Some of those errors are about missing sibling repos (`tor-haproxy` etc.). They come from my scratch clone, not from the product.
- No false green: nothing passed for mac, and the reason is on screen in the first FAIL line. The receipt itself has no row naming the unreachable target (finding m2).
- An earlier try that redirected `HostName` was refused before any connection: `host key for 192.0.2.1 is not in known_hosts … (no trust on first use)`. That is the key-pin check working as intended.

## Findings

Blocking: none.

Material:
- **M1. Uninstall leaves the menu-bar app running.** `nice-dns uninstall` deletes `~/Applications/nice-dns.app` while the app is open. The process (pid 74402) keeps running from the deleted bundle. Its status source (`~/.local/bin/nice-dns`) is gone too. A `quit` AppleEvent by bundle id no longer reaches it (rc=0, process still alive). Only `kill -TERM` ended it. The owner presumably keeps a stale menu-bar item until logout. I could not see the menu bar over ssh.
- **M2. The shipped app is older than the tree's gui/mac code.** The lock pins v1.2.0 (tag 740708d). `a109d57 gui/mac: look for the commands in the macOS install fallback` changed `gui/mac/Sources/NiceDNSKit/Paths.swift` after that tag, and `git merge-base --is-ancestor a109d57 v1.2.0` says it is not included. So installs carry the app without that fix. The `receipt gui-mac` the gate verifies is product 37f5741, which also predates a109d57. In the default install I ran, the app did find `~/.local/bin/nice-dns`. The fallback case the fix targets was not exercised.

Minor:
- m1. Advice in the sha256-mismatch message: `GUI not installed; reinstall with network to add it.` The network was fine. The bytes were wrong, so reinstalling will not fix it.
- m2. The receipt from the unreachable run has no row naming the unreachable target. Its `limit no-person-clicked` row still says `the opened app was quit by SIGTERM`, but no app was opened in that run. The reason is on screen and in `ops.log` only.
- m3. The download-failure message says `curl exit 56` for an HTTP 404. That number does not tell the owner the file is missing.

Observations, not findings:
- Before the demo, nine `nice-dns-health tick` processes were running at once on mac. Its status verdict was `FAIL [route:cloudflare-onion unbound]` while every check was healthy. I saw this once and did not look further. After the final install the verdict was `OK`.
- During the demo, someone else edited the working tree: `lib/install.sh` and `tests/integration/install-prepare.sh` were modified, and HEAD was unchanged. My first unreachable run therefore stopped at `ASSERT FAIL: the checkout is committed`. I reran from a clean clone. The mac installs used `git archive 2fe2312`, so the edits did not affect them.

State left on mac: a fourth install from the unmodified 2fe2312 tree (14:02:28Z–14:03:41Z, rc=0). `~/Applications/nice-dns.app` is present, has no xattrs, and is byte-identical to the v1.2.0 asset. `dig @172.31.240.250 cloudflare.com` answers. Controller verdict is `OK`. `nice-dns status` shows `source_commit unknown`, because the source was a `git archive` copy, not a checkout. The app is not running. `~/nd-demo`, `~/nd-demo-logs` and `~/nd-demo-g.sh` were removed. `~/nd-demo-055450a` (dated Nov 8) was there before and was left alone. Logs are kept at `/tmp/claude-1000/-home-user-dev-containers-nice-dns/23582f55-7604-4bc9-b6c6-62d70a97ff8c/scratchpad/demo/mac-logs/`.
