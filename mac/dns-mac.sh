#!/usr/bin/env bash
# setup-local-dns.sh — idempotent setup for macOS to use local DNS at 127.0.0.1

set -euo pipefail

# 1. Ensure running as root
if [[ $EUID -ne 0 ]]; then
  echo "⚠️  Please run as root: sudo $0" >&2
  exit 1
fi

# 2. Point all network services to 127.0.0.1
echo "🔧 Setting DNS server to 127.0.0.1 for every network service..."
networksetup -listallnetworkservices |\
   sed '1d' |\
   grep -v '^\*' |\
   while read -r SERVICE; do
      echo " • $SERVICE"
      networksetup -setdnsservers "$SERVICE" 127.0.0.1 >/dev/null
    done || true

pfctl -d || true

echo "🎉 All done! Your system will now send every DNS query → 127.0.0.1:53"
