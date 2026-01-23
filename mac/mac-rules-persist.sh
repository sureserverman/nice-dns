#!/bin/bash
set -euo pipefail

launchctl unload ~/Library/LaunchAgents/org.startpodman.plist || true

sudo install -m 755 ./mac/start-podman.sh /usr/local/sbin/start-podman.sh
install -m 644 ./mac/org.startpodman.plist ~/Library/LaunchAgents/org.startpodman.plist

# Load it now and at every boot:
launchctl load ~/Library/LaunchAgents/org.startpodman.plist

sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off
