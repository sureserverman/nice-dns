# Stage 3 premises — 2026-11-10-app-switches-autocheck-plan

Goal: The owner's two machines run the released apps, and a switch and a scheduled check are shown working on mint and on the mac.
Risk: MEDIUM — six reinstalls on two machines over ssh, and a pushed tag; the installers are transactional and both targets are disposable by rule.

Outcomes:
- Works: an install or `nice-dns update` on Linux and macOS lands the v1.4.0 apps with the selectors, and the controller's third schedule
- Works: on mint and on the mac, the proxy switch run from the app's own action changes the running proxy container and `status`; the hardened switch builds from the tree with no checkout on the host; DNS answers after each; the scheduled check, started by hand, updates `checked_at`
- A release asset cannot be fetched or its sha256 differs → the install goes on without the GUI, as today; the stack and the command are installed
- A live cell fails → its receipt row names the cell and the step; only that cell is rerun (DEC-009); the target is put back on its recorded choices
- A live target is offline → the cell is not run and the gate is not ticked; the owner is asked to wake it

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: the owner's GitHub account can push the branch and a v* tag, and a v* tag runs release.yml and publishes the assets
Checked: gh auth status; gh api repos/sureserverman/nice-dns --jq .permissions.push; gh release view v1.3.0 --json tagName,assets; grep tags .github/workflows/release.yml
Result: logged in as sureserverman; push true; v1.3.0 has 12 assets; release.yml runs on tags ["v*"]
Verdict: holds

## Premise 2
Assumption: mint and the mac answer, and the harness reaches each one's user session (mint's user systemd, the mac's gui-domain runtime through launchctl asuser)
Checked: target.sh probe mint|mac; target.sh snapshot then target.sh command <alias> --mode status (ARTIFACT_DIR in the scratchpad)
Result: both probes exit 0 with the three containers running; status --tsv on both: installed yes, 671d950, variant socat, pihole standard, controller active OK; bridges off on mint, on on the mac
Verdict: holds (the recorded choices are socat/standard on both; mint's bridges stay off)

## Premise 3
Assumption: neither host has a pi-hole-hardened checkout the old sibling lookup could have used, so the hardened switch proves the in-tree build
Checked: ssh mint|mac 'ls -d ~/.local/share/nice-dns/pi-hole-hardened ~/pi-hole-hardened ~/dev/pi-hole-hardened'; on the mac also ~/nice-dns-gui-build/pi-hole-hardened
Result: No such file or directory for every path on both hosts
Verdict: holds

## Premise 4
Assumption: launchd accepts an array of StartCalendarInterval dictionaries (the twice-a-day agent)
Checked: ssh mac 'man launchd.plist | col -b | grep -A8 StartCalendarInterval'
Result: "<dictionary of integers or array of dictionaries of integers> ... Multiple dictionaries may be specified in an array to schedule multiple calendar intervals."
Verdict: holds

## Premise 5
Assumption: both hosts have the v1.3.0 apps installed, so a v1.4.0 install has an app to replace
Checked: ssh mint 'ls -l ~/.local/bin/nice-dns-gui ~/.local/share/applications/nice-dns.desktop'; ssh mac 'ls -d ~/Applications/nice-dns.app'
Result: present on both (mint's from 2026-11-10 21:15)
Verdict: holds

## Premise 6
Assumption: the hosts can pull the Alpine base pinned in release/images.lock (hardened-os, docker.io/library/alpine@sha256:a8560b36...)
Checked: mint: podman pull -q docker.io/library/alpine@sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c
Result: mint: pulled (image aded1e1a5b37), exit 0. mac: not pulled
Verdict: holds on mint; mac not checkable here — over plain ssh the mac's container runtime is in another launchd domain (BL-052, a plain-ssh runtime call wedged vmnet on 2026-11-07); Task 3.3's hardened step pulls it inside the gui session
