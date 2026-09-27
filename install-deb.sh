#!/usr/bin/env bash
# Usage: install-deb.sh [haproxy|socat|uninstall] [branch]
#   first arg defaults to 'haproxy'; 'uninstall' removes the stack and exits.
#   branch defaults to 'main' and is ignored for 'uninstall'.

set -euo pipefail

ACTION="${1:-haproxy}"
BRANCH="${2:-main}"

# Runs as an unprivileged user; rootless Podman + user-mode systemd
# require this. sudo is used internally for the few privileged steps.
if [[ $EUID -eq 0 ]]; then
  echo "Please run ${0##*/} as a regular user, not with sudo." >&2
  exit 1
fi

case "$ACTION" in
  haproxy|socat|uninstall) ;;
  *) echo "Unknown arg '$ACTION'. Use 'haproxy', 'socat', or 'uninstall'." >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
ND_INST_CLEANUP=""
trap '[ -z "${ND_INST_CLEANUP:-}" ] || rm -rf "${ND_INST_CLEANUP:?}"' EXIT
if [[ -f "$HERE/lib/install.sh" && -d "$HERE/deb/quadlet" && -f "$HERE/deb/custom-dns-deb" ]]; then
  ND_INST_SRC="$HERE" ND_INST_ORIGIN=checkout
elif [[ -f lib/install.sh && -d deb/quadlet && -f deb/custom-dns-deb ]]; then
  ND_INST_SRC="$(pwd)" ND_INST_ORIGIN=checkout
else
  command -v git >/dev/null 2>&1 || sudo apt-get install -yq --no-install-recommends git
  ND_INST_CLEANUP="$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-install.XXXXXXXX")"
  git clone -b "$BRANCH" https://github.com/sureserverman/nice-dns.git "$ND_INST_CLEANUP/nice-dns"
  ND_INST_SRC="$ND_INST_CLEANUP/nice-dns" ND_INST_ORIGIN=clone
fi
# shellcheck source=lib/install.sh
. "$ND_INST_SRC/lib/install.sh"
ND_INST_PLATFORM=linux

if [[ "$ACTION" == "uninstall" ]]; then
  nd_install_linux_uninstall
  echo "nice-dns uninstalled."
  exit 0
fi

VARIANT="$ACTION"

# -- Preparation (lib/install.sh) --
# Dependencies, images and the prepare manifest. Nothing here interrupts the
# running stack or touches host DNS; a failure exits and leaves it as it was.
nd_install_begin linux install-deb.sh standard "$VARIANT" "$BRANCH"
# Refuses (exit 3) before any change when another owner took over host DNS.
nd_install_check_owned
# The reviewed image inputs (release/images.lock): shape, this host's
# platform, the proxy's interfaces and, with cosign, the signatures.
nd_install_read_lock
nd_install_verify_signatures
nd_install_linux_host_prereqs
# After the prerequisites (the macOS runtime is started there), before any pull.
nd_install_save_previous
nd_install_config_dir
nd_install_linux_prepare_images

# The interruption: record the owned DNS state, then cut over; the resolver is
# pinned only once the new stack answers and the controller passed its
# self-check, and any failure rolls back (lib/install.sh, transaction notes).
nd_install_linux_activate
nd_install_finish
