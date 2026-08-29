#!/usr/bin/env bash
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
sudo install -m 755 "$HERE/start-container.sh"            /usr/local/sbin/start-container.sh
sudo install -m 755 "$HERE/start-container-root.sh"       /usr/local/sbin/start-container-root.sh
# fetch-bridges.sh is invoked from start-container.sh at every LaunchAgent
# fire so the stack always uses the fastest bridges from the current network.
sudo install -m 755 "$HERE/../scripts/fetch-bridges.sh"   /usr/local/sbin/nice-dns-fetch-bridges.sh
# Host-side bridge selection. fetch-bridges.sh deliberately does not rank the
# pool it writes — a TCP probe cannot tell a working bridge from one that is
# TCP-open but PT-dead — and the proxy consumes bridges.env as-is, so without
# this every fetched bridge became a Bridge line, dead ones included. Linux has
# had the equivalent since deb/persistent-podman.sh grew its
# nice-dns-fetch-bridges.service unit.
sudo install -m 755 "$HERE/bridge-eval.sh"                /usr/local/sbin/nice-dns-bridge-eval.sh

# -- LaunchAgent: start container system + stack at login --
AGENT_DST="$HOME/Library/LaunchAgents/org.nice-dns.start-container.plist"
launchctl unload "$AGENT_DST" 2>/dev/null || true
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s/__USERNAME__/$(whoami)/" -e "s/__VARIANT__/$VARIANT/" \
  "$HERE/org.nice-dns.start-container.plist" > "$AGENT_DST"
chmod 644 "$AGENT_DST"
launchctl load "$AGENT_DST"

# -- LaunchAgent: refresh bridge selection out-of-band (login + daily) --
# Separate from the agent above on purpose. The usability probe takes ~150s;
# running it inside the proxy at startup was measured to push tor bootstrap
# from ~8s to ~87s, so it must not sit on the startup path.
EVAL_DST="$HOME/Library/LaunchAgents/org.nice-dns.bridge-eval.plist"
launchctl unload "$EVAL_DST" 2>/dev/null || true
sed -e "s/__USERNAME__/$(whoami)/g" -e "s/__VARIANT__/$VARIANT/" \
  "$HERE/org.nice-dns.bridge-eval.plist" > "$EVAL_DST"
chmod 644 "$EVAL_DST"
launchctl load "$EVAL_DST"

echo "LaunchAgents installed (variant=$VARIANT): start-container + bridge-eval."
