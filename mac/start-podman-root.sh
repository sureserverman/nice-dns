#!/bin/bash
# Root-only helper for mac/start-podman.sh

set -euo pipefail

MULLVAD_PLIST="/Library/LaunchDaemons/net.mullvad.daemon.plist"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "This script must run as root." >&2
  exit 1
fi

set_local_dns() {
  networksetup -listallnetworkservices | sed '1d' | grep -v '^\*' | while read -r svc; do
    networksetup -setdnsservers "$svc" 127.0.0.1 2>/dev/null || true
  done
}

case "${1:-}" in
  pre)
    launchctl bootout system/net.mullvad.daemon 2>/dev/null || true
    sleep 2
    ;;
  post)
    if [[ -f "$MULLVAD_PLIST" ]]; then
      launchctl bootstrap system "$MULLVAD_PLIST" 2>/dev/null || true
    fi
    set_local_dns
    ;;
  *)
    echo "Usage: $0 {pre|post}" >&2
    exit 2
    ;;
esac
