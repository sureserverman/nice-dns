#!/usr/bin/env bash
#
# Install Podman quadlet files for nice-dns and start the containers.
# Usage: ./deb/persistent-podman.sh [haproxy|socat]   (default: haproxy)

set -euo pipefail

VARIANT="${1:-haproxy}"

# Ensure we are not running as root. The script relies on rootless Podman and
# user-mode systemd. Running it via sudo will cause `systemctl --user` failures.
if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: Run this script as your regular user (without sudo)." >&2
  exit 1
fi

if [[ "$VARIANT" != "haproxy" && "$VARIANT" != "socat" ]]; then
  echo "ERROR: Unknown variant '$VARIANT'. Use 'haproxy' or 'socat'." >&2
  exit 1
fi

# ──────────── CONFIGURATION ────────────

QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
USER_SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ──────────── SCRIPT START ────────────

echo
echo "▸ Running as user: $(whoami)"
echo "▸ Variant: $VARIANT"
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

# 2) Remove old persistent-containers.service if present
if [ -f "$USER_SYSTEMD_DIR/persistent-containers.service" ]; then
  echo "2) Removing old persistent-containers.service..."
  systemctl --user disable persistent-containers.service 2>/dev/null || true
  systemctl --user stop persistent-containers.service 2>/dev/null || true
  rm -f "$USER_SYSTEMD_DIR/persistent-containers.service"
  echo "   ✓ Old service removed."
else
  echo "2) No old persistent-containers.service found (OK)."
fi
echo

# 3) Install quadlet files
echo "3) Installing quadlet files to $QUADLET_DIR ..."
mkdir -p "$QUADLET_DIR"

cp "$SCRIPT_DIR/quadlet/nice-dns.network" "$QUADLET_DIR/"
cp "$SCRIPT_DIR/quadlet/unbound.container" "$QUADLET_DIR/"
cp "$SCRIPT_DIR/quadlet/pi-hole.container" "$QUADLET_DIR/"
cp "$SCRIPT_DIR/quadlet/tor-${VARIANT}.container" "$QUADLET_DIR/"

# Fix dependency ordering for socat variant
if [ "$VARIANT" = "socat" ]; then
  sed -i 's/After=tor-haproxy\.service/After=tor-socat.service/' \
    "$QUADLET_DIR/unbound.container"
fi

echo "   ✓ Quadlet files installed."
echo

# 4) Reload and start services
echo "4) Reloading systemd and starting services..."
systemctl --user daemon-reload
systemctl --user start "tor-${VARIANT}.service"
systemctl --user start unbound.service
systemctl --user start pi-hole.service
echo "   ✓ Services started."
