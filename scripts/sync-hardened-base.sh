#!/usr/bin/env bash
# Refresh pihole-hardened/base from a pi-hole-hardened checkout (OD-6). A
# maintainer tool, never run by an installer. The hardened Pi-hole base is not
# published, so nice-dns carries its build inputs and every hardened install
# builds it from them (lib/install.sh _nd_inst_hardened_base). This copies the
# files the checkout's Dockerfile uses (Dockerfile, start.sh, post-install.sh
# and the FTL checksums its FTL_VERSION names) from the checkout's HEAD
# commit, never its working tree, and records that commit in
# pihole-hardened/base/UPSTREAM. Review the diff and commit it. When the
# Dockerfile's FROM moved, refresh the hardened-os row of
# release/images.lock in the same commit (docs/release-inputs.md): an install
# refuses a base whose FROM the lock does not pin.
#
# Usage: scripts/sync-hardened-base.sh <pi-hole-hardened checkout>
# Exit: 0 copied; 1 the checkout cannot be used (no commit, uncommitted
#       changes, a file missing at HEAD); 2 usage.

set -euo pipefail

[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: ${0##*/} <pi-hole-hardened checkout>" >&2; exit 2; }
SRC="$1"
DST="$(cd "$(dirname "$0")/.." && pwd)/pihole-hardened/base"

c="$(git -C "$SRC" rev-parse --verify HEAD 2>/dev/null)" || { echo "$SRC is not a git checkout with a commit" >&2; exit 1; }
if [ -n "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]; then
  echo "$SRC has uncommitted changes; the copy is of a commit, so commit them and run again" >&2
  exit 1
fi
ftl="$(git -C "$SRC" show "$c:Dockerfile" 2>/dev/null | awk -F= '/^ARG[ \t]+FTL_VERSION=/ { print $2; exit }')"
case "$ftl" in ''|*[!A-Za-z0-9._-]*) echo "cannot read FTL_VERSION from the Dockerfile at $c" >&2; exit 1 ;; esac
FILES="Dockerfile start.sh post-install.sh checksums/FTL-$ftl.sha256"

mkdir -p "$(dirname "$DST")"
NEW="$(mktemp -d "$(dirname "$DST")/.base.XXXXXX")"
trap 'rm -rf "${NEW:?}"' EXIT
mkdir -p "$NEW/checksums"
for f in $FILES; do
  git -C "$SRC" show "$c:$f" >"$NEW/$f" 2>/dev/null || { echo "$SRC has no $f at $c" >&2; exit 1; }
done
chmod 644 "$NEW/Dockerfile" "$NEW/checksums/FTL-$ftl.sha256"
chmod 755 "$NEW/start.sh" "$NEW/post-install.sh"
repo="$(git -C "$SRC" remote get-url origin 2>/dev/null)" || repo=-
printf 'schema\tnice-dns-hardened-upstream/1\nrepository\t%s\ncommit\t%s\nfiles\t%s\n' "$repo" "$c" "$FILES" >"$NEW/UPSTREAM"
chmod 755 "$NEW" "$NEW/checksums"
chmod 644 "$NEW/UPSTREAM"
if [ -e "$DST" ]; then rm -rf "${DST:?}.old"; mv "$DST" "$DST.old"; fi
mv "$NEW" "$DST"
trap - EXIT
rm -rf "${DST:?}.old"
echo "Copied pi-hole-hardened $c into $DST. Review the diff and commit it."
