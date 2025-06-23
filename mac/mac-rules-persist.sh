#!/bin/bash
sudo cp ./local-pf.sh /usr/local/sbin/
sudo cp ./start-podman.sh /usr/local/sbin/
sudo cp ./org.localdns.pf.plist /Library/LaunchDaemons/
sudo cp ./org.startpodman.plist /Library/LaunchDaemons/

sudo chmod 644    /Library/LaunchDaemons/org.startpodman.plist
sudo chmod 644    /Library/LaunchDaemons/org.localdns.pf.plist

# Load it now and at every boot:
sudo launchctl load /Library/LaunchDaemons/org.startpodman.plist
sudo launchctl load /Library/LaunchDaemons/org.localdns.pf.plist