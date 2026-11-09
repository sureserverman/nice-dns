# Close-out demo — 2026-11-05-gui-update-bridges-restart-sub-05-privileged-helper-plan

Environment: evaluated 2026-11-09 15:15–15:35 UTC from the laptop over ssh, as the plain user, without reading the source or the diff. The finished tree is `privileged-helper` at c2d6c66 (HEAD 69239bf only adds the gate record). It was unpacked by `git archive` to `~/nd-demo-c2d6c66` on each host and removed at the end. No install, reinstall, uninstall, update or restart was run. No root-owned file was changed. No container or service was touched.
- mint: Linux Mint 22.3, x86_64, podman 5.8.1, pkexec 124. Installed helper `/usr/libexec/nice-dns-helper` root:root 0755, `--version` 0.1.0, sha256 a28f5046…5e75. Polkit action `/usr/share/polkit-1/actions/org.nice-dns.policy` sha256 0a5f0ea7…740c, the same bytes as c2d6c66's `deb/org.nice-dns.policy`. Held root-ops `/usr/libexec/nice-dns/root-ops` sha256 9863b238…f977. Generation 20261109T064006Z-nogit0000000, `status --tsv` verdict OK, helper installed yes 0.1.0. `dig @127.0.0.1 cloudflare.com` answers.
- mac: macOS 27.2 (26B123), arm64, container CLI 1.7.1. Helper `/usr/local/libexec/nice-dns-helper` root:wheel `-rwsr-xr-x`, 0.1.0, sha256 e6e739b5…3f20. Owner file root:wheel 0644 holding `501`; user 501 is in group admin. Held root-ops sha256 f6d87bcc…152b. Same generation id, verdict OK, helper 0.1.0. `dig @172.31.240.250 cloudflare.com` answers.
- **Installed vs finished.** The helper binaries are the finished ones. Since the v1.0.0 tag (0358dea), the only change under `gui/helper` is THREAT-MODEL.md. Each installed binary equals its release asset and its lock row. The held root-ops is **not** the finished one. Both hosts hold adbf114's copy (deb 9863b238…, mac f6d87bcc…). c2d6c66 has deb 003bdd58… and mac 7f0d8bfd…, because 8074494 changed both root-ops files and lib/root.sh after the live run.
- Release v1.0.0 was read through the public API from mint, because the laptop's `gh` token is invalid (`gh release view` → 401). It is not a draft or a prerelease and was published 2026-11-08T22:39:31Z. It has six assets: three binaries, each with a `.sha256`.

## Stage 1 Outcome 1
> Works: `install-deb.sh` and `install-mac.sh` from a terminal prompt for sudo once (plus the keepalive) and run the same root steps as before, now as `sudo bash <tree>/<os>/root-ops <verb>` lines.

Verdict: not demonstrable within these limits

Evidence:
- This Outcome needs an install, which these limits forbid.
- The Stage 1 record (055450a, mint) shows the terminal sequence. My own read of mint's journal shows what happens since the helper exists.
- `journalctl _COMM=pkexec` holds no line with a TTY other than `unknown` since 2026-11-08. No terminal install has run on mint while the helper was installed.
- docs/release-inputs.md at c2d6c66 says that once the helper is installed, `lib/root.sh` runs each verb "through the helper instead of sudo, terminal or not".
- So on a host with the helper, a terminal install no longer uses only `sudo … root-ops` lines. See Finding 2.
- The sudo keepalive appears in every install on mint as `a password is required ; COMMAND=validate`. That includes the helper-path run at 06:28:19 today.

## Stage 1 Outcome 2
> A verb is unknown or an argument malformed → root-ops exits 2 with the verb named; the installer aborts before any change, or rolls back if one was made. (Owner decision: the installer's half is proven by a fixture test; demo root-ops' half.)

Verdict: holds (root-ops' half, as the owner scoped it; I did not run the fixture test)

Evidence: `sudo -n bash ~/nd-demo-c2d6c66/<os>/root-ops …` on both hosts:
```
(no verb)            root-ops: no verb given                         rc=2   (mint, mac)
frobnicate           root-ops: unknown verb 'frobnicate'             rc=2   (mint, mac)
--help / 'pin;id' / PIN / 'pin '   root-ops: unknown verb '<verb>'   rc=2   (mint, mac)
$'pin\nuninstall'    root-ops: unknown verb 'pin<newline>uninstall'  rc=2   (mint, mac)
mint: dns            verb 'dns' takes 1 argument(s), got 0           rc=2
mint: dns frob       verb 'dns': unknown helper verb 'frob'          rc=2
mint: pin extra      verb 'pin' takes 0 argument(s), got 1           rc=2
mint: host-setup --yes  verb 'host-setup' takes 0 argument(s), got 1 rc=2
mac:  agent          verb 'agent' takes 1 argument(s), got 0         rc=2
mac:  agent frob     verb 'agent': unknown helper verb 'frob'        rc=2
mac:  persist frob   verb 'persist': variant must be 'haproxy' or 'socat', not 'frob'  rc=2
mac:  version extra  verb 'version' takes 0 argument(s), got 1       rc=2
```
- Each verb from the helper's own table, given nine non-existent path arguments, gets root-ops' arity refusal (exit 2) on both hosts.
- Each verb from the other platform gets `unknown verb`. Examples: deb `host-prereqs`, `persist`, `agent`, `remove-helper`; mac `pin`, `dns`, `uninstall`, `host-setup`.
- Refusals with path arguments were not run under sudo: the session's safety classifier blocked `restore /etc/shadow -`. The helper's path refusals are in Stage 2 Outcome 2.

## Stage 1 Outcome 3
> root-ops is run as a non-root user → exit 1 `must run as root`.

Verdict: holds

Evidence: `bash ~/nd-demo-c2d6c66/<os>/root-ops <args>` as `user`, on both hosts, with no args, `pin`, `dns check`, `host-prereqs`, `agent post`, `frobnicate` and `version`. Each gave `root-ops: must run as root` rc=1. An unknown verb also gets 1, not 2, so the root check comes first.

## Stage 1 Outcome 4
> A rollback or uninstall → the same verbs in reverse, as today.

Verdict: not demonstrable within these limits (no uninstall or rollback allowed); the uninstall record seen in the journal matches

Evidence:
- mint's journal for today's live run (adbf114 tree), through the helper: `06:39:49 dns restore` → `06:40:00 uninstall`. The install it undoes ran `dns snapshot` → … → `pin-setup` → `pin` → `dns status` → `profiles-done`. That is the shape of the Stage 1 record.
- The mac's order could not be read. Its sudo and helper lines carry no verbs in the log.
- A rollback was not exercised by anyone live. It rests on the fixture lifecycle tests.

## Stage 2 Outcome 1
> Works: `nice-dns-helper pin` from a user process execs root-ops as root with only the three variables and a fixed PATH; polkit shows its prompt once (Linux); macOS prompts nothing.

Verdict: holds in the parts that could be observed. Not demonstrable within these limits: the four-variable environment and the polkit prompt shown once.

Evidence:
- **macOS prompts nothing, and execs root-ops as root.** Run over plain ssh with no tty, `/usr/local/libexec/nice-dns-helper --tree ~/.local/share/nice-dns/source version` printed `0.1.0` with rc=0 and no prompt.
- The same call with a scratch tree holding only `lib/install.sh` also printed `0.1.0` rc=0. So the answer comes from the root-held root-ops, which answers only as root (Stage 1 Outcome 3). The helper's own `--version` is a separate flag.
- Other callers are refused. `sudo -n` gives `the caller is root; the helper serves a non-root user` rc=1. `sudo -n -u nobody` gives `uid 4294967294 is not the user who installed the helper` rc=1.
- **macOS live run went through the helper.** The unified log for 06:20–06:50 UTC shows 41 separate `nice-dns-helper[pid]` processes doing their identity lookups: 11 at 06:27, 12 at 06:34, 3 at 06:35, 1 at 06:37, 2 at 06:39, 9 at 06:40 and 3 at 06:41.
- **Linux.** `pkaction --action-id org.nice-dns.helper --verbose` gives `auth_admin_keep` (any, inactive, active) and `exec.path -> /usr/libexec/nice-dns-helper`. The policy file equals c2d6c66's.
- mint's journal for today's live run lists pkexec `Executing command [USER=root] [TTY=unknown] … /usr/libexec/nice-dns-helper --tree <tree> <verb>`. The verbs, in order: `dns check`, `install-helper`, `version`, `host-packages`, `host-setup`, `host-linger`, `save-previous` ×9, `dns snapshot`, `interrupt-prereqs`, `pin-setup`, `pin`, `dns status`, `profiles-done`. Then the update into `~/.local/share/nice-dns/source`, then `dns restore` and `uninstall`, then the final install's `version` … `profiles-done`.
- In that window the only sudo root-ops lines are the final install's `dns check` and `install-helper` (06:40:06–07), after the uninstall had removed the helper. The live harness's own sudo lines `tee` and `rm` its temporary polkit rule, `90-nice-dns-test.rules`. polkitd reports 16 rules from 06:27:25 and 15 again from 06:43:10. `/etc/polkit-1/rules.d` now holds only `mintcommon-unattended-meta-update.rules`.
- Without pkexec, as the user: `nice-dns-helper --tree ~/no-such-tree pin` → `must run as root through pkexec (real and effective uid are not both 0)` rc=1. The same happens with `PKEXEC_UID=1000` set.
- Not observable: the environment root-ops receives. An eslogger exec trace on the mac lost its buffered events when stopped, so it caught nothing. No person was at mint's desktop to see a polkit dialog.

## Stage 2 Outcome 2
> A verb or argument outside the allow-list → exit 2, nothing executed, the verb named on stderr.

Verdict: holds

Evidence: as the user, with `T=~/nd-demo-c2d6c66` (the finished tree):
```
both:  (no args) no verb given rc=2; --tree T bogus|'pin;id'|PIN|'pin ' → unknown verb '<v>' rc=2;
       $'pin\nuninstall' → an argument contains a NUL or a newline rc=2; --tree -x → looks like an option rc=2;
       duplicate --tree → unknown verb '--tree' rc=2
mint:  pin (no --tree) → --tree is required rc=2; dns bogus → verb 'dns': unknown argument 'bogus' rc=2;
       dns → takes 1 argument(s), got 0; pin extra → takes 0, got 1; restore /etc/shadow - and
       save-previous /etc/passwd → '<path>' is not a file nice-dns owns rc=2; remove-helper, persist → unknown verb rc=2
mac:   pin, dns → unknown verb rc=2; persist bogus → unknown argument 'bogus'; agent → takes 1, got 0;
       agent 'post;id' → unknown argument 'post;id'; version extra → takes 0, got 1;
       restore /etc/sudoers -, save-previous /etc/master.passwd → not a file nice-dns owns rc=2
```
- **Path grammar on the mac.** These checks run after the setuid identity check has passed, so they are real refusals. Each was tried with verb `version` on scratch trees under the demo dir:
  - group-writable tree → `is writable by its group or by others`, rc=2;
  - symlinked tree → `is a symlink`, rc=2;
  - `lib/install.sh` a symlink → `holds no lib/install.sh`, rc=2;
  - empty tree → `holds no lib/install.sh`, rc=2;
  - trailing `/` → `has an empty, '.' or '..' component`, rc=2;
  - `/tmp`, `/etc`, `/Users/Shared` → `not under the caller's home`, rc=2;
  - the good copy → `0.1.0`, rc=0.
- **Verb tables.** `--list-verbs --platform deb` lists 19 verbs and `--platform mac` lists 9. Each matches the set and arity that the finished root-ops accepts (Stage 1 Outcome 2).
- **Nothing executed.** Both stacks stayed `verdict OK` and resolving. No pkexec line was logged for these calls.

## Stage 2 Outcome 3
> root-ops is missing, not root-owned, writable by others or a symlink → exit 3, nothing executed.

Verdict: not demonstrable within these limits

Evidence:
- Each case needs a root-owned file changed, which these limits forbid.
- What could be shown is that the chain is now in its trusted shape, so the helper does not refuse a good install:
  - mint: `/`, `/usr`, `/usr/libexec` and `/usr/libexec/nice-dns` are root:root 755 directories, and `root-ops` is a root:root 755 regular file.
  - mac: `/`, `/usr`, `/usr/local`, `/usr/local/libexec` and `…/nice-dns` are root:wheel 755. `root-ops` is a root:wheel 755 regular file with no flags (`ls -lO` shows `-`). The owner file is root:wheel 644.
- The setuid helper reaches the exec on the mac (`version` rc=0). So identity, path and chain checks all pass there.

## Stage 2 Outcome 4
> The polkit dialog is dismissed (126) or denied (127) → the installer prints `authorisation cancelled` / `not authorised` and aborts or rolls back as for any failed verb.

Verdict: not demonstrable within these limits

Evidence:
- It needs a person at mint's desktop and an install.
- Over ssh with no agent, `timeout 30 pkexec /usr/libexec/nice-dns-helper --tree ~/no-such-tree pin` → `Error creating textual authentication agent: … /dev/tty …` rc=127. `pkexec /usr/bin/true` gives the same.
- pkexec itself returns 127 for "no agent". docs/release-inputs.md says such a step "runs through sudo when sudo needs no password here, and otherwise fails the same way". The helper never returned 126 or 127 in my runs.

## Stage 2 Outcome 5
> The asset download fails or its sha256 differs → the install continues without the helper and says `GUI actions needing root will not work until a reinstall with network`; a mismatch is never installed.

Verdict: not demonstrable within these limits (the success path is verified)

Evidence:
- The failure paths need an install.
- On mint, into a `mktemp -d` directory, removed afterwards: `curl -fsSL` of all three assets and their `.sha256` files gave rc=0.
- The sha256 values were a28f5046…5e75 (linux-amd64), de2844b3…5083 (linux-arm64) and e6e739b5…3f20 (macos-arm64). Each equals its `.sha256` file, the API's `digest` field and the row in `release/assets.lock` at c2d6c66.
- `cmp` shows the release linux-amd64 binary is byte-identical to `/usr/libexec/nice-dns-helper`.
- The generation's staged copy on mint is a28f5046…. On the mac it is e6e739b5…, under `~/Library/Application Support/nice-dns-install/generations/…`. Both generations' `prepare.tsv` hold `helper 0.1.0`.
- A missing asset (`…-linux-riscv64`) → `curl: (22) … 404`, rc=22: the failure an install would meet.
- `release/bootstrap.tsv` declares this call as `exception assets`.

## Stage 2 Outcome 6
> The helper is installed but older than root-ops expects (`version` mismatch) → the installer re-installs it from the staged asset through root-ops `install-helper`.

Verdict: not demonstrable within these limits

Evidence:
- It needs an older helper in place and an install.
- The finished root-ops expects the installed helper: `sudo -n bash ~/nd-demo-c2d6c66/<os>/root-ops version` → `0.1.0` rc=0 on both hosts, and both helpers print `0.1.0`.
- A sibling trigger fired in today's live run: "the held root-ops is another tree's". mint's pkexec journal at 06:27:42 shows `nice-dns-helper --tree <new tree> install-helper <generation>/nice-dns-helper <tree>/deb/org.nice-dns.policy` running through the helper before any other step.
- After the uninstall, the "missing" trigger ran through sudo at 06:40:07.
- Both hosts' held root-ops now differ from c2d6c66's. The next install of the finished tree should take the same refresh path.

## Findings

1. **Material (evidence gap): the finished build was never run live.**
   - The helper-install receipt and the installed root-held root-ops come from adbf114.
   - 8074494 changed `deb/root-ops`, `mac/root-ops` (one EXIT handler replaces every verb's own trap; a step's exit 2 now leaves as 124) and `lib/root.sh` (the fallback). It touches every verb's exit path, the success path included.
   - So the gate criterion "the running artifact installs without a terminal on both platforms" is shown for adbf114, not for c2d6c66. No defect was seen.
2. **Material (unverified contradiction between Stage 1 and Stage 2 goals).**
   - Stage 1's Goal says "a terminal install behaves exactly as today". Stage 1 Outcome 1 says that means `sudo … root-ops` lines and one sudo prompt.
   - At c2d6c66, docs/release-inputs.md routes every verb through the helper "terminal or not" once the helper is installed. That is every install after the first on a host with pkexec.
   - No terminal install has ever run with the helper present: zero tty-bound pkexec lines on mint since 2026-11-08.
   - What a terminal user on a Linux desktop then sees is unshown: a sudo prompt plus a polkit dialog or textual prompt, or the sudo fallback after pkexec's 127. This needs one live terminal reinstall on mint, or an owner ruling that Stage 1 Outcome 1 covers only helper-less hosts.
3. **Minor: some refusals do not name the bad token.** The helper's NUL/newline refusal (`an argument contains a NUL or a newline`) names neither the verb nor the argument. THREAT-MODEL.md says a refusal about a verb or argument names it. root-ops prints the raw newline inside the quoted verb, so its message spans two lines. Both were also raised at the Stage 2 gate.
4. **Minor: one path message is wrong.** A tree whose `lib/install.sh` is a symlink is refused with `holds no lib/install.sh`. It should say it is a symlink, as the other symlink cases do.
5. **Minor: no tool lists its own verbs.** `nice-dns-helper --help` and `--list-verbs` (without `--platform`) give `unknown verb`, and root-ops prints no verb list. A reviewer must know `--list-verbs --platform deb|mac`.
6. **Minor: the macOS helper is only linker-signed.** The kernel logs `AMFI: '/usr/local/libexec/nice-dns-helper' has no CMS blob? … Unrecoverable CT signature issue, bailing out` on its first run after each install (06:27:38, 06:40:07). It runs, but it is a setuid-root binary with no Developer ID signature. Its integrity rests only on the lock's sha256 at download time.
7. **Minor: the sudo keepalive never succeeds on mint.** Every install's `sudo -n -v` logs `a password is required ; COMMAND=validate`, including the helper-path run (06:28:19). On a sudo-free GUI run it still probes sudo and logs an auth failure.
8. **Minor (local docs): the local CLAUDE.md lists old root-ops verbs.** It is not tracked in the repo. For deb it lists `host-prereqs`, `pin` and `nm-reload` but not `host-packages`, `host-setup`, `host-linger`, `pin-setup`, `podman-upgrade`, `crun-upgrade`, `version` or `install-helper`. For mac it omits `version`, `install-helper` and `remove-helper`.
9. **Note: two earlier Stage 2 findings are resolved.**
   - The Stage 2 gate's Material finding, macOS `status --tsv` merging `obs` rows, does not reproduce. Both the installed and the finished `nice-dns status --tsv` give 14 separate `obs` rows on the mac.
   - Its Minor 4 is answered: the mac's helper runs can be counted from the unified log (41 in the live run).
10. **Note (by design): the first install on a host still needs sudo.** The helper arrives with it (receipt scenario HI-INSTALL "with sudo available"). After an uninstall the next install also uses sudo for `dns check` and `install-helper`.
11. **Note: the decisions.** None is contradicted by what is observable.
    - DEC-020: mint's four stored Ethernet and Wi-Fi profiles read `ipv6.method disabled`, every device reads `disable_ipv6=1`, `/proc/cmdline` has no `ipv6.disable`, and the 91-nice-dns-ipv6 hooks are present.
    - DEC-018: `nice-dns-health drift` reports `Drift: none` rc=0, with no re-render.
    - DEC-019: not checkable, since Mullvad is not installed on mint.

**Against the master register Goal:** met as far as these limits allow.
- One allow-listed root-ops per platform. Its verb table equals the helper's in set and arity on both hosts, and it refuses unknown verbs (2) and non-root callers (1).
- The live run's install, update and uninstall went through `nice-dns-helper` with no terminal on both platforms. mint's journal holds pkexec verb lines only. The mac's log holds 41 helper processes.
- The helper on each host is the v1.0.0 release asset, verified against `release/assets.lock`.
- The gaps are evidence gaps, not observed defects: the finished commit was not the one run live (Finding 1), and the terminal behaviour on a host that has the helper is unshown (Finding 2). No Blocking finding.

## End state

Both hosts are as found: verdict OK, DNS answering, helper 0.1.0 installed. `~/nd-demo-c2d6c66` was removed on both. The eslogger observers I started on the mac were stopped (`pgrep eslogger` finds none). No background job is left running.
