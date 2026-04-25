#!/usr/bin/env bash
#
# Recompute mac/check-runtime.sh's SHA-256 and embed it in install-mac.sh
# so the curl-piped install path can verify integrity before sourcing.
#
# Run this whenever you edit mac/check-runtime.sh, OR install it as a
# pre-commit hook:
#
#   ln -s ../../scripts/update-check-runtime-sha.sh .git/hooks/pre-commit
#
# The hook stages install-mac.sh after updating, so the fix-up is part of
# the same commit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE_FILE="$REPO_ROOT/mac/check-runtime.sh"
INSTALL_FILE="$REPO_ROOT/install-mac.sh"

[[ -f "$GATE_FILE" ]]    || { echo "ERROR: $GATE_FILE missing" >&2; exit 1; }
[[ -f "$INSTALL_FILE" ]] || { echo "ERROR: $INSTALL_FILE missing" >&2; exit 1; }

new_sha="$(sha256sum "$GATE_FILE" | awk '{print $1}')"
old_sha="$(grep -oE "CHECK_RUNTIME_SHA256='[a-f0-9]{64}'" "$INSTALL_FILE" \
            | head -1 | grep -oE '[a-f0-9]{64}')"

if [[ "$new_sha" == "$old_sha" ]]; then
    echo "✓ install-mac.sh already pinned to current check-runtime.sh ($new_sha)"
    exit 0
fi

# Cross-platform sed -i (BSD on macOS, GNU on Linux).
if sed --version >/dev/null 2>&1; then
    sed -i "s/^CHECK_RUNTIME_SHA256='[a-f0-9]\{64\}'/CHECK_RUNTIME_SHA256='${new_sha}'/" "$INSTALL_FILE"
else
    sed -i '' "s/^CHECK_RUNTIME_SHA256='[a-f0-9]\{64\}'/CHECK_RUNTIME_SHA256='${new_sha}'/" "$INSTALL_FILE"
fi

echo "✓ install-mac.sh: CHECK_RUNTIME_SHA256 updated"
echo "  was: $old_sha"
echo "  now: $new_sha"

# If running as a pre-commit hook, re-stage install-mac.sh.
if [[ -d "$REPO_ROOT/.git" ]] && [[ "${GIT_DIR:-}" != "" || "${0##*/}" == "pre-commit" ]]; then
    (cd "$REPO_ROOT" && git add install-mac.sh)
    echo "  install-mac.sh re-staged"
fi
