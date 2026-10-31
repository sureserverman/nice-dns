# Stage 2 demo — 2026-10-30-nice-dns-command-and-unbound-recovery-plan

Environment: `ssh mint` (Linux, Podman quadlets) and `ssh mac` (macOS 26, Apple container), checkout ~/nice-dns-ci/nice-dns at e13e53e, 2026-10-31. Mac install, reinstall and uninstall ran in the GUI session through `launchctl asuser`; mac restart ran from plain ssh.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: `./nice-dns install [haproxy|socat] [--hardened] [--branch B]` from a checkout installs and leaves `nice-dns` on PATH. `reinstall` and `restart` work from any directory, and `uninstall` removes the stack and then the command itself.
Verdict: holds
Evidence:
MINT. Plain ssh. Before: stack from an earlier install script, no `~/.local/bin/nice-dns`.
- `./nice-dns install --branch no-such-branch`: `fatal: Remote branch no-such-branch not found in upstream origin`, `nice-dns: could not fetch branch 'no-such-branch' (is DNS down?). The running stack is untouched.`, exit 1, about 1 s. Container IDs and start times identical before and after. `--branch B` succeeding was not reachable here (the branch is not on GitHub).
- `./nice-dns install haproxy` from ~/nice-dns-ci/nice-dns: exit 0, about 2.5 min. `Generation 20261031T004402Z-e13e53e0b4d1 is active`. All four containers new. `bash -lc 'command -v nice-dns'` → /home/user/.local/bin/nice-dns (mode 755).
- From /tmp in a login shell, `nice-dns restart`: `Restarting the stack...`, `Chain is resolving, and Unbound resolves over its authenticated route.`, `nice-dns restarted; DNS is answering.`, exit 0, 25 s. All container IDs changed; dig answers.
- From /tmp in a login shell, `nice-dns reinstall --local`: exit 0, 2 m 49 s. `Generation 20261031T004720Z-nogit0000000 is active (previous: 20261031T004402Z-e13e53e0b4d1)`. Containers new; resolv.conf 127.0.0.1; dig answers. The clone path's success was not reachable here (the branch is not on GitHub).

- From /tmp, `nice-dns uninstall`: exit 0, 1 m 45 s, ends `custom-dns-deb: restored the resolver state from before nice-dns (fresh)`, `nice-dns uninstalled.`. After: `command -v nice-dns` empty in plain and login shell, ~/.local/bin empty, no containers, no units, ~/.local/share/nice-dns gone. DNS given back: /etc/resolv.conf → stub-resolv.conf, 127.0.0.53, systemd-resolved active, `getent hosts github.com` answers, `dig @127.0.0.1` connection refused. Leftovers: see findings.

MAC. Installs and reinstalls run in the GUI session (`sudo -n launchctl asuser <uid> sudo -n -u <user> env HOME=... PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin <cmd>`). `restart` over plain ssh.
- `./nice-dns install --branch no-such-branch`: `fatal: Remote branch no-such-branch not found in upstream origin`, `nice-dns: could not fetch branch 'no-such-branch' (is DNS down?). The running stack is untouched.`, exit 1. Start times unchanged.
- `./nice-dns install haproxy`: exit 0, about 2 min. `Generation 20261031T005604Z-e13e53e0b4d1 is active`. `zsh -lic 'command -v nice-dns'` → /Users/user/.local/bin/nice-dns.
- `nice-dns restart` from /tmp: exit 0, 19 s, stack really recreated (see Outcome 6).
- `nice-dns reinstall --local` from /tmp: exit 0, 64 s. `Generation 20261031T010250Z-nogit0000000 is active (previous: 20261031T005604Z-e13e53e0b4d1)`. Containers recreated 01:03:37/38Z, DNS .250, dig answers. Clone path's success not reachable here.

MINT final: `./nice-dns install haproxy` from the checkout after uninstall: exit 0. `Generation 20261031T010014Z-e13e53e0b4d1 is active (previous: none)`. `System-wide DNS now points to 127.0.0.1:53`; /etc/resolv.conf a plain file with `nameserver 127.0.0.1`; dig @127.0.0.1 and `getent hosts github.com` answer; nice-dns back; Source commit e13e53e; Drift none. DNS given back and pinned again.

- MAC `nice-dns uninstall` from /tmp, GUI session: exit 0, 107 s, `Uninstalled.`, `restored the DNS servers recorded before nice-dns`, `nice-dns uninstalled.`. After: `zsh -lic 'command -v nice-dns'` empty, no nice-dns files in ~/.local/bin, none of the three containers, ~/.local/share/nice-dns gone. DNS given back: `networksetup -getdnsservers` empty on all services, resolver 192.168.0.1, github.com resolves, dig @172.31.240.250 times out. Leftovers: see findings.

- MAC final: `./nice-dns install haproxy` from the checkout after uninstall, GUI session: exit 0, 119 s. `Generation 20261031T011150Z-e13e53e0b4d1 is active (previous: none)`, `All done. DNS is set to 172.31.240.250`. All three services back on .250, dig answers, github.com resolves, `nice-dns` back in the zsh login PATH. DNS given back and pinned again.

- MAC variants, GUI session: `./nice-dns install socat` exit 0, 93 s, tor-socat running, dig answers. `nice-dns reinstall --local` from /tmp exit 0, 70 s, stays tor-socat (choice remembered). `./nice-dns reinstall haproxy` exit 0, 89 s, tor-haproxy running, dig answers. `--hardened` success not reachable on mac (no sibling).

- MINT variants: `./nice-dns install socat` exit 0, 226 s, tor-socat. `nice-dns reinstall --local` from /tmp exit 0, 155 s, `Variant: socat (Pi-hole: standard)` (remembered). `./nice-dns reinstall haproxy --hardened` exit 0, 191 s, `Variant: haproxy (Pi-hole: hardened)`. `nice-dns restart` from /tmp exit 0, 23 s. `nice-dns reinstall --local` exit 0, 199 s, stays hardened. `./nice-dns reinstall --standard` exit 0, 195 s, `Variant: haproxy (Pi-hole: standard)`. dig answered after each.
Not reachable here: a successful clone (`nice-dns reinstall` without --local, `install --branch B`), because the branch is not on GitHub.
Final state, both hosts: stack on haproxy standard from e13e53e, nice-dns present, dig answers (mint 127.0.0.1, mac 172.31.240.250), no iptables rule, pf anchor empty, mint's pi-hole-hardened back in place.

## Outcome 2
> Run as root → refuses with the same message as the installers, exit 1.
Verdict: holds
Evidence:
Both hosts, from the checkout, stdout and stderr captured separately:
- `sudo -n ./nice-dns install`, `restart`, `reinstall`, `uninstall`: each prints on stderr `Please run nice-dns as a regular user, not with sudo.`, exit 1, on mint and on mac.
- Comparison on mint: `sudo -n ./install-deb.sh` prints `Please run install-deb.sh as a regular user, not with sudo.`, exit 1. Same wording, own name.
- Comparison on mac: `sudo -n ./install-mac.sh` prints `Run install-mac.sh as a regular user, not sudo.`, exit 1. Wording differs from the command's (see Minor finding).

## Outcome 3
> Unknown subcommand or option → usage on stderr, exit 2.
Verdict: holds
Evidence:
Both hosts identical (mint and mac), from the checkout:
- `./nice-dns` → stderr `nice-dns: no command given` + usage, stdout empty, exit 2.
- `./nice-dns frobnicate` → stderr `nice-dns: unknown command 'frobnicate'` + usage, stdout empty, exit 2.
- `./nice-dns install --bogus`, `install nope`, `restart --bogus`, `uninstall --bogus`, `reinstall --bogus` → stderr `nice-dns: unknown option '<x>' for <cmd>` + usage, stdout empty, exit 2.
- `./nice-dns --help` → usage on stdout, exit 0.
Usage lists install, reinstall, restart, uninstall.

## Outcome 4
> `reinstall` or `restart` with nothing installed → "nice-dns is not installed; run `nice-dns install`", exit 1, nothing changed.
Verdict: holds
Evidence:
MINT, after `nice-dns uninstall`, from the checkout (the installed command is gone):
- `./nice-dns reinstall`, `./nice-dns restart`, `./nice-dns reinstall --local`: each prints on stderr only `nice-dns: nice-dns is not installed; run `nice-dns install``, exit 1. Containers 0 before and after; quadlet dir count and resolv.conf hash unchanged.

MAC, after `nice-dns uninstall`, from the checkout, GUI session: `./nice-dns reinstall`, `./nice-dns restart`, `./nice-dns reinstall --local`: each stderr only `nice-dns: nice-dns is not installed; run `nice-dns install``, exit 1. Container count, Wi-Fi DNS and LaunchAgent list unchanged. (The one listed container is a stopped `buildkit`, not the stack.)

## Outcome 5
> `reinstall` clone fails (DNS is down) → says so and names `nice-dns reinstall --local`, which uses the kept snapshot; the running stack is untouched.
Verdict: holds
Evidence:
mint, installed command, cwd /tmp, PATH=$HOME/.local/bin:$PATH. Before and after compared: `podman ps` IDs and start times unchanged.
A. DNS up, `nice-dns reinstall` (clone fails on the unpublished branch):
  warning: Could not find remote branch command-recovery to clone.
  fatal: Remote branch command-recovery not found in upstream origin
  nice-dns: could not fetch branch 'command-recovery' (is DNS down?). The running stack is untouched.
  nice-dns: Run `nice-dns reinstall --local` to use the source kept at the last install.
  [exit 1]
B. DNS really down for the user: `iptables -I OUTPUT -o lo -p udp|tcp --dport 53 -m owner --uid-owner 1000 -j REJECT`; `getent hosts github.com` rc=2; `dig @127.0.0.1` "no servers could be reached". `nice-dns reinstall`:
  fatal: unable to access 'https://github.com/sureserverman/nice-dns.git/': Could not resolve host: github.com
  nice-dns: could not fetch branch 'command-recovery' (is DNS down?). The running stack is untouched.
  nice-dns: Run `nice-dns reinstall --local` to use the source kept at the last install.
  [exit 1]
  Containers before and after B: infra 284800999a48, tor 8796c7d168c2, unbound ae38d5a56498, pi-hole 6d2a9d0c82fa, same start times. Rule removed afterwards.
The named route was run on mint from /tmp: `nice-dns reinstall --local` exit 0, new generation, all four containers recreated (see Outcome 1).

MAC, installed command run in the GUI session (`launchctl asuser ... sudo -u ... env ...`), cwd /tmp.
A. DNS up, `nice-dns reinstall`: `fatal: Remote branch command-recovery not found in upstream origin`, `nice-dns: could not fetch branch 'command-recovery' (is DNS down?). The running stack is untouched.`, `nice-dns: Run `nice-dns reinstall --local` to use the source kept at the last install.`, exit 1.
B. DNS really down: `networksetup -setdnsservers Ethernet|Wi-Fi 192.0.2.1` and cache flush, restored straight after. (A first try with a pf block on the dig path did not stop DNS: dig still answered, so that run does not count.) Proof: `git ls-remote` → `Could not resolve host: github.com`. `nice-dns reinstall`, 30 s:
  fatal: unable to access 'https://github.com/sureserverman/nice-dns.git/': Could not resolve host: github.com
  nice-dns: could not fetch branch 'command-recovery' (is DNS down?). The running stack is untouched.
  nice-dns: Run `nice-dns reinstall --local` to use the source kept at the last install.
  [exit 1]
  All three containers' start times unchanged (01:00:24/25/26Z).

## Outcome 6
> `restart` gets no DNS answer within its wait → says DNS is not answering yet and names `nice-dns-health status`, exit 1.
Verdict: holds
Evidence:
MINT. Installed command, cwd /tmp. Fault: `iptables -I OUTPUT -o wlp12s0 -m conntrack --ctstate NEW -m owner --uid-owner 1000 -j REJECT` (Tor cannot open connections). `ND_INST_READY_TRIES=6 nice-dns restart` (wait shortened to 6 tries, 5 s apart):
  [stdout] Restarting the stack...
  [stdout] Waiting for the DNS chain to come up at 127.0.0.1 (Tor bootstrap takes 1-4 min)...
  [stderr] nice-dns: the stack restarted, but DNS is not answering yet. Check `nice-dns-health status`.
  [exit 1]  55 s. Containers were recreated (new IDs, 00:51:07). `dig @127.0.0.1 cloudflare.com` → timed out. Rule removed.

MAC, success path, `nice-dns restart` from /tmp, plain ssh: before pi-hole/unbound/tor started 00:57:02/03/04Z; ran 01:00:15 to 01:00:34; `Chain is resolving, and Unbound resolves over its authenticated route.`, `nice-dns restarted; DNS is answering.`, exit 0, 19 s. After: started 01:00:24/25/26Z, so printed about 8 s after all three were really recreated. The success message follows a real rebuild.

MAC, fault path. Fault: pf anchor com.apple/261.nddemo `block drop quick from 172.31.240.248/29 to any`, states killed. `ND_INST_READY_TRIES=6 nice-dns restart` from /tmp, plain ssh:
  [stdout] Restarting the stack...
  [stderr] nice-dns: the stack restarted, but DNS is not answering yet. Check `nice-dns-health status`.
  [exit 1]  300 s, not 30 s: the shortened wait did not apply on the mac (see findings). Containers recreated 01:04:32-34Z; log `stack rebuilt on expected addresses`; dig @172.31.240.250 timed out during the fault. Rule removed: anchor empty; `tor bootstrapped` in the log within seconds of removal.

## Outcome 7
> `~/.local/bin` is not on PATH → the install prints the full path and how to add it.
Verdict: holds
Evidence:
mint (ssh PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games, no ~/.local/bin), `./nice-dns install haproxy` last line of output, exit 0:
`Manage the stack with /home/user/.local/bin/nice-dns; to run it as nice-dns, add this line to your shell profile: export PATH="/home/user/.local/bin:$PATH"`

mac, install in the GUI session (`sudo -n launchctl asuser <uid> sudo -n -u <user> env HOME=... PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin ./nice-dns install haproxy`), PATH without ~/.local/bin; last line, exit 0:
`Manage the stack with /Users/user/.local/bin/nice-dns; to run it as nice-dns, add this line to your shell profile: export PATH="/Users/user/.local/bin:$PATH"`

## Outcome 8
> `reinstall --hardened` without the sibling `pi-hole-hardened` checkout → the installer's existing refusal, before any change.
Verdict: holds
Evidence:
MINT, sibling moved aside (put back afterwards). Before: infra 9c3328793ebc, tor 112dd3e29b4d, unbound 8fc0977033f3, pi-hole 8a54150edb91; generation 20261031T004720Z-nogit0000000.
- `./nice-dns reinstall --hardened` from the checkout: `nice-dns install: the hardened base is not published (release/images.lock); clone https://github.com/sureserverman/pi-hole-hardened next to nice-dns/ (/home/user/nice-dns-ci/pi-hole-hardened) and run again`, exit 1, 18 s.
- `nice-dns reinstall --hardened --local` from /tmp: same refusal naming /home/user/.local/share/nice-dns/pi-hole-hardened, exit 1, 18 s.
- `./install-deb-hardened.sh` directly: the same refusal line, exit 1.
- After all three: same container IDs, start times, generation; dig answers. The refusal does come after sudo sysctl output and `pre-<timestamp>` image tagging (see findings).

MAC (no sibling exists), GUI session. Before: start times 01:00:24/25/26Z, active generation 20261031T005604Z-e13e53e0b4d1.
- `./nice-dns reinstall --hardened`: `nice-dns install: the hardened base is not published (release/images.lock); clone https://github.com/sureserverman/pi-hole-hardened next to nice-dns/ (/Users/user/nice-dns-ci/pi-hole-hardened) and run again`, exit 1, about 8 s.
- `nice-dns reinstall --hardened --local` from /tmp: same refusal naming /Users/user/.local/share/nice-dns/pi-hole-hardened, exit 1.
- After both: same start times; dig answers; DNS still .250. The next real `reinstall --local` reported `previous: 20261031T005604Z-e13e53e0b4d1`, so the refusals did not move the active generation.
Stack unchanged on both hosts. What the refusal does first (image tags, sysctl output): see findings.

Extra, MINT with nothing installed and sibling aside: `./nice-dns install --hardened` → same refusal, exit 1. Nothing published on PATH, no stack, resolver not touched. It did generate and leave a Pi-hole password under ~/.local/state/nice-dns/secrets (see findings).

## Findings

Blocking: none.

Material:
- M1. After `nice-dns uninstall` on mint, IPv6 stays off and the low-port setting stays. `sysctl` right after uninstall shows `net.ipv6.conf.all.disable_ipv6 = 1` and `net.ipv4.ip_unprivileged_port_start = 53`, although the uninstall printed `ipv6.method auto again` and removed 99-nice-dns-disable-ipv6.conf. `/etc/sysctl.d/99-podman-privileged-ports.conf` also stayed. Whether a reboot clears the IPv6 value was not tested (no reboots on these hosts).

Minor:
- m1. Refused `--hardened` runs do work before refusing, 8 to 18 s: they re-apply sysctls on mint, and they leave image tags. On mac two refusals left 14 tags (`pre-<timestamp>` and `<timestamp>`), and more accumulate with each try. On a clean mint, `./nice-dns install --hardened` generated and left a Pi-hole password. Stack, generation and DNS were untouched in every case.
- m2. Uninstall leftovers. mint: empty `~/.config/containers/systemd/pi-hole.container.d`, `~/.config/nice-dns`. mac: `/usr/local/sbin/nice-dns-fetch-bridges.sh` (root-owned, dated by the install), `~/.config/nice-dns`.
- m3. `ND_INST_READY_TRIES=6` shortened mint's restart wait to 55 s, but mac's restart took 300 s. On the mac the wait is the helper's, and it prints no `Waiting for the DNS chain` line, so the owner sees only `Restarting the stack...` for 5 minutes. The helper kept running after the command exited, and it finished when Tor came back.
- m4. A `--local` generation has no commit: `Generation ...-nogit0000000`, and on mint `nice-dns-health status` shows `Source commit: unknown`.
- m5. Root refusal wording differs from `install-mac.sh` on mac: `Run install-mac.sh as a regular user, not sudo.` against the command's `Please run nice-dns as a regular user, not with sudo.` It matches `install-deb.sh`.
- m6. Wording: `nice-dns: nice-dns is not installed; ...` repeats the name. `(is DNS down?)` also prints when DNS is up and only the branch is missing, though git's own line above it names the real cause.
