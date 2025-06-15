#!/bin/sh
# reload-localdns-pf.sh
/sbin/pfctl -a localdns -F rules
/sbin/pfctl -a localdns -f /etc/pf.anchors/localdns
/sbin/pfctl -E
