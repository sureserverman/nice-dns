#!/usr/bin/env bash
# Privileged pre/post helper for mac/start-container.sh.
#
# pre:  tear down Mullvad (if installed) so it doesn't fight the stack coming
#       up. No-op if Mullvad isn't present.
# post: pin macOS system DNS to the pi-hole container IP and re-bootstrap
#       Mullvad if we took it down.

set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

MULLVAD_PLIST=/Library/LaunchDaemons/net.mullvad.daemon.plist
PIHOLE_IP=172.31.240.250

set_local_dns() {
  networksetup -listallnetworkservices | sed '1d' | { grep -v '^\*' || true; } | while read -r svc; do
    networksetup -setdnsservers "$svc" "$PIHOLE_IP" 2>/dev/null || true
  done
}

case "${1:-}" in
  pre)
    if [[ -f "$MULLVAD_PLIST" ]]; then
      launchctl bootout system/net.mullvad.daemon 2>/dev/null || true
    fi
    ;;
  post)
    if [[ -f "$MULLVAD_PLIST" ]]; then
      launchctl bootstrap system "$MULLVAD_PLIST" 2>/dev/null || true
    fi
    set_local_dns
    ;;
  *)
    echo "usage: $0 {pre|post}" >&2
    exit 2
    ;;
esac
