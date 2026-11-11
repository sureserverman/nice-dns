# Release inputs

Every image a nice-dns install pulls or builds on is pinned in
`release/images.lock`. The installers never float to whatever a tag points at
today. The lock records, for each input:

- the repository, the tag it was taken from, and its multi-platform index digest;
- the platforms that digest provides;
- the source repository and commit (or `upstream`) and the version;
- the signer identity cosign must see, or `none`.

It also lists the interfaces each proxy image provides and the ones this tree
requires. It is data, parsed by `lib/install.sh` and
`scripts/update-images-lock.sh`, never sourced.

## What an install checks, before it interrupts anything

1. The lock parses: schema line, known row kinds, `sha256:` digests.
2. This host's platform is in the lock's `supported` set, and every image the
   install uses has a build for it.
3. The lock says the chosen proxy provides every interface this tree
   `requires`: fixed route listeners, the route probe, the acknowledged
   control restart and the bridges mode (`bridges-mode/1`: the proxy runs
   over obfs4 bridges with `TOR_BRIDGES=on`, the default, and Tor direct
   with `TOR_BRIDGES=off`; tor-haproxy v2.16 and tor-socat v2.12 onwards).
   This compares the lock's own reviewed rows; it catches a lock pinned to
   an image that was never qualified for this tree. What the
   pulled image actually does is proven later, before the resolver is pinned:
   the readiness wait needs Unbound to resolve over a route (the route
   listeners and probe), and the controller's self-check must pass.
4. With cosign installed, each signed image's signature is checked on its
   locked digest against the lock's signer and issuer. Without cosign the
   install says the signatures were not verified and records that; set
   `ND_INST_REQUIRE_SIGNATURES=1` to refuse instead. An upstream input
   nice-dns cannot name a signer for (`pihole/pihole`) is recorded as
   `unsigned`: no check is invented for it.

Each generation's manifest records the lock's sha256, every locked reference,
each signature result, the gravity sources (`pihole/adlists-default.txt`,
`pihole/custom-allowlist.txt`; the lists they name are downloaded at build
time, so their contents are not pinned) and, for the hardened flavour, the
base's source (`pihole-hardened/base@<this tree's commit>` and the
pi-hole-hardened commit it was copied from) and the local id of the base.

The hardened base is not published. Its four build inputs (`Dockerfile`,
`start.sh`, `post-install.sh`, `checksums/FTL-v6.6.1.sha256`) are copied into
this tree at `pihole-hardened/base/`, with an `UPSTREAM` file naming the
pi-hole-hardened commit they came from, and a hardened install builds the base
from them; no other checkout is needed. The Alpine image the Dockerfile
builds FROM is the `hardened-os` row of `release/images.lock`, pulled by
digest. `scripts/sync-hardened-base.sh <checkout>` refreshes the copy from a
reviewed pi-hole-hardened commit; review its diff like any lock change.

What the copied Dockerfile still fetches at build time, unpinned by any lock:
the pihole-FTL binary is checked against `checksums/FTL-v6.6.1.sha256`, but
FTL's default `pihole.toml` (wget from the FTL release), Pi-hole core and web
(`git clone --branch v6.4.2` / `v6.5`, a tag, not a commit) and the Alpine
packages (`apk upgrade`, `apk add`) are taken as the network serves them at
that moment. A build months apart can differ there.

The kept source (`~/.local/share/nice-dns/source`, what `nice-dns switch` and
`reinstall --local` install from) has no git. When an install keeps it, it
writes `.source-commit` beside it: the commit, whether the tree had local
changes, and a sha256 over the kept files. An install from the kept source
reads it as data and records that commit, marked as changed once the kept
files no longer hash as recorded. No other tree is trusted that way.

The previous generation's images stay on the host (lib/install.sh prunes only
older ones), so a failed install rolls back to what ran before.

## What an install runs as root

Every root-run step of an install, uninstall or rollback is a verb of one
entry point in the tree being installed: `deb/root-ops` on Linux and
`mac/root-ops` (Bash 3.2) on macOS. The installers call it as
`sudo bash <tree>/<os>/root-ops <verb> [args]` (`lib/root.sh`), so a
terminal install asks for sudo once and keeps the credential fresh with
`sudo -n -v` until it ends. root-ops checks the verb and its arguments
against its allow-list before anything runs: an unknown verb or argument
exits 2, a run as a user other than root exits 1. The rollback's root files
are root-ops' own fixed list; a rollback hands it the saved bytes on stdin
and never a path to open as root. As root it trusts nothing of the caller's
environment but `ND_ROOT_USER`, `ND_ROOT_HOME`, `ND_ROOT_TREE` and
`SUDO_USER`; that is defence in depth for sudo, which has already reset the
environment, and a caller that is not sudo must start root-ops with an empty
one. It acts only for an existing user other than root, whose home is the
one the password database (macOS: the directory service) names, on a tree
that user owns with no symlink in its path: a tree owned by root or by
another user is refused (exit 1). The podman and crun versions are read by
the installer, as the user, before root-ops upgrades either.

Once `nice-dns-helper` is installed (below) and is the version the tree's
root-ops expects, its root-held copy of root-ops is the tree's, and the tree
is one the helper takes (under `$HOME`, owned by the user, writable by no
group or other), `lib/root.sh` runs the verb through the helper instead of
sudo, terminal or not. The helper runs the root-held copy of root-ops
(`/usr/libexec/nice-dns/root-ops`, `/usr/local/libexec/nice-dns/root-ops`)
with only `PATH` and the three `ND_ROOT_*` variables. On Linux pkexec starts
it and polkit asks for an administrator's password once per install, then
once more each five minutes of a long one: one runner process makes every
pkexec call (OD-11). While that grant lasts, any process running as the
same user can submit to the runner too; that is accepted (OD-14), since such
a process can already change the tree root-ops runs. A dismissed dialog is
`authorisation cancelled` and the install aborts or rolls back as for any
failed step; a step the helper refuses, or pkexec cannot authorise
(`not authorised`; pkexec gives the same status when no polkit agent can
ask, as over ssh, and the message says so), runs through sudo when sudo
needs no password here, and otherwise fails the same way. While root steps
go through the helper, the sudo keepalive does not run. On macOS it is setuid root and asks nothing;
it serves only the admin user its owner file names (OD-10). Anything else
keeps to sudo. An update (`nice-dns update`, a branch reinstall) clones its
tree under `~/.cache/nice-dns`, so it goes through the helper too.

The root steps outside it: `install-deb.sh` and `install-deb-hardened.sh`
run `apt-get install git` before the source is cloned, when no tree exists
yet; and, outside any install, the macOS LaunchAgent runs its own root
helper through its passwordless rule (`mac/start-container.sh`,
`mac/start-container.sudoers`).

## Updating the lock

Run this on a maintainer machine with curl, podman, python3 and cosign:

```sh
scripts/update-images-lock.sh            # report: exit 0 current, 1 drift, 2 error
scripts/update-images-lock.sh --write    # record new digests and platforms
```

For each image the script:

- reads the current digest of `<repository>:<tag>` from Docker Hub;
- requires every `supported` platform;
- verifies each signed image's signature on the new digest.

It refuses to write if any of that fails. Only the moved rows change.

Then:

1. Set each moved row's `source` commit and `version` by hand, or move its
   `tag` to the new release first.
2. Requalify the new images: the transport and controller test groups, and a
   live install on each platform (`tests/run.sh plan installers`).
3. Update any `provides` row the new image changes.
4. Review the diff and commit it on its own, citing the qualification.

Refresh at least with every sibling image release, and whenever an upstream
base carries a security fix. Pinning must not freeze a vulnerable input
(ARCH-05).

## Release assets: the privileged helper

`nice-dns-helper` (`gui/helper`) is the one program a GUI, or any caller
without a terminal, runs to take a root step: through pkexec and polkit on
Linux, as a setuid program on macOS (`gui/helper/THREAT-MODEL.md`). It is
built by `.github/workflows/release.yml` on every `v*` tag, for
`linux/amd64`, `linux/arm64` and `macos/arm64`, and attached to that GitHub
release with a `.sha256` beside each binary.

`release/assets.lock` pins them: a `release <tag>` row (`none` before the
first release) and one `asset helper <platform> <arch> <url> <sha256>` row
each. During preparation an install:

1. checks the lock's grammar (a malformed lock fails the install before it
   changes anything);
2. downloads this host's asset with `curl -fsSL` into the new generation
   (declared in `release/bootstrap.tsv` as `assets`), trying a failed name
   lookup three times, 20 s apart (BL-044);
3. keeps the file only when its sha256 is the lock's, and installs it
   through root-ops `install-helper` when the installed helper is missing,
   another version, runs another root-ops or (macOS) serves another user.

An install whose helper is already the one this tree wants fetches nothing.
With no asset for the host, a failed download or a sha256 that differs, the
install goes on without the helper and says
`GUI actions needing root will not work until a reinstall with network`,
also in its last lines. A file that does not match is never installed. (The
fixture tests' `ND_INST_HELPER_STAGED`, which skips the download, is honoured
only with their root prefix `ND_INST_ROOT` set.)

To pin a new release, after the workflow's run succeeded:

```sh
scripts/update-assets-lock.sh                 # report: exit 0 current, 1 drift, 2 error
scripts/update-assets-lock.sh --write         # record the latest release (or --tag vX.Y.Z)
```

The script fetches each asset and its `.sha256`, refuses a binary whose bytes
are not its `.sha256`'s, and writes the `release` and `asset` rows only.
Commit the lock on its own. `ND_HELPER_VERSION` in `deb/root-ops` and
`mac/root-ops` must be the helper crate's version
(`tests/integration/installers-interaction.sh`
`t_root_ops_expects_the_crates_helper_version`).

## Release assets: the Linux GUI

`nice-dns-gui` (`gui/linux`, GTK 4.14 and libadwaita 1.5) is built by the
same workflow on the Ubuntu 24.04 runners, for `linux/amd64` and
`linux/arm64`, and packed with its launcher and icon into
`nice-dns-gui-linux-<arch>.tar.gz` (a `.sha256` beside each). The lock pins
each as `asset gui linux <arch> <url> <sha256>`; the script above records
them with the helpers.

On Linux an install downloads this host's tarball in preparation (declared
in `release/bootstrap.tsv` as `gui-asset`, the same three tries on a failed
lookup) and keeps it only when its sha256 is the lock's. Only a fully
successful install publishes it, for the user, each file by rename:
`~/.local/share/nice-dns/gui/` (the three files as shipped, beside the kept
source, with `published.tsv` saying where the rest went), `nice-dns-gui`
beside the `nice-dns` command, `$XDG_DATA_HOME/applications/nice-dns.desktop`
(by default under `~/.local/share`; its `Exec` names that program) and the
256 px icon in the user's hicolor theme. Without an asset, a download or a
matching sha256, the install goes on and says `GUI not installed; reinstall
with network to add it`, also in its last lines. The tarball must also hold
exactly those three plain files and the program must answer `--version` on
the host (GTK 4.14 and libadwaita 1.5); otherwise the install goes on and
says `GUI not installed` with the reason. An uninstall removes all of it,
wherever `published.tsv` says it went.

## Release assets: the macOS menu-bar app

`nice-dns.app` (`gui/mac`, Swift, macOS 13 or later) is built by the same
workflow on the `macos-15` runner: `swift test` and `KitCheck`, then
`make VERSION=<tag without v>` assembles the bundle and signs it ad hoc, and
`ditto -c -k --keepParent` zips it as `nice-dns-gui-macos-arm64.zip` (a
`.sha256` beside it). The lock pins it as `asset gui macos arm64 <url>
<sha256>`; the script above records it with the others (a release before
v1.2.0 has none).

On macOS an install downloads the zip in preparation (declared in
`release/bootstrap.tsv` as `gui-asset-macos`, the same three tries on a
failed lookup) and keeps it only when its sha256 is the lock's. Only a fully
successful install lands it, as the user and without root: `ditto -x -k`
beside the kept source, `xattr -dr com.apple.quarantine` over the whole
bundle, then a rename to `~/Applications/nice-dns.app`. The zip must hold
`nice-dns.app` alone, of plain files and directories only, and its program
must answer `--version`; otherwise, or without an asset, a download or a
matching sha256, the install goes on and says `GUI not installed` with the
reason, also in its last lines. A failed install keeps the earlier app; an
uninstall removes it.
