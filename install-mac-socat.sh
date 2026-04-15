#!/usr/bin/env bash
# Install nice-dns on macOS using Apple's `container` runtime (tor-socat
# variant). Mirrors install-mac.sh but pulls sureserver/tor-socat.
#
# Usage: ./install-mac-socat.sh [branch]   (default: main)

set -euo pipefail
BRANCH="${1:-main}"

if [[ $EUID -eq 0 ]]; then
  echo "Run install-mac-socat.sh as a regular user, not sudo." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"

# When invoked via `bash <(curl ...)` there is no local checkout yet, so fetch
# the gate script directly from the requested branch.
if [[ -f "$HERE/mac/check-runtime.sh" ]]; then
  # shellcheck source=mac/check-runtime.sh
  source "$HERE/mac/check-runtime.sh" || exit 1
else
  _gate="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/sureserverman/nice-dns/${BRANCH}/mac/check-runtime.sh" -o "$_gate" \
    || { echo "failed to download compatibility gate" >&2; rm -f "$_gate"; exit 1; }
  # shellcheck source=/dev/null
  source "$_gate" || { rm -f "$_gate"; exit 1; }
  rm -f "$_gate"
fi

if ! command -v brew >/dev/null; then
  echo "Homebrew not found. Install from https://brew.sh and re-run." >&2
  exit 1
fi

brew update
for pkg in git container; do
  brew list --formula "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done

if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  sudo softwareupdate --install-rosetta --agree-to-license
fi

CONTAINER_BIN="${CONTAINER_BIN:-/opt/homebrew/bin/container}"
yes | "$CONTAINER_BIN" system start >/dev/null

for c in pi-hole unbound tor-haproxy tor-socat; do
  "$CONTAINER_BIN" stop "$c" >/dev/null 2>&1 || true
  "$CONTAINER_BIN" rm   "$c" >/dev/null 2>&1 || true
done
"$CONTAINER_BIN" network rm dnsnet >/dev/null 2>&1 || true

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone -q -b "$BRANCH" https://github.com/sureserverman/nice-dns.git "$WORK/nice-dns"
cd "$WORK/nice-dns"
HERE="$WORK/nice-dns"

"$CONTAINER_BIN" builder start >/dev/null 2>&1 || true
"$CONTAINER_BIN" build -t unbound unbound/
"$CONTAINER_BIN" build -t pi-hole pihole/

"$CONTAINER_BIN" network create --subnet 172.31.240.248/29 dnsnet >/dev/null

"$CONTAINER_BIN" run -d --name pi-hole --network dnsnet \
  -e TZ=Europe/London \
  -e DNS1=172.31.240.251 \
  -e DISABLE_GITHUB_UPDATES=true \
  pi-hole:latest >/dev/null

"$CONTAINER_BIN" run -d --name unbound --network dnsnet unbound:latest >/dev/null

"$CONTAINER_BIN" run -d --name tor-socat --network dnsnet \
  docker.io/sureserver/tor-socat:latest >/dev/null

echo "Waiting for the DNS chain to come up (Tor bootstrap takes ~30-60s)..."
for i in $(seq 1 30); do
  if dig @172.31.240.250 +time=3 +tries=1 +short cloudflare.com 2>/dev/null \
      | grep -Eq '^[0-9.]+$'; then
    echo "Chain is resolving."
    break
  fi
  sleep 5
done

sudo "$HERE/mac/dns-mac.sh"
"$HERE/mac/persist.sh" socat

echo "All done. DNS is set to 172.31.240.250 (pi-hole). Web UI: http://172.31.240.250"
