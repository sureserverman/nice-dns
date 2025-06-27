#!/usr/bin/env bash
#

set -euo pipefail

# Ensure we are not running as root. The script relies on rootless Podman and
# user-mode systemd. Running it via sudo will cause `systemctl --user` failures.
if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: Run this script as your regular user (without sudo)." >&2
  exit 1
fi
# ──────────── CONFIGURATION ────────────

# List the exact names of your existing containers:
CONTAINERS=(
  "tor-socat"
  "unbound"
  "pi-hole"
)

# Where to drop the generated service files:
USER_SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# ──────────── SCRIPT START ────────────

echo
echo "▸ Running as user: $(whoami)"
echo "▸ Ensuring Podman v4+ is installed..."
if ! command -v podman &>/dev/null; then
  echo "Error: podman is not installed. Install podman v4.x or newer and re-run." >&2
  exit 1
fi

echo "▸ Podman version: $(podman --version)"
echo

# 1) Enable “linger” so your user’s --user units survive reboot/logout
echo "1) Enabling linger for user $(whoami) (so systemd-user services survive reboot)..."
if ! loginctl show-user "$(whoami)" --no-pager | grep -q "Linger=yes"; then
  loginctl enable-linger "$(whoami)"
  echo "   ✓ Linger enabled."
else
  echo "   • Linger was already enabled."
fi
echo

# 2) Make sure the ~/.config/systemd/user directory exists
echo "2) Ensuring user-mode systemd directory at: $USER_SYSTEMD_DIR"
mkdir -p "$USER_SYSTEMD_DIR"
echo "   ✓ Directory ready."
echo

# 3) For each container, generate a systemd unit
echo "3) Generating systemd user units for each container..."
for cname in "${CONTAINERS[@]}"; do

  # The generated filename is exactly “container-<cname>.service”
  GENERATED="container-${cname}.service"

  systemctl --user disable --now "$GENERATED" &>/dev/null || true
  rm -f "$USER_SYSTEMD_DIR/$GENERATED" &>/dev/null || true
  echo "done."
done
echo

cp ./deb/persistent-containers.service "$USER_SYSTEMD_DIR/"
systemctl --user daemon-reload
echo "3) Enabling persistent containers service..."
systemctl --user enable persistent-containers.service
echo "   ✓ Service enabled to restart containers on login."