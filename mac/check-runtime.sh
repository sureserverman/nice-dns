#!/usr/bin/env bash
# Phase 0 compatibility gate for the Apple `container` runtime.
#
# Exits 0 if the host is eligible (arm64 Apple silicon, macOS 26+, `container`
# CLI present), non-zero otherwise. Prints a one-line reason on failure.
#
# Usage:
#   mac/check-runtime.sh             # exits 0/1 silently on success
#   source mac/check-runtime.sh      # sets NICE_DNS_READY=1|0

set -euo pipefail

fail() {
  echo "container runtime unavailable: $1" >&2
  return 1
}

arch="$(uname -m)"
[[ "$arch" == "arm64" ]] || fail "requires Apple silicon (arm64), got '$arch'" || return 1

ver="$(sw_vers -productVersion 2>/dev/null || echo 0.0)"
major="${ver%%.*}"
[[ "$major" =~ ^[0-9]+$ ]] || fail "cannot parse macOS version '$ver'" || return 1
(( major >= 26 )) || fail "requires macOS 26 or newer, got $ver" || return 1

# Prefer PATH resolution, fall back to brew's default location.
CONTAINER_BIN="$(command -v container 2>/dev/null || true)"
if [[ -z "$CONTAINER_BIN" && -x /opt/homebrew/bin/container ]]; then
  CONTAINER_BIN=/opt/homebrew/bin/container
fi
[[ -n "$CONTAINER_BIN" ]] || fail "container CLI not found (brew install container)" || return 1

export CONTAINER_BIN

if (return 0 2>/dev/null); then
  NICE_DNS_READY=1
  export NICE_DNS_READY
fi
