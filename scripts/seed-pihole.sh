#!/usr/bin/env bash
#
# Seed Pi-hole's adlist and denylist tables on first install. Idempotent:
# `pihole adlist add` is a no-op for URLs already present, and the script
# only runs `pihole -g` if it actually added new lists.
#
# Usage: seed-pihole.sh <runtime>
#   <runtime> = "podman" (Linux) | "container" (macOS Apple Container)
#
# Reads URLs from <repo>/pihole/adlists-default.txt and domains from
# <repo>/pihole/custom-allowlist.txt. The repo root is detected from
# the script's own directory (parent of scripts/).

set -euo pipefail

RUNTIME="${1:-podman}"
case "$RUNTIME" in
    podman|container) ;;
    *) echo "ERROR: unsupported runtime '$RUNTIME' (use 'podman' or 'container')" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADLISTS_FILE="$REPO_ROOT/pihole/adlists-default.txt"
DENYLIST_FILE="$REPO_ROOT/pihole/custom-allowlist.txt"

[[ -f "$ADLISTS_FILE" ]] || { echo "ERROR: $ADLISTS_FILE not found" >&2; exit 1; }
[[ -f "$DENYLIST_FILE" ]] || { echo "ERROR: $DENYLIST_FILE not found" >&2; exit 1; }

echo "▸ Waiting for Pi-hole container to be ready..."
for i in $(seq 1 60); do
    if "$RUNTIME" exec pi-hole pihole-FTL --version >/dev/null 2>&1; then
        echo "  Pi-hole responsive after $((i * 2))s"
        break
    fi
    if (( i == 60 )); then
        echo "ERROR: Pi-hole container did not become responsive in 120s" >&2
        exit 1
    fi
    sleep 2
done

# Strip blank lines and `#` comments; trim whitespace.
strip_comments() {
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//; s/[[:space:]]*$//' "$1"
}

added_any=0

echo "▸ Seeding adlists from $(basename "$ADLISTS_FILE")..."
while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    out="$("$RUNTIME" exec pi-hole pihole adlist add "$url" 2>&1 || true)"
    if grep -qiE 'added|inserted' <<<"$out"; then
        added_any=1
        printf '  + %s\n' "$url"
    else
        printf '  = %s (already present)\n' "$url"
    fi
done < <(strip_comments "$ADLISTS_FILE")

echo "▸ Seeding custom denylist from $(basename "$DENYLIST_FILE")..."
while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    out="$("$RUNTIME" exec pi-hole pihole allow add "$domain" 2>&1 || true)"
    if grep -qiE 'added|inserted' <<<"$out"; then
        added_any=1
        printf '  + %s\n' "$domain"
    else
        printf '  = %s (already present)\n' "$domain"
    fi
done < <(strip_comments "$DENYLIST_FILE")

if (( added_any == 1 )); then
    echo "▸ Building gravity (downloads blocklists, ~30-90s)..."
    "$RUNTIME" exec pi-hole pihole -g
    echo "✓ Pi-hole seeded — adlists downloaded and compiled."
else
    echo "✓ Pi-hole was already seeded; no gravity rebuild needed."
fi
