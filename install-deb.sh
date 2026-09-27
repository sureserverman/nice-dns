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

configure_nm_dns_lockdown() {
  if ! command -v nmcli >/dev/null 2>&1; then
    return 0
  fi
  if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
    return 0
  fi

  # Two pieces are sufficient to keep /etc/resolv.conf pinned at 127.0.0.1
  # under NetworkManager:
  #
  #   1. dns=none — tell NM to stop managing /etc/resolv.conf entirely.
  #      With this set, per-connection ipv4.dns / ipv4.ignore-auto-dns
  #      have no observable effect; NM never writes resolv.conf, so
  #      whatever custom-dns-deb wrote stays.
  #
  #   2. dispatcher hook — re-run custom-dns-deb on every NM state change,
  #      so if anything *else* on the system (cloud-init, dhclient, a
  #      package upgrade) ever rewrites resolv.conf, the next NM event
  #      pins it back. Cheap defense-in-depth.
  #
  # An earlier version of this function also iterated every active
  # connection to set ipv4.dns 127.0.0.1 and then re-upped them all. With
  # dns=none in effect those modifications had no observable behaviour —
  # and the re-up loop kicked libvirt bridges (virbr0 etc.) into a
  # deactivate→detach-ports→reactivate cycle that orphaned VM tap
  # interfaces (vnet0…). Removed.
  sudo mkdir -p /etc/NetworkManager/conf.d /etc/NetworkManager/dispatcher.d
  sudo tee /etc/NetworkManager/conf.d/90-nice-dns.conf >/dev/null <<'EOF'
[main]
dns=none
EOF
  sudo tee /etc/NetworkManager/dispatcher.d/90-nice-dns-pin >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -x /usr/bin/custom-dns-deb ]; then
  /usr/bin/custom-dns-deb
fi
EOF
  sudo chmod 755 /etc/NetworkManager/dispatcher.d/90-nice-dns-pin

  sudo systemctl reload NetworkManager 2>/dev/null || sudo systemctl restart NetworkManager
}

configure_ipv6_disable() {
  sudo tee /etc/sysctl.d/99-nice-dns-disable-ipv6.conf >/dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sudo sysctl --system >/dev/null

  # sysctl-only on purpose. The kernel cmdline flag ipv6.disable=1 (shipped by
  # earlier versions as a grub.d drop-in) removes AF_INET6 entirely, so any
  # software that creates an IPv6 socket fails with EAFNOSUPPORT (os error 97)
  # — observed bricking Mullvad's userspace WireGuard (gotatun binds ::), which
  # then fail-closes the whole machine at boot. The sysctl above gives the same
  # posture (no v6 addresses, no v6 traffic) while keeping sockets creatable.
  # Remove the legacy drop-in left by previous installs.
  if [ -f /etc/default/grub.d/99-nice-dns-ipv6.cfg ]; then
    sudo rm /etc/default/grub.d/99-nice-dns-ipv6.cfg
    if command -v update-grub >/dev/null 2>&1; then
      sudo update-grub
    fi
  fi
}

# -- Stage the source, then load the shared installer library --
# Work from an in-tree checkout if present; otherwise fetch a fresh clone
# into a scoped temp dir so we never touch any unrelated 'nice-dns/' the
# user happens to have in their cwd. The checkout is the tree this script
# sits in or, as before, the current directory. Without one (`bash <(curl …)`)
# the branch is cloned first and the library loaded from the clone.
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
  nd_install_linux_teardown uninstall
  echo "nice-dns uninstalled."
  exit 0
fi

VARIANT="$ACTION"

# -- Preparation (lib/install.sh) --
# Dependencies, images and the prepare manifest. Nothing here interrupts the
# running stack or touches host DNS; a failure exits and leaves it as it was.
nd_install_begin linux install-deb.sh standard "$VARIANT" "$BRANCH"
nd_install_linux_host_prereqs
nd_install_config_dir
nd_install_linux_prepare_images

# -- Interruption window: replace the running stack --
nd_install_linux_teardown reinstall
nd_install_linux_interrupt_prereqs
nd_install_linux_activate_images

cd "$ND_INST_TREE"
# Bridge selection is no longer done here. persistent-podman.sh installs the
# host-side bridge-eval "manage" service (fetch Moat + rdsys distributor,
# accumulate a persistent pool, test real obfs4 usability, write the
# *reachable* set to ~/.config/nice-dns/bridges.env) and runs it once before
# the stack starts.
./deb/persistent-podman.sh "$VARIANT"
# Note: pi-hole's gravity DB is built at IMAGE BUILD time (see pihole/Containerfile),
# so no post-start seed step is needed — pihole-FTL serves DNS immediately.

# Install and start custom-dns-deb.service
sudo cp deb/custom-dns-deb.service /etc/systemd/system/custom-dns-deb.service
sudo install -m 755 deb/custom-dns-deb /usr/bin/custom-dns-deb
sudo systemctl daemon-reload
sudo systemctl enable --now custom-dns-deb.service
sudo systemctl restart custom-dns-deb.service
configure_nm_dns_lockdown
configure_ipv6_disable
sudo /usr/bin/custom-dns-deb

nd_install_finish
cd - >/dev/null
