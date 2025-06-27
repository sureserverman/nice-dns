#!/usr/bin/env bash
#


set -euo pipefail

# Ensure we are not running as root. The script relies on rootless Podman and
# user-mode systemd. Running it via sudo will cause `systemctl --user` failures.
if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: Run this script as your regular user (without sudo)." >&2
  exit 1
fi

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

# First time on the machine – install a generic template
sudo podman-compose systemd -a create-unit
# This creates a podman-compose@.service template in ~/.config/systemd/user/
# It will be used to start the podman-compose service for each stack.
cd ..
# In your project directory:
podman-compose systemd -a register  # makes podman-compose@dns-stack.service

# Enable it for your user
systemctl --user enable --now podman-compose@dns-stack
