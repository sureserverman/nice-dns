#!/bin/bash
launchctl unload ~/Library/LaunchAgents/org.startpodman.plist

sudo cp ./mac/start-podman.sh /usr/local/sbin/
cp ./mac/org.startpodman.plist ~/Library/LaunchAgents/

chmod 644    ~/Library/LaunchAgents/org.startpodman.plist

# Load it now and at every boot:
launchctl load ~/Library/LaunchAgents/org.startpodman.plist