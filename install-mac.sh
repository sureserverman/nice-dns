#!/usr/bin/env bash
# Install nice-dns on macOS using Apple's `container` runtime (tor-haproxy
# variant). Intended for macOS 26+ on Apple silicon; falls back with a clear
# diagnostic on unsupported hosts.
#
# Usage: ./install-mac.sh [branch]   (default: main)

set -euo pipefail
BRANCH="${1:-main}"

if [[ $EUID -eq 0 ]]; then
  echo "Run install-mac.sh as a regular user, not sudo." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"

# -- Phase 0: compatibility gate --
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

# -- Homebrew + container + Rosetta + git --
if ! command -v brew >/dev/null; then
  cat >&2 <<EOF
Homebrew not found. Install from https://brew.sh and re-run.
EOF
  exit 1
fi

brew update
for pkg in git container; do
  brew list --formula "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done

# Apple container builder runs in a Rosetta VM; install non-interactively
# if absent. softwareupdate is a no-op when already installed.
if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  sudo softwareupdate --install-rosetta --agree-to-license
fi

# -- Bring up the runtime + default kernel --
CONTAINER_BIN="${CONTAINER_BIN:-/opt/homebrew/bin/container}"
# First-time start prompts [Y/n] for the kata kernel download; feed `yes` so
# the install is non-interactive. The subshell swallows the SIGPIPE that
# hits `yes` when `container` exits, which would otherwise trip pipefail.
{ yes 2>/dev/null || true; } | "$CONTAINER_BIN" system start >/dev/null

# -- Teardown any previous nice-dns state --
for c in pi-hole unbound tor-haproxy tor-socat; do
  "$CONTAINER_BIN" stop "$c" >/dev/null 2>&1 || true
  "$CONTAINER_BIN" rm   "$c" >/dev/null 2>&1 || true
done
"$CONTAINER_BIN" network rm dnsnet >/dev/null 2>&1 || true

# -- Fetch the repo at the requested branch --
# Place WORK under $HOME -- Apple Container's builder VM cannot read
# /var/folders/.../T/ (the macOS default $TMPDIR), so mktemp -d lands in a
# location the build context transfer can't see, yielding an empty context
# and "lstat /etc: no such file or directory" during ADD/COPY.
WORK="$(mktemp -d "$HOME/.nice-dns-install.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
git clone -q -b "$BRANCH" https://github.com/sureserverman/nice-dns.git "$WORK/nice-dns"
cd "$WORK/nice-dns"
HERE="$WORK/nice-dns"

# -- Build local images --
"$CONTAINER_BIN" builder start >/dev/null 2>&1 || true
"$CONTAINER_BIN" build -t unbound unbound/
"$CONTAINER_BIN" build -t pi-hole pihole/

# Builder VM isn't needed once images are built; reclaim ~2 GB RAM. It will
# auto-start again on the next `container build`.
"$CONTAINER_BIN" builder stop >/dev/null 2>&1 || true

# -- Create network and start containers in IP-allocation order --
"$CONTAINER_BIN" network create --subnet 172.31.240.248/29 dnsnet >/dev/null

"$CONTAINER_BIN" run -d --name pi-hole --network dnsnet \
  -c 1 -m 256M \
  -e TZ=Europe/London \
  -e DNS1=172.31.240.251 \
  -e DISABLE_GITHUB_UPDATES=true \
  pi-hole:latest >/dev/null

"$CONTAINER_BIN" run -d --name unbound --network dnsnet \
  -c 1 -m 256M \
  unbound:latest >/dev/null

"$CONTAINER_BIN" run -d --name tor-haproxy --network dnsnet \
  -c 1 -m 256M \
  docker.io/sureserver/tor-haproxy:latest >/dev/null

# -- Wait for the chain (Tor bootstrap) before flipping system DNS --
echo "Waiting for the DNS chain to come up (Tor bootstrap takes ~30-60s)..."
for i in $(seq 1 30); do
  if dig @172.31.240.250 +time=3 +tries=1 +short cloudflare.com 2>/dev/null \
      | grep -Eq '^[0-9.]+$'; then
    echo "Chain is resolving."
    break
  fi
  sleep 5
done

# -- Point the system at pi-hole and install the LaunchAgent --
sudo "$HERE/mac/dns-mac.sh"
"$HERE/mac/persist.sh" haproxy

echo "All done. DNS is set to 172.31.240.250 (pi-hole). Web UI: http://172.31.240.250"
