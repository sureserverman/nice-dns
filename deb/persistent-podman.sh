#!/usr/bin/env bash
#
# Setup Podman quadlets for nice-dns containers
# This script is now simplified for quadlet-based deployment

set -euo pipefail

# Ensure we are not running as root. The script relies on rootless Podman and
# user-mode systemd. Running it via sudo will cause `systemctl --user` failures.
if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: Run this script as your regular user (without sudo)." >&2
  exit 1
fi

echo
echo "▸ Running as user: $(whoami)"
echo "▸ Ensuring Podman v4+ is installed..."
if ! command -v podman &>/dev/null; then
  echo "Error: podman is not installed. Install podman v4.x or newer and re-run." >&2
  exit 1
fi

echo "▸ Podman version: $(podman --version)"
echo

# 1) Enable "linger" so your user's --user units survive reboot/logout
echo "1) Enabling linger for user $(whoami) (so systemd-user services survive reboot)..."
if ! loginctl show-user "$(whoami)" --no-pager | grep -q "Linger=yes"; then
  loginctl enable-linger "$(whoami)"
  echo "   ✓ Linger enabled."
else
  echo "   • Linger was already enabled."
fi
echo

# 2) Setup quadlet directory
QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
echo "2) Ensuring quadlet directory at: $QUADLET_DIR"
mkdir -p "$QUADLET_DIR"
echo "   ✓ Directory ready."
echo

# 3) Copy quadlet files
echo "3) Installing quadlet files..."
cp quadlets/*.network "$QUADLET_DIR/" 2>/dev/null || true
cp quadlets/*.container "$QUADLET_DIR/" 2>/dev/null || true
echo "   ✓ Quadlet files installed."
echo

# 4) Reload systemd daemon to pick up quadlets
echo "4) Reloading systemd user daemon..."
systemctl --user daemon-reload
echo "   ✓ Daemon reloaded."
echo

# 5) Enable services (quadlets auto-generate these)
echo "5) Enabling quadlet-based services..."
systemctl --user enable dnsnet-network.service 2>/dev/null || true
systemctl --user enable tor-socat.service 2>/dev/null || true
systemctl --user enable unbound.service 2>/dev/null || true
systemctl --user enable pi-hole.service 2>/dev/null || true
echo "   ✓ Services enabled for automatic start on boot."
echo

echo "Setup complete! Quadlet-based containers will start automatically on boot."
echo "Note: With quadlets, systemd manages the containers natively - no manual restart needed."