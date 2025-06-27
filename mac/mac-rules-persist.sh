#!/bin/bash
sudo cp ./mac/local-pf.sh /usr/local/sbin/
sudo cp ./mac/start-podman.sh /usr/local/sbin/
sudo cp ./mac/org.localdns.pf.plist /Library/LaunchDaemons/
sudo cp ./mac/org.startpodman.plist /Library/LaunchDaemons/

sudo chmod 644    /Library/LaunchDaemons/org.startpodman.plist
sudo chmod 644    /Library/LaunchDaemons/org.localdns.pf.plist

# Load it now and at every boot:
sudo launchctl load /Library/LaunchDaemons/org.startpodman.plist
sudo launchctl load /Library/LaunchDaemons/org.localdns.pf.plist