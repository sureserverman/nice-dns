#!/bin/bash
launchctl unload ~/Library/LaunchAgents/org.startpodman.plist

# sudo launchctl bootout system/org.startpodman || true
# sudo launchctl unload /Library/LaunchDaemons/org.startpodman.plist || true
# sudo rm -f /Library/LaunchDaemons/org.startpodman.plist


sudo cp ./mac/start-podman.sh /usr/local/sbin/
cp ./mac/org.startpodman.plist ~/Library/LaunchAgents/

chmod 644    ~/Library/LaunchAgents/org.startpodman.plist

# Load it now and at every boot:
launchctl load ~/Library/LaunchAgents/org.startpodman.plist

sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off