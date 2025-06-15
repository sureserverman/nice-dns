#!/bin/bash
cp ./local-pf.sh /usr/local/sbin/local-pf.sh
cp ./org.localdns.pf.plist /Library/LaunchDaemons/org.localdns.pf.plist

chown root:wheel /Library/LaunchDaemons/org.localdns.pf.plist
chmod 644    /Library/LaunchDaemons/org.localdns.pf.plist

# Load it now and at every boot:
launchctl load /Library/LaunchDaemons/org.localdns.pf.plist


