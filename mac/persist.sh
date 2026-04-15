#!/bin/bash
# Installs the LaunchAgent and its privileged helper for the Apple `container`
# runtime, without the Podman-era pfctl/port-53 assets.
#
# Usage: ./mac/persist.sh [haproxy|socat]

set -euo pipefail

VARIANT="${1:-haproxy}"
case "$VARIANT" in haproxy|socat) ;; *)
  echo "variant must be 'haproxy' or 'socat'" >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"

# -- sudoers: allow the LaunchAgent to run only the pre/post helper --
tmp_sudoers="$(mktemp)"
trap 'rm -f "$tmp_sudoers"' EXIT
sed "s/__USERNAME__/$(whoami)/" "$HERE/start-container.sudoers" > "$tmp_sudoers"
sudo install -m 440 "$tmp_sudoers" /etc/sudoers.d/start-container
sudo visudo -cf /etc/sudoers.d/start-container

# -- install scripts (ensure /usr/local/sbin exists on fresh macOS) --
sudo install -d -m 755 /usr/local/sbin
sudo install -m 755 "$HERE/start-container.sh"      /usr/local/sbin/start-container.sh
sudo install -m 755 "$HERE/start-container-root.sh" /usr/local/sbin/start-container-root.sh

# -- LaunchAgent: start container system + stack at login --
AGENT_DST="$HOME/Library/LaunchAgents/org.nice-dns.start-container.plist"
launchctl unload "$AGENT_DST" 2>/dev/null || true
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s/__USERNAME__/$(whoami)/" -e "s/__VARIANT__/$VARIANT/" \
  "$HERE/org.nice-dns.start-container.plist" > "$AGENT_DST"
chmod 644 "$AGENT_DST"
launchctl load "$AGENT_DST"

echo "LaunchAgent installed (variant=$VARIANT)."
