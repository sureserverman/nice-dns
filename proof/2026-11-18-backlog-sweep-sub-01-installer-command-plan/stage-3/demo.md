# Plan demo — 2026-11-18-backlog-sweep-sub-01-installer-command-plan

Environment: mint (Linux Mint 22.3, Podman), sweep-installer generation 20261118T225504Z-d769e954a98f, driven over `ssh mint` on 2026-11-18 23:01-23:09 UTC. The Mac runs `main` and was not touched. Nothing was run on the laptop except reading docs and the goal grep.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

# Stage 1

## Outcome 1
> Works: a GUI or helper download whose connect or name lookup fails is tried again, up to 3 times 20 s apart, and the app is installed
Verdict: not shown here
Evidence:
Needs a spare Linux host (or Mac) that may be installed on, where the GUI/helper download's connect or name lookup can be made to fail during the install. mint forbids install/reinstall/update and network cuts; the laptop forbids installers.


## Outcome 2
> Works: an image pull or the clone whose name lookup fails is tried again, up to 3 times, before the install gives up
Verdict: not shown here
Evidence:
Needs a spare host that may be installed on, where name lookup can be broken during the image pull and the clone. Not allowed on mint or the laptop.


## Outcome 3
> Works: after a successful install the state directory keeps the running generation, its rollback and the 5 newest others; older directories are gone
Verdict: holds
Evidence:
Seen on mint after the branch install of 2026-11-18 22:55-22:58 UTC (Task 3.5's install; I did not run it, installs are not allowed to me).
- `ssh mint 'cat ~/.local/state/nice-dns-install/current; ls ~/.local/state/nice-dns-install/generations'`:
  current = `20261118T225504Z-d769e954a98f`; 7 directories: 20261111T115431Z, 20261111T120943Z, 20261111T121538Z, 20261111T122007Z, 20261111T212625Z (all -f1cbc1b37037 / -d5ccea92b7ac), 20261111T213009Z-d5ccea92b7ac, 20261118T225504Z-d769e954a98f.
- The running generation's `prepare.tsv`: `previous 20261111T213009Z-d5ccea92b7ac` and `rollback 20261111T213009Z-d5ccea92b7ac available`; that directory is kept. The other 5 are the newest left after it.
- Before the install, the stage-3 premise recorded 191 directories on mint (2026-11-18). The generations directory's own entry is 16384 bytes, the size left by a directory that once held many entries. So older directories are gone.
- Limit: I saw only the state after the install. I cannot rule out that a newer failed generation was pruned instead of an older one.


## Outcome 4
> Works: the install prints `Bridges selected` only when a selection ran, and `kept the existing bridges` when it was skipped
Verdict: not shown here
Evidence:
Needs an install run on a host that may be installed on, once with a bridge selection and once with it skipped. Installs are not allowed on mint; the Mac runs `main`.


## Outcome 5
> Every download try fails → the install still finishes without the GUI, and its note names the address curl tried and how long the connect took
Verdict: not shown here
Evidence:
Needs a spare host that may be installed on, with every GUI download try made to fail (blocked address or name). Not allowed on mint or the laptop.


## Outcome 6
> The branch asked for does not exist → the message says the branch was not found and does not ask whether DNS is down
Verdict: not shown here
Evidence:
Needs a host where an installer may be run with a branch that does not exist (`install-deb.sh haproxy <no-such-branch>`). Installers are not allowed on mint or the laptop.


## Outcome 7
> Every pull try fails → the install stops in preparation with the registry name in the message; the running stack is untouched
Verdict: not shown here
Evidence:
Needs a spare host that may be installed on, with every registry pull made to fail while a stack runs. Not allowed on mint or the laptop.


# Stage 2

## Outcome 8
> Works: after an install that rolled back, a GUI action that needs root still runs through the helper, with no terminal
Verdict: not shown here
Evidence:
Needs a host where an install can be made to roll back, then a GUI action needing root run from the window (polkit dialog). Install/reinstall/update are not allowed on mint.


## Outcome 9
> Works: an uninstall gives the host's DNS back first and stops the stack after
Verdict: not shown here
Evidence:
Needs a host that may be uninstalled (a spare Linux box or VM on this branch). Uninstall is not allowed on mint; the Mac runs `main`.


## Outcome 10
> The DNS restore fails during an uninstall → the stack keeps running and answering, the message names the cause and says to run `nice-dns uninstall` again, exit status is not 0
Verdict: not shown here
Evidence:
Needs a host that may be uninstalled, with the host-DNS restore made to fail during the uninstall. Not allowed on mint.


## Outcome 11
> A full disk interrupts the first route seed → the next install says the route record is incomplete and seeds it again, and never treats the half-written file as the controller's
Verdict: not shown here
Evidence:
Needs a fresh host whose disk can be filled during the first route seed, then a second install. Not allowed on mint or the laptop.


# Stage 3

## Outcome 12
> Works: `bridges-mode.env` means the same to the installer, the status, the Linux unit and the macOS agent, also after a hand edit that left two lines; the last line wins everywhere
Verdict: holds (for the Linux readers: `status`, `bridges status`, the Linux unit); not shown here for the installer and the macOS agent
Evidence:
On mint, saved the file first (`cp -p` to /tmp; sha256 c3f84029...a7b, mode 644, 16 bytes, mtime 2026-11-10 19:02:21; content `TOR_BRIDGES=off`).
1. Hand edit, last line `on`: `printf 'TOR_BRIDGES=off\nTOR_BRIDGES=on\n' > ~/.config/nice-dns/bridges-mode.env`
   - `nice-dns status --tsv | grep ^bridges` -> `bridges	mode	on`
   - `nice-dns status` -> Bridges section `mode            on`
   - `nice-dns bridges status` -> `mode	on`, exit 0
2. Hand edit, last line `off`: `printf 'TOR_BRIDGES=on\nTOR_BRIDGES=off\n' > ...`
   - `nice-dns status --tsv` -> `bridges	mode	off`; `nice-dns bridges status` -> `mode	off`, exit 0
3. With that two-line file (first line `on`, last `off`), `nice-dns restart` (exit 0, 17 s):
   ```
   Restarting the stack...
   Waiting for the DNS chain to come up at 127.0.0.1 (Tor bootstrap takes 1-4 min)...
   Chain is resolving, and Unbound resolves over its authenticated route.
   nice-dns restarted; DNS is answering.
   ```
   - `systemctl --user show tor-socat.service -p EnvironmentFiles` -> `/home/user/.config/nice-dns/bridges-mode.env (ignore_errors=yes)`
   - `podman inspect tor-socat` (started 23:03:27) env -> `TOR_BRIDGES=off`
   - `podman logs --since 2m tor-socat` -> `tor-supervisor: bridges off: BRIDGE1..16 ignored` / `tor-supervisor: spawned tor pid=13 generation=1 direct (no bridges)`
   So the Linux unit took the last line, not the first.
4. Put the file back with `cp -p`: same sha256 c3f84029...a7b, mode 644, 16 bytes, mtime 2026-11-10 19:02:21, content `TOR_BRIDGES=off`. The effective mode was `off` during the restart and after, so the running proxy matches the restored file. DNS answered (104.16.133.229, 104.16.132.229).
Not shown here: the installer's reading (needs an install, not allowed on mint) and the macOS agent's (the Mac runs `main`; a Mac on this branch is needed).


## Outcome 13
> Works: after `nice-dns uninstall` no `bridges-mode.env` is left, so a later install starts with bridges on
Verdict: not shown here
Evidence:
Needs a host that may be uninstalled and then installed again. Not allowed on mint; the Mac runs `main`.


## Outcome 14
> Works: after `nice-dns restart` the controller's next pass does not restart the stack again inside its cooldown
Verdict: holds (seen with healthy passes; the cooldown was not put under load)
Evidence:
On mint, `nice-dns restart` at 1795043000 (23:03:20 UTC), exit 0, 17 s (output under Outcome 12).
- Journal (`~/.local/state/nice-dns/controller/recovery.tsv`), every row since then:
  `1795043007 nd-cli-1795043007-858088 stack manual nice-dns restart restarted the stack`, then only the route switch rows `route:cloudflare-exit requested / acknowledged / ready`. There is no restart row from the controller.
- `health.log` for the next four passes:
  `23:04:07 TICK active action=switch-route target=cloudflare-exit result=unchanged ... reason=fresh proxy (generation 6e64172f14a0f5b5); streaks restart ...`
  `23:05:06`, `23:06:09`, `23:07:08 TICK active action=no-op target=- result=none ... reason=route cloudflare-exit stays selected`
- At 23:07:44: pi-hole, unbound and tor-socat still had StartedAt 23:03:29 / 23:03:28 / 23:03:27 (the manual restart); `systemctl --user show` gave NRestarts=0 and ActiveEnterTimestamp 23:03:27-29 for all three; DNS answered; `status` gave `verdict OK`, `stale no`.
Limit: every pass after the restart was healthy, so the controller had no reason to restart. A defect would show the same. Showing the cooldown hold needs a chain still failing after the restart (beyond the 300 s grace), which needs a network or Tor cut on mint. That is not allowed.


## Outcome 15
> Works: a macOS restart that waits on a slow Tor prints a waiting line every 30 s
Verdict: not shown here
Evidence:
Needs a Mac running this branch (the Mac runs `main`) with a Tor bootstrap slow enough to wait 30 s or more, for example bridges on through slow obfs4.


## Outcome 16
> Works: mint, reinstalled from the branch, answers DNS and keeps at most 7 generation directories
Verdict: holds
Evidence:
- `ssh mint 'nice-dns status'`: `installed yes`, `generation 20261118T225504Z-d769e954a98f`, `source_commit d769e954a98f32e0c304c7bca7c0c5234db9f4ff`, `branch sweep-installer`, `variant socat`, controller `verdict OK`, every check and container healthy.
- `ls ~/.local/state/nice-dns-install/generations | wc -l`: 7 directories (listed under Outcome 3). There were 191 before the install (stage-3 premise).
- The gate command `ssh mint 'dig @127.0.0.1 +time=5 +tries=2 +short cloudflare.com | grep -Eq "^[0-9.]+$" && ~/.local/bin/nice-dns status --tsv | grep -q "^install<TAB>installed<TAB>yes"'` -> GATE-OK; dig answered 104.16.133.229 / 104.16.132.229, before and after my restart.


## Outcome 17
> Running an installer as root → the same message from `install-deb.sh`, `install-mac.sh` and `nice-dns`
Verdict: not shown here
Evidence:
Needs a host where `install-deb.sh`, `install-mac.sh` and `nice-dns install` may be run as root: a spare Linux box or VM and a Mac on this branch. Installers are not allowed on mint or the laptop; the Mac runs `main`.



# Plan goal

Goal check run from the repo: `for n in 020 028 044 055 061 063 064 067; do grep -rq "BL-$n" tests/integration tests/unit ...` -> all 8 found; `grep -n BL-051 /mnt/vault/Portfolio/containers/nice-dns/decisions.md` -> line 10 `Decided: 2026-11-18 (owner, on BL-051: "Accept and close (Recommended)")`, line 15 `the window stays and BL-051 is closed`. Passes.

# Findings

Blocking: none.

Material: none.

Minor:
- docs/cli-contract.md (`nice-dns bridges`) says "The bridges mode is one line" and "parsed for the `TOR_BRIDGES` line only". Its `bridges` row reads "`on` unless the bridges toggle wrote `TOR_BRIDGES=off`". Neither says what a hand-edited file with two lines means. The product (Outcome 12) takes the last line, so the contract should say so.

Residuals (not shown here): Outcomes 1, 2, 4-11, 13, 15, 17, plus the installer and macOS-agent readers of Outcome 12. They need a spare host that may be installed on and uninstalled, with network faults, or a Mac on this branch. Outcome 14 was seen only with healthy passes (does not tell a fixed build from a broken one). Outcome 3 was seen only after the install.

Left on mint: bridges-mode.env restored byte for byte, with the same mode and mtime (its ctime changed). The backup copy was removed. One `nice-dns restart` (allowed), 23:03:20 UTC. DNS answers; controller verdict OK.
