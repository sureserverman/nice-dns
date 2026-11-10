# Stage 2 premises — 2026-11-05-gui-update-bridges-restart-sub-07-macos-gui-plan

Goal: The installer puts the app into ~/Applications from a verified release asset, and the owner sees it run on the Mac.
Risk: MEDIUM — a release tag is public; the live run reinstalls mac's stack; Gatekeeper behaviour is proven, not assumed.

Outcomes:
- Works: after `nice-dns install` on macOS, `~/Applications/nice-dns.app` exists without quarantine and launches; uninstall removes it.
- The download fails or the sha256 differs → the install continues and says `GUI not installed`.
- A target is unreachable → that check is `[~]` with the reason.

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: an HTTPS download by `curl` on mac carries no `com.apple.quarantine` attribute (the installer strips it anyway).
Checked: 2026-11-10 on mac: `curl -fsSL -o h https://github.com/sureserverman/nice-dns/releases/download/v1.1.0/nice-dns-helper-macos-arm64 && xattr h | wc -l`
Result: 0 attributes.
Verdict: holds

## Premise 2
Assumption: a `ditto -c -k --keepParent` zip of the ad-hoc signed bundle unpacks with `ditto -x -k` into a bundle that still verifies and runs.
Checked: 2026-11-10 on mac, after `make` in ~/nice-dns-gui-check/gui/mac: ditto -c -k --keepParent build/nice-dns.app app.zip; ditto -x -k app.zip x; codesign --verify --deep x/nice-dns.app; xattr -lr x/nice-dns.app; x/nice-dns.app/Contents/MacOS/NiceDNSGUI --check
Result: verify-ok; no extended attributes; `--check` exit 0 ("installed: generation 20261109T180318Z-nogit0000000; controller OK, fresh").
Verdict: holds

## Premise 3
Assumption: ~/Applications exists and is the user's to write (no root), and ditto, xattr and iconutil are present.
Checked: 2026-11-10 on mac: `ls -ld ~/Applications; which ditto xattr iconutil`
Result: drwxr-xr-x user staff /Users/user/Applications; /usr/bin/ditto, /usr/bin/xattr, /usr/bin/iconutil.
Verdict: holds (the installer still makes the directory when it is missing)

## Premise 4
Assumption: GitHub's macos-15 runner builds the package with `make` (swift, iconutil, codesign) and runs `swift test`.
Checked: not here; there is no runner to probe before a tag is pushed.
Result: —
Verdict: not checkable here — no macos-15 runner without a release run; Task 2.2's release run is the check, and a failure there stops the stage.

## Premise 5
Assumption: the release can be pushed and watched: gh is logged in to the repo owner.
Checked: 2026-11-10: `gh auth status`
Result: logged in to github.com as sureserverman (keyring).
Verdict: holds
