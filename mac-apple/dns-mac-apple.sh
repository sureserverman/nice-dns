#!/usr/bin/env bash
# Point every active macOS network service DNS at the pi-hole container.
#
# Apple container's custom bridge subnet is directly routable from the host,
# so the system queries pi-hole at its bridge IP — no loopback alias, no port
# forwarding. Pass a different IP as $1 if the subnet is ever re-homed.

set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

PIHOLE_IP="${1:-172.31.240.250}"

networksetup -listallnetworkservices \
  | sed '1d' | grep -v '^\*' \
  | while read -r svc; do
      echo " - $svc -> $PIHOLE_IP"
      networksetup -setdnsservers "$svc" "$PIHOLE_IP" >/dev/null
    done || true

# Leave pfctl in whatever state the user configured; unlike the Podman path,
# we don't need to disable it because port 53 is never bound on the host.
