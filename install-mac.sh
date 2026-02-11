#!/usr/bin/env bash

# Fail on error and undefined variables
set -euo pipefail
BRANCH="${1:-main}"

# 0. Require SIP disabled (needed to stop mDNSResponder and free port 53)
if csrutil status | grep -q "enabled"; then
  cat <<EOF
System Integrity Protection (SIP) is enabled.
Pi-hole needs port 53, which is held by macOS mDNSResponder.
Disabling SIP lets the installer stop mDNSResponder to free that port.

To disable SIP:
  1. Shut down your Mac
  2. Boot into Recovery Mode (hold Power on Apple Silicon / Cmd-R on Intel)
  3. Open Terminal from the Utilities menu
  4. Run: csrutil disable
  5. Reboot and re-run this script
EOF
  exit 1
fi

# Temporarily point DNS to 1.1.1.1 so git clone works during install
networksetup -listallnetworkservices | sed '1d' | grep -v '^\*' | while read -r svc; do
  sudo networksetup -setdnsservers "$svc" 1.1.1.1 >/dev/null 2>&1 || true
done || true

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
if podman ps -a --format "{{.Names}}" | grep -Eq "^(tor-socat|tor-stunnel|tor-haproxy|unbound|pi-hole)$"; then
  echo "Stopping & removing old containers/images..."
  for name in pi-hole unbound tor-socat tor-stunnel tor-haproxy; do
    podman stop "$name" 2>/dev/null || true
    podman rm   "$name" 2>/dev/null || true
    podman image rm -f "$name" 2>/dev/null || true
  done
  podman network rm dnsnet 2>/dev/null || true
else
  echo "Installing prerequisites via Homebrew..."
  brew update
  brew install git podman podman-compose

fi

# Initialize & start the Podman VM (reuse existing if present)
if podman machine inspect podman-machine-default &>/dev/null; then
  echo "Podman machine already exists, reusing it..."
  podman machine start 2>/dev/null || true
else
  echo "Disabling Rosetta (not needed – all images have ARM builds)..."
  mkdir -p ~/.config/containers
  printf '[machine]\nrosetta=false\n' > ~/.config/containers/containers.conf
  echo "Initializing podman machine..."
  podman machine init
  podman machine start
  echo "Modifying podman machine..."
  podman machine ssh \
  'echo "net.ipv4.ip_unprivileged_port_start=53" \
    | sudo tee /etc/sysctl.d/99-podman-ports.conf && sudo sysctl --system'
  podman machine stop 2>/dev/null || true
  podman machine start
fi

# 3. Clone, network, and bring up the stack
echo "Cloning nice-dns repo..."
rm -rf nice-dns
git clone -b "$BRANCH" https://github.com/sureserverman/nice-dns.git
pushd nice-dns >/dev/null

echo "Creating podman network..."
podman network exists dnsnet || \
  podman network create \
    --driver bridge \
    --subnet 172.31.240.248/29 \
    --dns 1.1.1.1 \
    dnsnet

echo "Stopping mDNSResponder to free port 53..."
sudo launchctl bootout system/com.apple.mDNSResponder 2>/dev/null || true
sudo launchctl bootout system/com.apple.mDNSResponderHelper 2>/dev/null || true

echo "Launching containers with podman-compose..."
PODMAN_COMPOSE_PROVIDER=podman-compose BUILDAH_FORMAT=docker \
podman-compose --podman-run-args="--health-on-failure=restart" up -d

sudo ./mac/dns-mac.sh
./mac/mac-rules-persist.sh

popd >/dev/null
rm -rf nice-dns

echo "All done! ⚡"
