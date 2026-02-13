#!/bin/bash
set -euo pipefail

# -- Sudoers: allow LaunchAgent to run only required root helper actions --
tmp_sudoers="$(mktemp)"
trap 'rm -f "$tmp_sudoers"' EXIT
sed "s/__USERNAME__/$(whoami)/" ./mac/start-podman.sudoers > "$tmp_sudoers"
sudo install -m 440 "$tmp_sudoers" /etc/sudoers.d/start-podman
sudo visudo -cf /etc/sudoers.d/start-podman

# -- LaunchDaemon: free port 53 at boot (runs as root) --
sudo launchctl bootout system/org.nice-dns.free-port53 2>/dev/null || true
sudo install -m 644 ./mac/org.nice-dns.free-port53.plist /Library/LaunchDaemons/org.nice-dns.free-port53.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/org.nice-dns.free-port53.plist

# -- LaunchAgent: start Podman VM + containers (runs as user) --
launchctl unload ~/Library/LaunchAgents/org.startpodman.plist 2>/dev/null || true
sudo install -m 755 ./mac/start-podman.sh /usr/local/sbin/start-podman.sh
sudo install -m 755 ./mac/start-podman-root.sh /usr/local/sbin/start-podman-root.sh
sed "s/__USERNAME__/$(whoami)/" ./mac/org.startpodman.plist > ~/Library/LaunchAgents/org.startpodman.plist
chmod 644 ~/Library/LaunchAgents/org.startpodman.plist
launchctl load ~/Library/LaunchAgents/org.startpodman.plist
