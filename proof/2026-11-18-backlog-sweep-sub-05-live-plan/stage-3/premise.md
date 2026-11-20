# Stage 3 premises — 2026-11-18-backlog-sweep-sub-05-live-plan

Goal: A person who installs or updates nice-dns gets the swept code with release assets that match it.
Risk: MEDIUM — a pushed tag starts a public release build. The lock is changed only by the script's reviewed diff, and an unchanged lock keeps every install on the last good assets.

Outcomes:
- Works: release v1.5.0 exists with the helper and GUI assets for each platform, and an install fetches exactly the files `release/assets.lock` pins
- The release build fails → no tag is left pinned in the lock; the lock stays on v1.4.1 and installs keep working

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: this laptop can push the branch and a tag to origin and create a release (Task 3.1, OD-4)
Checked: `gh auth status`; `git remote -v`; `git fetch origin` (2026-11-20 08:58 UTC)
Result: logged in (keyring), scopes include repo and workflow; origin is github.com/sureserverman/nice-dns; origin/main = main = 710031f, an ancestor of sweep-live; no sweep-live on origin yet
Verdict: holds

## Premise 2
Assumption: v1.5.0 is free and the lock still pins v1.4.1 (Stage 3 failure Outcome)
Checked: `git ls-remote --tags origin 'v1.*'`; `git tag -l 'v1.5*'`; `grep -P '^release\t' release/assets.lock`
Result: remote tags end at v1.4.1, no local v1.5*; the lock's release row is v1.4.1 with 6 asset rows
Verdict: holds

## Premise 3
Assumption: a v* tag starts the release workflow, which publishes the six assets with no version file to bump first (Task 3.1)
Checked: `.github/workflows/release.yml` lines 11-13, 129-132, 166-168; `gh workflow list`; `gh run list --workflow release.yml --limit 3`
Result: `on: push: tags: ["v*"]`; the mac app takes its version from the tag (`make VERSION="${TAG#v}"`), the crates keep their own versions; `gh release create "$TAG" --verify-tag`; workflow active; v1.4.1, v1.4.0 and v1.3.0 runs succeeded
Verdict: holds

## Premise 4
Assumption: the lock script compares and writes against a published tag (Task 3.1 Test)
Checked: `scripts/update-assets-lock.sh --help`
Result: `usage: update-assets-lock.sh [--lock FILE] [--tag vX.Y.Z] [--write]`
Verdict: holds
