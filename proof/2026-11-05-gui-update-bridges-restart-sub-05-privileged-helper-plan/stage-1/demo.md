# Stage 1 demo — 2026-11-05-gui-update-bridges-restart-sub-05-privileged-helper-plan

Environment: mint (Linux Mint, Podman) and mac (macOS 27, Apple container), both tor-socat standard; the demo evaluator ran the literal user route on 055450a: a `git archive` unpacked to `~/nd-demo-055450a`, the installer run from it over `ssh -tt`. Its full notes: `.claude/evidence/sp5/stage-1-demo.md` (local, gitignored); the evidence below is copied from them (no bridge lines).

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: `install-deb.sh` and `install-mac.sh` from a terminal prompt for sudo once (plus the keepalive) and run the same root steps as before, now as `sudo bash <tree>/<os>/root-ops <verb>` lines.
Verdict: holds (mint fully observed; the mac in part: it logs no sudo command lines)
Evidence:
Evidence:

mint, `bash install-deb.sh socat` (10:41:29–10:44:45Z): `INSTALLER_RC=0`. Screen ends with
"Chain is resolving, and Unbound resolves over its authenticated route." / "System-wide DNS now points to 127.0.0.1:53" /
"Generation 20261108T104129Z-nogit0000000 is active (previous: 20261107T131109Z-...)".

Every sudo command in that window (`journalctl _COMM=sudo`; `<tree>` = /home/user/nd-demo-055450a):

```
10:41:30 /usr/bin/bash <tree>/deb/root-ops dns check
10:41:30 /usr/bin/bash <tree>/deb/root-ops host-prereqs
10:42:04 /usr/bin/bash <tree>/deb/root-ops save-previous <path>   x9 (custom-dns-deb, 90-nice-dns-pin, 91-nice-dns-ipv6 x2,
         custom-dns-deb.service, 90-nice-dns.conf, 99-nice-dns-disable-ipv6.conf, 99-podman-privileged-ports.conf,
         10-wait-for-connectivity.conf)
10:42:20 validate                                  (the sudo -n -v keepalive)
10:43:49 /usr/bin/bash <tree>/deb/root-ops dns snapshot
10:44:03 /usr/bin/bash <tree>/deb/root-ops interrupt-prereqs
10:44:40 /usr/bin/bash <tree>/deb/root-ops pin
10:44:43 /usr/bin/bash <tree>/deb/root-ops dns status
10:44:44 /usr/bin/bash <tree>/deb/root-ops profiles-done
```

No other sudo command ran. Baseline for "as before": the last pre-Stage-1 install on mint
(2026-11-07 13:11Z, same journal) ran ~60 bare sudo lines in the same order:
`custom-dns-deb check` → podman-ppa tee, apt-get update/--fix-broken/install, passt AppArmor, privileged-ports sysctl,
delegate.conf, daemon-reload, enable-linger → `test -f`/`cat` of the same 9 owned files → `custom-dns-deb snapshot` →
install service + helper, enable, NM conf + dispatchers, reload NM, ipv6 sysctl, dispatcher runs, `ipv6-profiles` → `pin` → `status` → `ipv6-profiles-done`.
The new run maps onto it verb for verb (check → host-prereqs → save-previous x9 → snapshot → pin → status → profiles-done).
Effects on disk match: apt output shown on screen; /etc/apparmor.d/usr.bin.passt, 99-podman-privileged-ports.conf, delegate.conf rewritten 10:41:59;
custom-dns-deb + .service 10:44:40; NM conf, dispatchers, ipv6 sysctl 10:44:43; `systemctl is-enabled custom-dns-deb` = enabled; Linger=yes;
NetworkManager journal "Reloading NetworkManager.service" at 10:44:43; /etc/resolv.conf = `nameserver 127.0.0.1`.
`interrupt-prereqs` is a verb with no counterpart line in the baseline; it changed no file under /etc, /usr/bin, /usr/local (find -newermt).
`dig @127.0.0.1 cloudflare.com` → 104.16.133.229, 104.16.132.229.

mac, `install-mac.sh socat` (10:42:37Z start): `INSTALLER_RC=0`. Screen ends with
"/etc/sudoers.d/start-container: parsed OK" (visudo) / "LaunchAgent installed (variant=socat): start-container." /
"Generation 20261108T104237Z-nogit0000000 is active" / "All done. DNS is set to 172.31.240.250 (pi-hole)."
The macOS unified log does not record sudo command lines on this host (`log show --predicate 'process == "sudo"'` gives only
config/group-lookup lines), so the full verb list could not be read. A 0.3 s `ps` sampler during the install caught, as root:
`sudo bash /Users/user/.nice-dns-install.0c6SAhco/nice-dns/mac/root-ops agent post`. Effects: /etc/sudoers.d/start-container and
/usr/local/sbin/{start-container.sh,start-container-root.sh,nice-dns-fetch-bridges.sh,nice-dns-bridge-eval.sh} rewritten 10:44;
`networksetup -getdnsservers` = 172.31.240.250 on Ethernet, Thunderbolt Bridge, Wi-Fi. `dig @172.31.240.250 cloudflare.com` → 104.16.132.229, 104.16.133.229.

"Prompt for sudo once": not observable (NOPASSWD on both targets). On mint, each root step is its own `sudo` call, with one `validate` (keepalive) line.


## Outcome 2
> A verb is unknown or an argument malformed → root-ops exits 2 with the verb named; the installer aborts before any change, or rolls back if one was made.
Verdict: holds — root-ops' half seen by this demo on both hosts; the installer's half cannot be reached by the user's route and is shown instead by t_root_ops_refusal_aborts_or_rolls_back (owner, 2026-11-08: "Prove it by fixture test (Recommended)"; the test passes, run in the round-1 fix-scope)
Evidence:
Evidence (operator running root-ops by hand as root, `sudo -n bash ~/nd-demo-055450a/<os>/root-ops ...`):

mint:
```
(no verb)                         root-ops: no verb given                                              rc=2
frobnicate                        root-ops: unknown verb 'frobnicate'                                  rc=2
--help                            root-ops: unknown verb '--help'                                      rc=2
'pin;id'                          root-ops: unknown verb 'pin;id'                                      rc=2
dns                               root-ops: verb 'dns' takes 1 argument(s), got 0                      rc=2
dns frob                          root-ops: verb 'dns': unknown helper verb 'frob'                     rc=2
dns 'check status'                root-ops: verb 'dns': unknown helper verb 'check status'             rc=2
save-previous /etc/shadow         root-ops: verb 'save-previous': '/etc/shadow' is not a file nice-dns owns   rc=2
save-previous /usr/bin/custom-dns-deb/../../../etc/shadow   ... is not a file nice-dns owns            rc=2
save-previous                     root-ops: verb 'save-previous' takes 1 argument(s), got 0            rc=2
pin extra-arg                     root-ops: verb 'pin' takes 0 argument(s), got 1                      rc=2
host-prereqs --yes                root-ops: verb 'host-prereqs' takes 0 argument(s), got 1             rc=2
```
90-nice-dns.conf mtime unchanged (10:44:43) before and after; DNS kept answering.

mac:
```
(no verb)                         root-ops: no verb given                                              rc=2
frobnicate / --help / 'pin;id'    root-ops: unknown verb '<verb>'                                      rc=2
agent                             root-ops: verb 'agent' takes 1 argument(s), got 0                    rc=2
agent frob / agent 'post;id'      root-ops: verb 'agent': unknown helper verb '<arg>'                  rc=2
agent post extra                  root-ops: verb 'agent' takes 1 argument(s), got 2                    rc=2
save-previous /etc/master.passwd  root-ops: verb 'save-previous': '/etc/master.passwd' is not a file nice-dns owns   rc=2
```

Installer half: no user input reaches a root-ops verb or argument. Malformed installer arguments are rejected by the
installer itself, exit 1, before any root step:
`install-deb.sh frob` / `install-deb.sh 'socat;id'` → "Unknown arg '...'. Use 'haproxy', 'socat', or 'uninstall'." rc=1, no sudo line logged;
`install-mac.sh frob` / `'socat;id'` → same message, rc=1, sudoers/helpers mtimes unchanged.
Making the installer send root-ops a bad verb needs an edited tree or a test hook, so "installer aborts / rolls back on root-ops exit 2"
was not reached. It needs a test or a source review, not a demo.


## Outcome 3
> root-ops is run as a non-root user → exit 1 `must run as root`.
Verdict: holds
Evidence:
Evidence: `bash <tree>/<os>/root-ops <args>` as user `user`:
mint: (none), `dns check`, `host-prereqs`, `frobnicate` → each `root-ops: must run as root`, rc=1.
mac: (none), `dns-pin`, `frobnicate` → each `root-ops: must run as root`, rc=1.
The root check runs before verb parsing (an unknown verb as non-root still gets exit 1, not 2).


## Outcome 4
> A rollback or uninstall → the same verbs in reverse, as today.
Verdict: holds for the uninstall (mint, seen); the rollback was not exercised here and is covered by the fixture lifecycle and t_root_ops_refusal_aborts_or_rolls_back
Evidence:
Evidence: mint `bash install-deb.sh uninstall` (10:49Z): `INSTALLER_RC=0`, screen "custom-dns-deb: NetworkManager profile <uuid> has ipv6.method auto again" x4 /
"custom-dns-deb: restored the resolver state from before nice-dns (fresh)" / "nice-dns uninstalled."
sudo lines:
```
10:49:41 /usr/bin/bash <tree>/deb/root-ops dns restore
10:49:55 /usr/bin/bash <tree>/deb/root-ops uninstall
```
Baseline pre-Stage-1 uninstall (2026-11-06 15:08Z): `custom-dns-deb restore` → `rm -f /usr/bin/custom-dns-deb` → `test -f grub cfg` → `daemon-reload`. Same shape.
After: resolv.conf back to `nameserver 127.0.0.53` (systemd-resolved active); custom-dns-deb, .service, NM conf, 90/91 dispatchers, ipv6 sysctl,
privileged-ports sysctl and the wait-online drop-in gone; NM profiles ipv6.method auto; `dig cloudflare.com` via the system resolver answers; `dig @127.0.0.1` refused (expected).
Left in place, as before: delegate.conf, usr.bin.passt, podman-ppa preference, Linger=yes.

Reinstall `bash install-deb.sh socat` (10:50:46–10:54:30Z, "previous none, rollback none"): `INSTALLER_RC=0`; same verb sequence as Outcome 1 plus
`nm-wait-dropin` (10:53:43) because the uninstall had removed that drop-in. `dig @127.0.0.1 cloudflare.com` → answers.

## Findings (none Blocking from an observed defect)

- Blocking per the demo rule, evidence gap only: Outcome 2's installer half ("aborts before any change, or rolls back") cannot be reached by the user's route. No user input becomes a root-ops argument. Needs a test or a source check.
- Material, evidence gap: on the mac the full verb sequence of an install could not be listed (no sudo command logging; only `agent post` seen by sampling). Effects and screen text match a normal install. `eslogger exec` works over ssh on this mac and could record the verbs on a later run.
- Minor: `install-deb.sh socat 'main;x'` takes a malformed branch argument without complaint and starts a real install. The branch is unused (the installer installs its own tree). My run piped it through `head`, so SIGPIPE stopped it after `host-prereqs`. No change was made past host-prereqs: no save-previous, same containers, DNS answered. Not a Stage 1 regression.
- Minor: `root-ops --help` gives `unknown verb '--help'` (exit 2) and prints no verb list, so a reviewer of the allow-list cannot list the verbs from the tool.
- Note: rollback (a failure after a change) was not exercised. Prompt-once could not be observed (NOPASSWD sudo on both targets).

## End state

mint: tor-socat standard, generation 20261108T105046Z, resolv.conf 127.0.0.1, `dig @127.0.0.1` answers. (Uninstall/reinstall wiped Tor state, lists and the admin password; a new password was generated.)
mac: tor-socat standard, generation 20261108T104237Z, DNS pinned 172.31.240.250 on every service, `dig @172.31.240.250` answers.
Demo trees left at ~/nd-demo-055450a on both targets. Every background job and monitor finished on its own.
