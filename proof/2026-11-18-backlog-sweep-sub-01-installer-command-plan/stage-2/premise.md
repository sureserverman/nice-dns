# Stage 2 premises — 2026-11-18-backlog-sweep-sub-01-installer-command-plan

Goal: A person whose install rolled back keeps a working app, and a person who uninstalls keeps working DNS even when the restore fails.
Risk: MEDIUM — Task 2.2 changes what a rollback does to a root-held file the helper executes, and Task 2.4 reorders the uninstall. Fixtures cover both; Sub-plan 5 runs the live install lifecycle.

Outcomes:
- Works: after an install that rolled back, a GUI action that needs root still runs through the helper, with no terminal
- Works: an uninstall gives the host's DNS back first and stops the stack after
- The DNS restore fails during an uninstall → the stack keeps running and answering, the message names the cause and says to run `nice-dns uninstall` again, exit status is not 0
- A full disk interrupts the first route seed → the next install says the route record is incomplete and seeds it again, and never treats the half-written file as the controller's

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: the root-held root-ops the helper runs lives at a fixed root path on both platforms, outside the user's tree, so a rollback that does not rewrite it leaves the old tree and the held copy apart (the BL-063 defect Task 2.2 fixes).
Checked: `ssh mint ls -l /usr/libexec/nice-dns/root-ops /usr/libexec/nice-dns-helper`; `ssh mac ls -l /usr/local/libexec/nice-dns/root-ops /usr/local/libexec/nice-dns-helper`; `ssh mint command -v pkexec` (2026-11-18).
Result: mint: both root:root 0755, dated Nov 10; pkexec at /usr/bin/pkexec. mac: root-ops root:wheel 0755, the helper root:wheel 4755 (setuid), dated Nov 10.
Verdict: holds

## Premise 2
Assumption: on Linux the host's DNS can be given back (systemd-resolved re-enabled) while the stack still holds port 53, so restoring before stopping (Task 2.4) does not collide on the address.
Checked: `ssh mint ss -lnup/-lntp "sport = :53"`; `grep DNSStubListener /etc/systemd/resolved.conf{,.d/*}`; as the user on mint, a UDP bind of 127.0.0.53:53 and 127.0.0.54:53 while the stack runs (`ip_unprivileged_port_start` is 53).
Result: the pod's rootlessport holds 127.0.0.1:53 only (UDP and TCP), not the wildcard; no DNSStubListener override, so resolved uses its default 127.0.0.53/127.0.0.54; both addresses bound and released cleanly beside the running stack.
Verdict: holds

## Premise 3
Assumption: on macOS, pinning the network services' DNS away from 172.31.240.250 does not need the containers stopped first.
Checked: not run: changing the Mac's DNS mid-plan is a live step the plan reserves for Sub-plan 5 (Risk line).
Result: —
Verdict: not checkable here — a live DNS change on the Mac is out of this stage's fixture-only scope; Sub-plan 5's live lifecycle carries it
