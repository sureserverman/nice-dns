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

# Remove old manual .service files (from pre-quadlet workaround)
for svc in tor-haproxy tor-socat unbound pi-hole; do
  if [ -f "$USER_SYSTEMD_DIR/${svc}.service" ]; then
    systemctl --user disable "${svc}.service" 2>/dev/null || true
    systemctl --user stop "${svc}.service" 2>/dev/null || true
    rm -f "$USER_SYSTEMD_DIR/${svc}.service"
  fi
done
echo

# 3) Install quadlet files
echo "3) Installing quadlet files to $QUADLET_DIR ..."
mkdir -p "$QUADLET_DIR"

# Keep direct script runs variant-clean too. The full installer tears down first,
# but this helper can be used on its own.
for svc in tor-haproxy tor-socat; do
  systemctl --user disable --now "${svc}.service" 2>/dev/null || true
done
rm -f "$QUADLET_DIR/tor-haproxy.container" "$QUADLET_DIR/tor-socat.container"

cp "$SCRIPT_DIR/quadlet/nice-dns.network" "$QUADLET_DIR/"
cp "$SCRIPT_DIR/quadlet/nice-dns.pod" "$QUADLET_DIR/"
cp "$SCRIPT_DIR/quadlet/unbound.container" "$QUADLET_DIR/"
cp "$SCRIPT_DIR/quadlet/pi-hole.container" "$QUADLET_DIR/"
cp "$SCRIPT_DIR/quadlet/tor-${VARIANT}.container" "$QUADLET_DIR/"

# unbound.container ships with __VARIANT__ as a placeholder so its After=
# names only the Tor proxy variant actually installed. systemd warns about
# unknown unit names in After= on every daemon-reload otherwise.
sed -i "s/__VARIANT__/${VARIANT}/g" "$QUADLET_DIR/unbound.container"

echo "   ✓ Quadlet files installed."
echo

# 4) Reload and start services
echo "4) Reloading systemd and starting services..."

# Re-exec the user systemd manager *after* the quadlet files are in place. The
# top-level installer already runs daemon-reexec earlier, but if Podman was
# upgraded in the same run the user manager may still hold the old quadlet
# generator path in its cache. A reexec here is cheap and avoids the
# "Unit nice-dns-pod.service not found" mystery on fresh installs.
systemctl --user daemon-reexec
systemctl --user daemon-reload

# Sanity-check that the quadlet generator actually produced
# nice-dns-pod.service. If it didn't, restarting the unit fails with a
# cryptic "Unit ... not found" — surface the real reason instead.
QUADLET_BIN=""
for cand in /usr/libexec/podman/quadlet /usr/lib/podman/quadlet /usr/lib/systemd/user-generators/podman-user-generator; do
  if [ -x "$cand" ]; then
    QUADLET_BIN="$cand"
    break
  fi
done

GEN_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/systemd/generator"
if [ ! -e "$GEN_DIR/nice-dns-pod.service" ]; then
  echo "   ✗ daemon-reload did not generate nice-dns-pod.service." >&2
  echo "     podman version: $(podman --version 2>&1 || echo 'podman missing')" >&2
  echo "     quadlet binary: ${QUADLET_BIN:-NOT FOUND}" >&2
  echo "     quadlet dir   : $QUADLET_DIR" >&2
  echo "     generator dir : $GEN_DIR" >&2
  if [ -n "$QUADLET_BIN" ]; then
    echo "     --- quadlet -dryrun -user output (stderr) ---" >&2
    "$QUADLET_BIN" -dryrun -user 2>&1 | sed 's/^/     /' >&2 || true
    echo "     ----------------------------------------------" >&2
  fi
  echo "" >&2
  echo "   .pod quadlets require Podman >= 5.0. If podman --version above" >&2
  echo "   reports < 5.0, the sejug/podman PPA upgrade in install-deb.sh did" >&2
  echo "   not produce a candidate for your Ubuntu release/arch." >&2
  exit 1
fi

systemctl --user restart nice-dns-pod.service
echo "   ✓ Services started."
