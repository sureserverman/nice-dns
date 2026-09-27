#!/usr/bin/env bash
# Refresh release/images.lock (Sub-plan 4 Task 1.3; ARCH-05). A maintainer
# tool, never run by an installer. For each `image` row it asks Docker Hub for
# the current index digest of <repository>:<tag> and the platforms it
# provides, requires every platform the lock supports, and checks each signed
# image's signature with cosign on that digest. It reports the drift; with
# --write it records the new digests and platforms, touching no other row.
# Review the diff and commit it as the release input change (see
# docs/release-inputs.md).
#
# Usage: scripts/update-images-lock.sh [--lock FILE] [--write]
# Exit: 0 the lock matches the registry (or was rewritten); 1 drift found and
#       not written; 2 an error (registry, platform, signature, usage).
# Needs: curl, podman (manifest inspect), cosign, python3.

set -euo pipefail

LOCK="$(cd "$(dirname "$0")/.." && pwd)/release/images.lock"
WRITE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lock) LOCK="${2:?--lock needs a file}"; shift ;;
    --write) WRITE=1 ;;
    *) echo "usage: ${0##*/} [--lock FILE] [--write]" >&2; exit 2 ;;
  esac
  shift
done
[ -f "$LOCK" ] || { echo "no lock at $LOCK" >&2; exit 2; }
[ "$(head -n 1 "$LOCK")" = "$(printf 'schema\tnice-dns-images-lock/1')" ] || { echo "$LOCK is not a nice-dns-images-lock/1 lock" >&2; exit 2; }
command -v cosign >/dev/null 2>&1 || { echo "cosign is required to refresh the lock (signatures are checked on every signed image)" >&2; exit 2; }

TAB="$(printf '\t')"
SUPPORTED="$(awk -F '\t' '$1 == "supported" { print $2; exit }' "$LOCK")"
ISSUER="$(awk -F '\t' '$1 == "issuer" { print $2; exit }' "$LOCK")"

# registry_digest <repository without docker.io/> <tag>: the index digest.
registry_digest() {
  local tok
  tok="$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$1:pull" \
    | sed -E 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')" || return 1
  curl -fsSI -H "Authorization: Bearer $tok" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://registry-1.docker.io/v2/$1/manifests/$2" \
    | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" { print $2; exit }'
}

# registry_platforms <repository:tag>: the index's platforms, comma-separated.
registry_platforms() {
  podman manifest inspect "$1" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
out = []
for m in d.get("manifests", []):
    p = m.get("platform", {})
    if p.get("architecture") in (None, "unknown"):
        continue
    out.append(p["os"] + "/" + p["architecture"] + ("/" + p["variant"] if p.get("variant") else ""))
print(",".join(out))'
}

drift=0 errors=0
NEW="$(mktemp "${LOCK}.new.XXXXXX")"
trap 'rm -f "${NEW:?}"' EXIT
printf '%-15s %-34s %-12s %s\n' ROLE REFERENCE STATUS DIGEST
while IFS= read -r line; do
  case "$line" in
    image"$TAB"*) ;;
    *) printf '%s\n' "$line" >>"$NEW"; continue ;;
  esac
  IFS="$TAB" read -r _ role repo tag digest plats src ver signer <<EOF
$line
EOF
  short="${repo#docker.io/}"
  if ! now="$(registry_digest "$short" "$tag")" || [ -z "$now" ]; then
    echo "$role: cannot read the digest of $repo:$tag" >&2; errors=1
    printf '%s\n' "$line" >>"$NEW"; continue
  fi
  nplats="$(registry_platforms "$repo:$tag")" || nplats=""
  for p in $(printf '%s' "$SUPPORTED" | tr ',' ' '); do
    case ",$nplats," in *",$p,"*) ;; *) echo "$role: $repo:$tag has no $p build (supported: $SUPPORTED)" >&2; errors=1 ;; esac
  done
  if [ "$signer" != none ]; then
    if ! cosign verify --certificate-identity-regexp "^$(printf '%s' "$signer" | sed 's/\./\\./g')" \
          --certificate-oidc-issuer "$ISSUER" "$repo@$now" >/dev/null 2>&1; then
      echo "$role: the signature of $repo@$now does not verify for $signer" >&2; errors=1
    fi
  fi
  if [ "$now" = "$digest" ]; then
    printf '%-15s %-34s %-12s %s\n' "$role" "$repo:$tag" current "$digest"
    printf '%s\n' "$line" >>"$NEW"
  else
    drift=1
    printf '%-15s %-34s %-12s %s -> %s\n' "$role" "$repo:$tag" moved "$digest" "$now"
    printf 'image\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$role" "$repo" "$tag" "$now" "${nplats:-$plats}" "$src" "$ver" "$signer" >>"$NEW"
  fi
done <"$LOCK"

if [ "$errors" = 1 ]; then echo "not updating the lock: see the errors above" >&2; exit 2; fi
if [ "$drift" = 0 ]; then echo "The lock matches the registry."; exit 0; fi
if [ "$WRITE" = 1 ]; then
  cat "$NEW" >"$LOCK"
  echo "Wrote the new digests to $LOCK. Update each moved row's source and version by hand, requalify, review the diff and commit it."
  exit 0
fi
echo "Drift found; run with --write to record it."
exit 1
