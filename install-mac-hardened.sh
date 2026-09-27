#!/usr/bin/env bash
# Hardened-base sibling of install-mac.sh.
#
# Identical to install-mac.sh in every system-level concern (Homebrew, Apple
# `container` runtime bring-up, Rosetta install, network creation, LaunchAgent
# install). The ONLY differences are:
#
#   1. Before building pihole/, build pi-hole-hardened-base (under the
#      install's generation tag) from the sibling ../pi-hole-hardened repo (or
#      pull sureserver/pi-hole-hardened:latest from Docker Hub if no sibling).
#
#   2. Build pihole-hardened/Containerfile (FROM the hardened base) instead
#      of pihole/Containerfile (FROM pihole/pihole:latest).
#
#   3. Final image is still tagged pi-hole:latest at activation, so
#      mac/persist.sh and the LaunchAgent pick it up unchanged.
#
# The shared preparation, image builds and teardown live in lib/install.sh
# (pihole=hardened selects the recipe). Diff this against install-mac.sh to
# confirm the surface area.
#
# Usage: ./install-mac-hardened.sh [haproxy|socat|uninstall] [branch]
#   first arg defaults to 'haproxy'; 'uninstall' removes the stack and exits.
#   branch defaults to 'main' and is ignored for 'uninstall'.

set -euo pipefail
ACTION="${1:-haproxy}"
BRANCH="${2:-main}"

if [[ $EUID -eq 0 ]]; then
  echo "Run ${0##*/} as a regular user, not sudo." >&2
  exit 1
fi

case "$ACTION" in
  haproxy|socat|uninstall) ;;
  *) echo "Unknown arg '$ACTION'. Use 'haproxy', 'socat', or 'uninstall'." >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "$ACTION" != "uninstall" ]]; then
# -- Phase 0: compatibility gate --
# Same hash-pinned check as install-mac.sh; if check-runtime.sh changes,
# update the hash in BOTH installers (or call scripts/update-check-runtime-sha.sh).
CHECK_RUNTIME_SHA256='62f80b955124c6f379dc0b71bae81d813d8ba0b64a4c45f5bc1b41a85a075a4e'

if [[ -f "$HERE/mac/check-runtime.sh" ]]; then
  # shellcheck source=mac/check-runtime.sh
  source "$HERE/mac/check-runtime.sh" || exit 1
else
  _gate="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/sureserverman/nice-dns/${BRANCH}/mac/check-runtime.sh" -o "$_gate" \
    || { echo "failed to download compatibility gate" >&2; rm -f "$_gate"; exit 1; }
  _gate_sha="$(shasum -a 256 "$_gate" | awk '{print $1}')"
  if [[ "$_gate_sha" != "$CHECK_RUNTIME_SHA256" ]]; then
    echo "ERROR: compatibility gate SHA-256 mismatch." >&2
    echo "  expected: $CHECK_RUNTIME_SHA256" >&2
    echo "  got:      $_gate_sha" >&2
    echo "  branch:   $BRANCH" >&2
    rm -f "$_gate"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$_gate" || { rm -f "$_gate"; exit 1; }
  rm -f "$_gate"
fi
fi

# -- Stage the source, then load the shared installer library --
# Honor an in-tree checkout when present so a clone with the new
# pihole-hardened/ files is preserved instead of overwritten by a fresh
# clone of $BRANCH (which may not yet contain those files). Use the in-tree
# checkout this script sits in when there is one; the
# library copies it under $HOME for the build. Without one (`bash <(curl …)`)
# clone the requested branch under $HOME -- Apple Container's builder VM
# cannot read $TMPDIR (see lib/install.sh nd_install_macos_stage_tree).
ND_INST_CLEANUP="" ND_INST_WORK=""
trap '[ -z "${ND_INST_CLEANUP:-}" ] || rm -rf "${ND_INST_CLEANUP:?}"; [ -z "${ND_INST_WORK:-}" ] || rm -rf "${ND_INST_WORK:?}"' EXIT
if [[ -f "$HERE/lib/install.sh" && -f "$HERE/mac/persist.sh" && -f "$HERE/pihole-hardened/Containerfile" ]]; then
  ND_INST_SRC="$HERE" ND_INST_ORIGIN=checkout
else
  if ! command -v brew >/dev/null; then
    echo "Homebrew not found. Install from https://brew.sh and re-run." >&2
    exit 1
  fi
  brew list --formula git >/dev/null 2>&1 || brew install --formula git
  ND_INST_CLEANUP="$(mktemp -d "$HOME/.nice-dns-install.XXXXXXXX")"
  git clone -q -b "$BRANCH" https://github.com/sureserverman/nice-dns.git "$ND_INST_CLEANUP/nice-dns"
  ND_INST_SRC="$ND_INST_CLEANUP/nice-dns" ND_INST_ORIGIN=clone
fi
# shellcheck source=lib/install.sh
. "$ND_INST_SRC/lib/install.sh"
ND_INST_PLATFORM=macos

if [[ "$ACTION" == "uninstall" ]]; then
  nd_install_macos_uninstall
  echo "nice-dns uninstalled."
  exit 0
fi

VARIANT="$ACTION"

# -- Preparation (lib/install.sh) --
# Dependencies, the runtime, the build tree, the pulled images, bridges and
# the prepare manifest. Nothing here interrupts the running stack or touches
# host DNS; a failure exits and leaves it as it was.
nd_install_begin macos install-mac-hardened.sh hardened "$VARIANT" "$BRANCH"
# Refuses (exit 3) before any change when another owner took over host DNS.
nd_install_check_owned
# The reviewed image inputs (release/images.lock): shape, this host's
# platform, the proxy's interfaces and, with cosign, the signatures.
nd_install_read_lock
nd_install_verify_signatures
nd_install_save_previous
nd_install_macos_host_prereqs
nd_install_config_dir
nd_install_macos_stage_tree
nd_install_macos_prepare_images
nd_install_macos_bridges

# The interruption: record the owned DNS state, then stop, build and cut over;
# every service is pinned only once the new stack answers and the controller
# passed its self-check, and any failure rolls back (lib/install.sh,
# transaction notes).
nd_install_macos_activate
nd_install_finish

echo "All done. DNS is set to 172.31.240.250 (pi-hole, hardened base). Web UI: http://172.31.240.250"
