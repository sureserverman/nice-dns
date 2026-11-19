# Stage 1 premises — 2026-11-18-backlog-sweep-sub-05-live-plan

Goal: A person who installs today's main on Linux or on a Mac gets what the fixtures promised: the lifecycle, the recovery, the bridges switch and the transport security all hold on real machines.
Risk: MEDIUM — the groups reinstall and fault two real hosts. Both are disposable by rule, each group has a green dry-run twin first, and the installer rolls back on failure.

Outcomes:
- Works: install, reinstall, a rolled-back install and uninstall behave on mint and the mac as Sub-plans 1 and 3 changed them; DNS answers after each step that should leave it answering
- Works: a stopped or frozen container is recovered by the controller on both targets; a bridges switch off and on comes back, also with only 2 bridges on Linux
- Works: on both targets a bogus DNSSEC answer and a wrong TLS name are refused, and Unbound has no network control listener
- Works: the legacy `:853` route presents a certificate that verifies for its name behind each proxy

These Outcomes are what `Stage N green` is checked against. Changing one after
this point needs the owner's words in its amendment note: owner, <date>: "<words>".

One entry per thing the Goal, Outcomes or Risk assume about what the code does
not control (the platform, another app, a permission, the engine, a service).
Check each on the real environment before building on it. Verdict: holds, false,
or not checkable here — <why>. A false premise is a Stop condition.

## Premise 1
Assumption: both targets take a harness command today (Early premise)
Checked: `bash tests/live/target.sh probe mint --targets tests/live/targets.env`, the same for `mac` (2026-11-19 22:00 UTC)
Result: rc 0 each; mint Linux Mint 22.3, podman 5.8.1, nice-dns-infra/unbound/pi-hole/tor-socat running; mac macOS 27.2.1, container CLI 1.7.1, unbound .251, tor-socat .252, pi-hole .250 running
Verdict: holds

## Premise 2
Assumption: over plain ssh the mac's gui container runtime is reachable through launchctl asuser (DEC-024), which the mac cells use
Checked: `ssh mac 'sudo -n launchctl asuser $(id -u) sudo -n -u $USER /opt/homebrew/bin/container ls; launchctl managername'`
Result: the three containers listed, running since 18:01 UTC; managername `Background` (so plain ssh alone cannot see the runtime, as BL-052 says)
Verdict: holds

## Premise 3
Assumption: mint holds a bridge pool the bridges-on step (and BT-ON-FEW, 2 bridges) can use, though it sits in bridges-off mode
Checked: `ssh mint 'cat ~/.config/nice-dns/bridges-mode.env; grep -c "^Bridge\|obfs4" ~/.config/nice-dns/bridges.env'` (count only, no bridge line read back)
Result: `TOR_BRIDGES=off`; 7 matching lines in bridges.env (kept while off, as CLAUDE.md says)
Verdict: holds

## Premise 4
Assumption: the compat route exists in the route table and mint has the tor-haproxy image for the switch (Task 1.4)
Checked: `grep cloudflare-legacy routes/providers.tsv`; `ssh mint 'podman images ... | grep -i tor-'`
Result: `cloudflare-legacy 853 tor.cloudflare-dns.com cloudflare compat` (routes/providers.tsv:17); docker.io/sureserver/tor-haproxy:latest present on mint (sha256:21ba507e...)
Verdict: holds

## Premise 5
Assumption: both stacks answer before Stage 1 faults them, so a failure later is this run's
Checked: `ssh mint 'dig @127.0.0.1 +time=5 +tries=2 +short cloudflare.com'`; `ssh mac 'dig @172.31.240.250 +time=5 +tries=2 +short cloudflare.com'`
Result: both printed 104.16.133.229 and 104.16.132.229
Verdict: holds
