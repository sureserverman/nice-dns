#!/usr/bin/env bash
# setup-local-dns.sh — idempotent setup for macOS to redirect all DNS → 127.0.0.1:2053

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

# 3. Create PF anchor file
echo "🔧 Ensuring PF anchor ${ANCHOR_FILE} exists..."
cat > "$ANCHOR_FILE" <<EOF
rdr pass inet proto { tcp, udp } from any to 127.0.0.1 port 53 -> 127.0.0.1 port 2053
EOF
echo " • Wrote redirect rule to $ANCHOR_FILE"

echo "🎉 All done! Your system will now send every DNS query → 127.0.0.1:2053"
