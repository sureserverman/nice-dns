#!/usr/bin/env bash
# setup-local-dns.sh — idempotent setup for macOS to use local DNS at 127.0.0.1

set -euo pipefail

ANCHOR_NAME="localdns"
ANCHOR_FILE="/etc/pf.anchors/${ANCHOR_NAME}"
PF_CONF="/etc/pf.conf"

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
    done


# 3. Remove any old PF redirect rule (if present)
if [ -f "$ANCHOR_FILE" ]; then
  rm -f "$ANCHOR_FILE"
  echo "🔧 Removed obsolete PF anchor $ANCHOR_FILE"
fi

if grep -q "anchor \"${ANCHOR_NAME}\"" "$PF_CONF"; then
  sed -i '' "/anchor \"${ANCHOR_NAME}\"/d" "$PF_CONF"
  echo "🔧 Cleaned anchor reference from $PF_CONF"
fi

pfctl -f "$PF_CONF" >/dev/null 2>&1 || true

echo "🎉 All done! Your system will now send every DNS query → 127.0.0.1:53"
