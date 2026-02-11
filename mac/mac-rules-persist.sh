#!/bin/bash
set -euo pipefail

launchctl unload ~/Library/LaunchAgents/org.startpodman.plist 2>/dev/null || true
sudo install -m 755 ./mac/start-podman.sh /usr/local/sbin/start-podman.sh
sed "s/__USERNAME__/$(whoami)/" ./mac/org.startpodman.plist > ~/Library/LaunchAgents/org.startpodman.plist
chmod 644 ~/Library/LaunchAgents/org.startpodman.plist
launchctl load ~/Library/LaunchAgents/org.startpodman.plist
