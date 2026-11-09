# Stage 2 demo — 2026-11-05-gui-update-bridges-restart-sub-05-privileged-helper-plan

Environment: evaluated 2026-11-08 23:40–23:50 UTC from the laptop over ssh (no change made to the laptop, either host's stack, or any root-owned file). Repo branch `privileged-helper` at 3169e06; the hosts run the tree the live run installed (receipt `helper-install/20261108T232540Z-1649ab09`, source f53214d, `source_commit unknown` / nogit generations), so 8578181 (helper-removal message wording) is not what is installed.
- mint: Linux Mint 22.3, x86_64, podman 5.8.1, pkexec 124. Helper `/usr/libexec/nice-dns-helper` root:root 0755, `--version` 0.1.0, sha256 a28f5046…5e75. Held root-ops `/usr/libexec/nice-dns/root-ops` root:root 0755, sha256 5d347df1…7aa (= tree's deb/root-ops). Generation 20261108T233506Z-nogit0000000. `status --tsv`: verdict OK, `helper installed yes`, `version 0.1.0`. DNS answers.
- mac: macOS 27.2 (26B123), arm64, container CLI 1.7.1. Helper `/usr/local/libexec/nice-dns-helper` root:wheel 4755, 0.1.0, sha256 e6e739b5…3f20. Held root-ops root:wheel 0755, sha256 80513519…7564 (= tree's mac/root-ops). Owner file holds `501` (user, in group admin). Generation 20261108T233507Z-nogit0000000. `status --tsv`: verdict OK, helper 0.1.0. DNS answers via 172.31.240.250.
- Release v1.0.0 (sureserverman/nice-dns): not draft, not prerelease, published 2026-11-08T22:39:31Z, six assets (three binaries + `.sha256`).

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: `nice-dns-helper pin` from a user process execs root-ops as root with only the three variables and a fixed PATH; polkit shows its prompt once (Linux); macOS prompts nothing.
Verdict: PASS (residuals: the polkit prompt-once and the exact four-variable environment were not observed live)
Evidence:
- Policy binds pkexec to the helper path (mint): `pkaction --action-id org.nice-dns.helper --verbose` → `implicit any/inactive/active: auth_admin_keep`, `annotation: org.freedesktop.policykit.exec.path -> /usr/libexec/nice-dns-helper`, rc=0.
- Helper refuses to run without pkexec (mint, as user): `nice-dns-helper --tree ~/.local/share/nice-dns/source pin` → `must run as root through pkexec (real and effective uid are not both 0)` rc=1; same with `env PKEXEC_UID=1000` → rc=1. As root via sudo without pkexec: `sudo -n nice-dns-helper --tree /home/user/no-such-tree pin` → `PKEXEC_UID is not set; run through pkexec` rc=1; `PKEXEC_UID=0` → `the helper serves a non-root user` rc=1; `PKEXEC_UID=+1000` → `'+1000' is not a decimal uid` rc=1. (Trees were nonexistent, so nothing could run.)
- It did exec root-ops as root in the live run (mint): `journalctl _COMM=pkexec` 23:25:40–23:39 shows `Executing command [USER=root] [TTY=unknown] ... [COMMAND=/usr/libexec/nice-dns-helper --tree <tree> pin]` ×3, plus every other verb of the install (host-packages, pin-setup, profiles-done, save-previous …, dns snapshot/status/check, uninstall, version). Receipt HI-REINSTALL (linux): `command_exit 0`, `sudo_root_ops 0`, `pkexec_helper_runs 18`, `resolves yes`. The only sudo root-ops in that window are the two at 23:35:06–07 (`dns check`, `install-helper`) of the HI-FINAL install after the helper had been uninstalled, as expected.
- macOS prompts nothing: run as user over plain ssh, `nice-dns-helper --tree /tmp version` → `--tree: '/tmp' is not under the caller's home '/Users/user'` rc=2, i.e. it passed the identity check (setuid, owner 501, admin) with no prompt and stopped at the path check. Receipt HI-REINSTALL (macos): `command_exit 0`, `sudo_root_ops 0`, `resolves yes`. Other callers refused: `sudo -n nice-dns-helper ...` → `the caller is root; the helper serves a non-root user` rc=1; `sudo -n -u nobody ...` → `uid 4294967294 is not the user who installed the helper` rc=1.
- Not demonstrable here: a person seeing the polkit dialog once (the receipt's `limit no-person-prompted`: a temporary polkit rule stood in; polkitd shows rules 15→16 at 23:25:51 and back to 15 at 23:38:29, and `/etc/polkit-1/rules.d` now holds no nice-dns rule). The environment root-ops receives (PATH + ND_ROOT_USER/HOME/TREE) is not observable after the fact; only the threat model states it.

## Outcome 2
> A verb or argument outside the allow-list → exit 2, nothing executed, the verb named on stderr.
Verdict: PASS
Evidence (as user; mint `H=/usr/libexec/nice-dns-helper`, mac `H=/usr/local/libexec/nice-dns-helper`, `T=~/.local/share/nice-dns/source`):
- mint `$H --tree $T bogus` → `nice-dns-helper: unknown verb 'bogus'` rc=2. `$H --tree $T dns bogus` → `verb 'dns': unknown argument 'bogus'` rc=2. `$H --tree $T dns` → `verb 'dns' takes 1 argument(s), got 0` rc=2. `$H --tree $T pin extra` → `verb 'pin' takes 0 argument(s), got 1` rc=2. `$H --tree $T restore /etc/shadow -` → `verb 'restore': '/etc/shadow' is not a file nice-dns owns` rc=2. `$H --tree $T remove-helper` → `unknown verb 'remove-helper'` rc=2 (not in the deb list). `'pin '` and `PIN` → `unknown verb` rc=2 (exact match). `$'pin\nuninstall'` → `an argument contains a NUL or a newline` rc=2. `$H pin` → `--tree is required` rc=2. `$H` → `no verb given` rc=2. Duplicate `--tree` → `unknown verb '--tree'` rc=2.
- mac: `$H --tree $T bogus` → `unknown verb 'bogus'` rc=2; `pin` → `unknown verb 'pin'` rc=2 (not a mac verb); `persist bogus` → `verb 'persist': unknown argument 'bogus'` rc=2; `agent` → `takes 1 argument(s), got 0` rc=2; `version extra` → `takes 0 argument(s), got 1` rc=2; `restore /etc/sudoers -` → `'/etc/sudoers' is not a file nice-dns owns` rc=2; newline in verb → rc=2; `--tree -x` → `looks like an option` rc=2; `--tree /Users/user/../user/x` → `has an empty, '.' or '..' component` rc=2.
- Nothing executed: every refusal came before any exec (on the mac the setuid helper had already passed identity, so these are real refusals, not identity failures); the pkexec journal on mint has no entry for them; both stacks stayed `verdict OK` and resolving afterwards.
- Allow-lists shown by `--list-verbs --platform deb|mac` (deb: 19 verbs incl. `version`, `install-helper`; mac: 9 incl. `remove-helper`).

## Outcome 3
> root-ops is missing, not root-owned, writable by others or a symlink → exit 3, nothing executed.
Verdict: not demonstrable here
Evidence:
- Every refusal path needs a root-owned file changed (missing, re-owned, made writable, swapped for a symlink), which I may not do. On Linux the check also runs only after pkexec authorisation, which I cannot give.
- What I could show: the chain is currently in the trusted shape on both hosts, so the helper is not refusing a good install. mint `stat`: `/`, `/usr`, `/usr/libexec`, `/usr/libexec/nice-dns` root:root 755 directories; `/usr/libexec/nice-dns/root-ops` root:root 755 regular file. mac: `/`, `/usr`, `/usr/local`, `/usr/local/libexec`, `/usr/local/libexec/nice-dns` root:wheel 0755; `root-ops` root:wheel 0755 regular file, no flags (`ls -lO` shows `-`); owner file root:wheel 0644. The held copies' sha256 equal the trees' (`5d347df1…` deb, `80513519…` mac) and the receipt's `held_root_ops_sha`.
- The exit code 3 and the order of the check (after argv, identity and path checks) are stated in `gui/helper/THREAT-MODEL.md` ("Order of refusals and exit codes"); I did not see them happen.

## Outcome 4
> The polkit dialog is dismissed (126) or denied (127) → the installer prints `authorisation cancelled` / `not authorised` and aborts or rolls back as for any failed verb.
Verdict: not demonstrable here
Evidence:
- Dismissing or denying a dialog needs a person at mint's desktop, and the installer path needs an install, which I may not run.
- What I could show: pkexec over ssh with no agent, with arguments the helper would refuse anyway, returns the "not authorised" code: `timeout 30 pkexec /usr/libexec/nice-dns-helper --tree /home/user/no-such-tree pin` → `Error creating textual authentication agent: Error opening current controlling terminal for the process ('/dev/tty'): No such device or address` rc=127 (same for `pkexec /usr/bin/true`).
- The helper itself never returned 126/127 in any of my runs (only 0, 1, 2).
- Static, from the installed tree on mint: `lib/root.sh:194: 126) echo "nice-dns: authorisation cancelled"`, `:195: 127) echo "nice-dns: not authorised"`. docs/release-inputs.md says the install then aborts or rolls back as for any failed step. That abort/rollback was not observed.

## Outcome 5
> The asset download fails or its sha256 differs → the install continues without the helper and says `GUI actions needing root will not work until a reinstall with network`; a mismatch is never installed.
Verdict: not demonstrable here (the success path, a verified asset, is demonstrated)
Evidence:
- The failure paths (download fails, sha256 differs) need an install run, which I may not do.
- The asset is verified on the success path. `gh release view v1.0.0`: six assets, `nice-dns-helper-{linux-amd64,linux-arm64,macos-arm64}` (512928, 554064, 480784 bytes) each with a `.sha256`. On mint, into a `mktemp -d` dir: `curl -fsSL` of all three binaries and `.sha256` files rc=0. `sha256sum`: a28f5046…5e75, de2844b3…5083, e6e739b5…3f20. These equal both the `.sha256` files and `release/assets.lock`'s rows. A non-existent asset (`…-linux-riscv64`) → `curl: (22) … 404` rc=22, the failure an install would meet.
- Installed bytes equal the lock: mint `/usr/libexec/nice-dns-helper` and the generation's staged `nice-dns-helper` both a28f5046…5e75; mac installed helper and staged copy both e6e739b5…3f20. Both generations' `prepare.tsv`: `helper 0.1.0`.
- Static: the message `GUI actions needing root will not work until a reinstall with network` is `ND_INST_HELPER_MISSING` in the installed `lib/install.sh:1474`. docs/release-inputs.md describes the fallback and "A file that does not match is never installed". I did not see it happen.

## Outcome 6
> The helper is installed but older than root-ops expects (`version` mismatch) → the installer re-installs it from the staged asset through root-ops `install-helper`.
Verdict: not demonstrable here
Evidence:
- Making a version mismatch needs an older helper in place and then an install, which I may not do.
- Current state matches what is expected: the helper `--version` is 0.1.0 on both hosts, and `status --tsv` shows `helper version 0.1.0`. HI-REINSTALL with the matching helper did not reinstall it through sudo (sudo_root_ops 0).
- The re-install mechanism was seen in its "missing" case, not the "older version" case. After HI-UNINSTALL removed the helper (`helper absent`, `policy absent`), the next install ran `sudo bash <tree>/deb/root-ops install-helper <generation>/nice-dns-helper <tree>/deb/org.nice-dns.policy` (mint sudo journal, 23:35:07). That put the staged asset (sha256 a28f5046…) at `/usr/libexec/nice-dns-helper`. The mismatch trigger is documented (docs/release-inputs.md: "when the installed helper is missing, another version, runs another root-ops or (macOS) serves another user") but was not exercised.

## Findings

1. **Material (outside this stage's Outcomes): on macOS `nice-dns status --tsv` merges the `obs` rows into one line.** All 15 `obs` records come out joined, and the `route` row is joined to them (`...tor-socatobs	container:pi-hole...`; `grep -n '^obs'` finds one line). The controller's `observations.tsv` on the mac has a correct `\n` after each record (od -c, 16 lines). So the loss happens in `status`. This breaks cli-contract.md (one `obs` row per observation, groups as separate rows) for any GUI reading the mac. Linux output is correct.
2. **Minor: some refusal messages are unclear.** (a) The NUL/newline refusal does not name the verb or the argument (`an argument contains a NUL or a newline`). The threat model says every refusal names one; it could print an escaped form. (b) `--tree` after the verb is counted as verb arguments: `pin --tree T` → `verb 'pin' takes 0 argument(s), got 2`, which does not tell the user that `--tree` must come first. (c) `--list-verbs` without `--platform` → `unknown verb '--list-verbs'`, and `--platform linux` is refused (it takes `deb`/`mac`).
3. **Minor: pkexec exit 127 also covers "no authentication agent".** Over ssh with no agent, pkexec returns 127. The installer would report this as `not authorised`, which misnames a session with no agent as a denial.
4. **Minor (receipt quality).** The Linux HI-REINSTALL `verb` rows list `save-previous`'s path arguments (`/etc/NetworkManager/...`) and `dns`'s sub-verbs (`check`, `snapshot`, `status`) as verbs. They omit `save-previous`, `dns` and `host-setup`. The macOS cell reports `pkexec_helper_runs 0` and `sudo_root_ops 0`, but nothing counts helper runs, so the receipt does not show that the mac went through the helper.
5. **Minor (housekeeping, outside scope).** Generation directories are never pruned: 139 on mint and 128 on the mac. Each now also holds a ~0.5 MB helper copy.
6. **Not a defect, stated for the record.** The test polkit rule the live run used is gone: polkitd went back to 15 rules at 23:38:29, and `/etc/polkit-1/rules.d` holds only `mintcommon-unattended-meta-update.rules`.

No Blocking finding. Outcomes 1 and 2 PASS; 3–6 not demonstrable here within the allowed actions; for 5 and 6 the success and "helper missing" paths were seen live.
