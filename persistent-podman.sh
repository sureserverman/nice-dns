#!/usr/bin/env bash
#
# setup-rootless-autostart.sh
#
# Purpose:
#   For Ubuntu 24.04 (rootless Podman v4.x, no Quadlets/Podlets available),
#   generate per-container systemd user units for three already-running
#   containers named "tor-socat", "unbound" and "pi-hole". This makes them
#   auto-start whenever you reboot or log back in.
#
# Usage:
#   1. Save this file somewhere in your home, e.g. ~/bin/setup-rootless-autostart.sh
#   2. Make it executable:  chmod +x ~/bin/setup-rootless-autostart.sh
#   3. Run it once as your regular user:  ~/bin/setup-rootless-autostart.sh
#
# Prerequisites:
#   - Podman v4.x or newer installed
#   - You already have three containers (tor-socat, unbound, pi-hole) created
#     and in the “Exited” or “Created” state (they must exist!)
#   - systemd-user is enabled on your system (it is by default on Ubuntu 24.04)
#
# What it does under the hood:
#   • loginctl enable-linger <user>         → keep your user’s systemd services running when you log out/reboot
#   • podman generate systemd --name X       → emit a container-<X>.service that does “podman start X”
#   • mv container-X.service ~/.config/systemd/user/
#   • systemctl --user daemon-reload         → pick up new user-mode services
#   • systemctl --user enable container-X   → ensure it runs on boot/login
#   • systemctl --user start  container-X   → start it right now
#
# After that, on every reboot, systemd-user will see container-X.service, run it,
# and podman will start your existing container named “X”.

set -euo pipefail

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
  echo -n "   • Checking for container '$cname'... "
  if ! podman container exists "$cname"; then
    echo "❌ (not found)"
    echo "     → ERROR: Container \"$cname\" does not exist. Create or rename your container and re-run."
    exit 1
  fi
  echo "found."

  # Use “podman generate systemd --name <cname> --files”
  # This creates a file named “container-<cname>.service” in the current working directory.
  echo -n "     Generating container-$cname.service... "
  podman generate systemd --name "$cname" --files &>/dev/null
  echo "done."

  # The generated filename is exactly “container-<cname>.service”
  GENERATED="container-${cname}.service"
  if [ ! -f "$GENERATED" ]; then
    echo "     ❌ ERROR: Expected \"$GENERATED\" file but it was not produced."
    exit 1
  fi

  # Move it under ~/.config/systemd/user/
  echo -n "     Moving $GENERATED → $USER_SYSTEMD_DIR/ ... "
  mv "$GENERATED" "$USER_SYSTEMD_DIR/"
  echo "done."
done
echo

# 4) Reload the user systemd daemon so it picks up new services
echo "4) Reloading systemd-user daemon..."
systemctl --user daemon-reload
echo "   ✓ Reload complete."
echo

# 5) Enable & start each service right now
echo "5) Enabling and starting each container-<name>.service..."
for cname in "${CONTAINERS[@]}"; do
  unit="container-${cname}.service"
  echo -n "   • Enabling $unit ... "
  systemctl --user enable "$unit" --now
  echo "done."
done
echo

# 6) Final status check
echo "6) Status of each container’s systemd unit (should be \"active (running)\"):"
for cname in "${CONTAINERS[@]}"; do
  unit="container-${cname}.service"
  echo
  echo "┌─ $unit ─────────────────────────────────────────────────────"
  systemctl --user status "$unit" --no-pager
  echo "└────────────────────────────────────────────────────────────"
done

echo
echo "6a) ‘podman ps’ shows which containers are up:"
podman ps
echo

echo "✅ All done! On the next reboot (or logout/login), systemd will automatically start:"
for cname in "${CONTAINERS[@]}"; do
  echo "   • $cname (via container-${cname}.service)"
done
echo

exit 0
