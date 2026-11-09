#!/usr/bin/env bash
# Refresh release/assets.lock (Sub-plan 5 Task 2.4). A maintainer tool, never
# run by an installer. For a nice-dns release (the latest, or --tag) it
# fetches each helper asset's .sha256 that .github/workflows/release.yml
# attached, downloads the asset itself and requires its sha256 to be that
# one, then compares the result with the lock. It reports the drift; with
# --write it records the release and the three asset rows, keeping the
# lock's comments. Review the diff and commit it as the release input change
# (docs/release-inputs.md).
#
# Usage: scripts/update-assets-lock.sh [--lock FILE] [--tag vX.Y.Z] [--write]
# Exit: 0 the lock matches the release (or was rewritten); 1 drift found and
#       not written; 2 an error (network, a hash that does not match, usage).
# Needs: curl, sha256sum or shasum.

set -euo pipefail

REPO=sureserverman/nice-dns
ASSETS="linux amd64
linux arm64
macos arm64"
LOCK="$(cd "$(dirname "$0")/.." && pwd)/release/assets.lock"
TAG="" WRITE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lock) LOCK="${2:?--lock needs a file}"; shift ;;
    --tag) TAG="${2:?--tag needs a tag}"; shift ;;
    --write) WRITE=1 ;;
    *) echo "usage: ${0##*/} [--lock FILE] [--tag vX.Y.Z] [--write]" >&2; exit 2 ;;
  esac
  shift
done
[ -f "$LOCK" ] || { echo "no lock at $LOCK" >&2; exit 2; }
[ "$(head -n 1 "$LOCK")" = "$(printf 'schema\tnice-dns-assets-lock/1')" ] || { echo "$LOCK is not a nice-dns-assets-lock/1 lock" >&2; exit 2; }

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

if [ -z "$TAG" ]; then
  TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)" \
    || { echo "cannot read the latest release of $REPO" >&2; exit 2; }
fi
case "$TAG" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "not a release tag: '$TAG'" >&2; exit 2 ;; esac
case "$TAG" in *[!v0-9.]*) echo "not a release tag: '$TAG'" >&2; exit 2 ;; esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
want="$(printf 'release\t%s' "$TAG")"
while read -r plat arch; do
  name="nice-dns-helper-$plat-$arch"
  url="https://github.com/$REPO/releases/download/$TAG/$name"
  curl -fsSL "$url.sha256" -o "$tmp/$name.sha256" || { echo "cannot fetch $url.sha256" >&2; exit 2; }
  sha="$(cut -d' ' -f1 "$tmp/$name.sha256")"
  case "$sha" in *[!0-9a-f]*|'') echo "$name.sha256 holds no sha256" >&2; exit 2 ;; esac
  [ "${#sha}" = 64 ] || { echo "$name.sha256 holds no sha256" >&2; exit 2; }
  curl -fsSL "$url" -o "$tmp/$name" || { echo "cannot fetch $url" >&2; exit 2; }
  [ "$(sha_of "$tmp/$name")" = "$sha" ] || { echo "$name's bytes do not match its .sha256" >&2; exit 2; }
  want="$want
$(printf 'asset\thelper\t%s\t%s\t%s\t%s' "$plat" "$arch" "$url" "$sha")"
done <<EOF
$ASSETS
EOF

have="$(awk -F '\t' '$1 == "release" || $1 == "asset"' "$LOCK")"
if [ "$have" = "$want" ]; then
  echo "release/assets.lock matches $TAG"
  exit 0
fi
echo "release/assets.lock drifts from $TAG:"
diff <(printf '%s\n' "$have") <(printf '%s\n' "$want") || true
[ "$WRITE" = 1 ] || exit 1
{ awk -F '\t' '$1 != "release" && $1 != "asset"' "$LOCK"; printf '%s\n' "$want"; } >"$tmp/lock"
cp "$tmp/lock" "$LOCK"
echo "wrote $LOCK"
