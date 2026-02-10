#!/bin/bash
set -euo pipefail

launchctl unload ~/Library/LaunchAgents/org.startpodman.plist || true

# sudo launchctl bootout system/org.startpodman || true
# sudo launchctl unload /Library/LaunchDaemons/org.startpodman.plist || true
# sudo rm -f /Library/LaunchDaemons/org.startpodman.plist


sudo install -m 755 ./mac/start-podman.sh /usr/local/sbin/start-podman.sh
sed "s/__USERNAME__/$(whoami)/" ./mac/org.startpodman.plist > ~/Library/LaunchAgents/org.startpodman.plist
chmod 644 ~/Library/LaunchAgents/org.startpodman.plist

# Load it now and at every boot:
launchctl load ~/Library/LaunchAgents/org.startpodman.plist

# sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off
