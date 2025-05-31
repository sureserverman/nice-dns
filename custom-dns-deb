#!/usr/bin/env bash
set -euo pipefail

# must run as root
if [[ $EUID -ne 0 ]]; then
  echo "⚠️  This script must be run as root." >&2
  exit 1
fi

### 1) Disable systemd-resolved so it stops managing /etc/resolv.conf
if systemctl is-active --quiet systemd-resolved; then
  systemctl stop systemd-resolved
fi
if systemctl is-enabled --quiet systemd-resolved; then
  systemctl disable systemd-resolved
fi

### 2) Ensure /etc/resolv.conf is a plain file pointing at 127.0.0.1
RESOLV=/etc/resolv.conf

# if it's a symlink (eg. to stub-resolv.conf), or missing, replace it
if [ -L "$RESOLV" ] || [ ! -f "$RESOLV" ]; then
  rm -f "$RESOLV"
  cat > "$RESOLV" <<EOF
nameserver 127.0.0.1
EOF
else
  # if it exists but isn't exactly our single-line, back it up & rewrite
  if ! grep -Fxq 'nameserver 127.0.0.1' "$RESOLV" \
     || grep -E '^\s*nameserver' "$RESOLV" | grep -v '127.0.0.1' >/dev/null; then
    cp "$RESOLV" "$RESOLV".bak."$(date +%Y%m%d_%H%M%S)"
    cat > "$RESOLV" <<EOF
nameserver 127.0.0.1
EOF
  fi
fi

### 3) Add iptables‐NAT rules to redirect all DNS to port 2053
# (glibc always sends to port 53; we catch it and forward to 2053)
for proto in udp tcp; do
  if ! iptables -t nat -C OUTPUT -p $proto --dport 53 -j REDIRECT --to-ports 2053 2>/dev/null; then
    iptables -t nat -A OUTPUT -p $proto --dport 53 -j REDIRECT --to-ports 2053
  fi
done

echo "✅ System-wide DNS now forced to 127.0.0.1:2053"
