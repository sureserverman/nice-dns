#!/usr/bin/env bash

set -euo pipefail

# 1. Ensure Homebrew is installed
if ! command -v brew &>/dev/null; then
  cat <<EOF
Homebrew not found!  
Please install Homebrew first, e.g.:

  /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

After that re-run this script.
EOF
  exit 1
fi

# 2. Check for existing containers/images/networks
if podman ps -a --format "{{.Names}}" | grep -Eq "^(tor-socat|unbound|pi-hole)$"; then
  echo "Stopping & removing old containers/images..."
  for name in pi-hole unbound tor-socat; do
    podman stop "$name" 2>/dev/null || true
    podman rm   "$name" 2>/dev/null || true
  done
  podman image rm nice-dns-web-pi-hole:latest     2>/dev/null || true
  podman image rm nice-dns-web-unbound:latest     2>/dev/null || true
  podman image rm sureserver/tor-socat:latest     2>/dev/null || true
  podman network rm nice-dns-web_dnsnet           2>/dev/null || true
else
  echo "Installing prerequisites via Homebrew..."
  brew update
  brew install git podman podman-compose

  # Initialize & start the Podman VM
  if ! podman machine list --format "{{.Name}}" | grep -q '^default$'; then
    echo "Initializing podman machine..."
    podman machine init
  fi
  echo "Starting podman machine..."
  podman machine start
fi

# 3. Clone, network, and bring up the stack
echo "Cloning nice-dns repo..."
git clone https://github.com/sureserverman/nice-dns.git
pushd nice-dns >/dev/null

echo "Creating podman network..."
podman network exists dnsnet || \
  podman network create \
    --driver bridge \
    --subnet 172.31.240.248/29 \
    dnsnet

echo "Launching containers with podman-compose..."
PODMAN_COMPOSE_PROVIDER=podman-compose BUILDAH_FORMAT=docker \
podman compose --podman-run-args="--health-on-failure=restart" up -d

sudo ./mac/dns-mac.sh
sudo ./mac/mac-rules-persist.sh

popd >/dev/null
rm -rf nice-dns

echo "All done! ⚡"

