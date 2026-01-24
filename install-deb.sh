#!/usr/bin/env bash

# This script is intended to be run as an unprivileged user. It uses sudo
# internally for the few commands that require escalation. Running the entire
# script with sudo will break the rootless Podman setup.
if [[ $EUID -eq 0 ]]; then
  echo "Please run install-deb.sh as a regular user, not with sudo." >&2
  exit 1
fi


# Install required software if not already installed
if ! dpkg -l | grep -qw podman; then
  echo "Installing required packages..."
  sudo apt-get update
  sudo apt-get install -yq git podman podman-compose
else
  echo "Required packages already installed."
fi

# Check if there are running containers from previous installation
if command -v podman > /dev/null 2>&1; then
  EXISTING_CONTAINERS=$(podman ps -a --format "{{.Names}}" 2>/dev/null | grep -E "tor-socat|unbound|pi-hole" || true)
  if [[ -n "$EXISTING_CONTAINERS" ]]; then
    echo "Found existing nice-dns containers. Stopping and removing..."

    # Temporarily set DNS to a public resolver
    echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null

    # Stop and remove only nice-dns related containers
    echo "$EXISTING_CONTAINERS" | while read -r container; do
      podman rm -f "$container" 2>/dev/null || true
    done

    # Remove nice-dns images
    podman image rm -f nice-dns-unbound nice-dns-pi-hole sureserver/tor-socat 2>/dev/null || true

    # Remove the network if it exists
    podman network rm dnsnet 2>/dev/null || true

    echo "Cleanup complete."
  else
    echo "No existing nice-dns containers found."
  fi
fi

# Configure Podman registries
# target config path (user-level)
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/containers/registries.conf"
DIR=$(dirname "$CONFIG")

# ensure directory exists
mkdir -p "$DIR"

# if file missing: create from scratch
if [[ ! -f "$CONFIG" ]]; then
  cat > "$CONFIG" <<'EOF'
# registries.conf for Podman

unqualified-search-registries = ["docker.io"]

[[registry]]
prefix = "docker.io"
location = "registry-1.docker.io"
EOF
  echo "Created new $CONFIG with Docker Hub settings."
fi

# helper to add or update unqualified-search-registries
if grep -q '^[[:space:]]*unqualified-search-registries' "$CONFIG"; then
  if ! grep -q '^[[:space:]]*unqualified-search-registries.*docker.io' "$CONFIG"; then
    sed -i 's|^[[:space:]]*unqualified-search-registries.*|unqualified-search-registries = ["docker.io"]|' "$CONFIG"
    echo "Updated unqualified-search-registries to include docker.io"
  else
    echo "unqualified-search-registries already includes docker.io"
  fi
else
  echo 'unqualified-search-registries = ["docker.io"]' >> "$CONFIG"
  echo "Appended unqualified-search-registries = [\"docker.io\"]"
fi

# helper to add registry block for docker.io
if grep -q '^[[:space:]]*prefix[[:space:]]*=[[:space:]]*"docker.io"' "$CONFIG"; then
  echo "Registry block for docker.io already present"
else
  cat >> "$CONFIG" <<'EOF'

[[registry]]
prefix = "docker.io"
location = "registry-1.docker.io"
EOF
  echo "Appended [[registry]] block for docker.io"
fi

echo "Done updating $CONFIG."


# Configure sysctl for unprivileged port binding
SYSCTL_CONF="/etc/sysctl.d/99-podman-privileged-ports.conf"
if [[ ! -f "$SYSCTL_CONF" ]] || ! grep -q "net.ipv4.ip_unprivileged_port_start = 53" "$SYSCTL_CONF"; then
  echo "Configuring unprivileged port binding..."
  echo 'net.ipv4.ip_unprivileged_port_start = 53' | sudo tee "$SYSCTL_CONF" > /dev/null
  sudo sysctl --system > /dev/null
  echo "Unprivileged port binding configured."
else
  echo "Unprivileged port binding already configured."
fi

CONFIG="/etc/NetworkManager/NetworkManager.conf"

# Check for an uncommented 'dns=dnsmasq' line
if grep -Eq '^[[:space:]]*dns[[:space:]]*=[[:space:]]*dnsmasq' "$CONFIG"; then
  echo "Found dns=dnsmasq in $CONFIG – disabling it..."

  # Comment out the line
  sudo sed -i -E 's|^[[:space:]]*dns[[:space:]]*=[[:space:]]*dnsmasq|#&|' "$CONFIG"
  echo "Line commented out."

  # Restart NetworkManager
  echo "Restarting NetworkManager..."
  sudo systemctl restart NetworkManager
  echo "Done. dnsmasq is now disabled in NetworkManager."
fi

# Add UID/GID mappings for current user if missing
if ! grep -q "^$USER:100000:65536" /etc/subuid 2>/dev/null; then
  sudo usermod --add-subuids 100000-165535 $USER
fi
if ! grep -q "^$USER:100000:65536" /etc/subgid 2>/dev/null; then
  sudo usermod --add-subgids 100000-165535 $USER
fi

# Enable cgroups v2 delegation for systemd services
DELEGATE_CONF="/etc/systemd/system/user@.service.d/delegate.conf"

if [[ ! -f "$DELEGATE_CONF" ]] || ! grep -q "Delegate=cpu cpuset io memory pids" "$DELEGATE_CONF"; then
  echo "Configuring cgroups v2 delegation..."
  sudo mkdir -p /etc/systemd/system/user@.service.d
  sudo tee "$DELEGATE_CONF" << EOF
[Service]
Delegate=cpu cpuset io memory pids
EOF
  sudo systemctl daemon-reload
else
  echo "cgroups v2 delegation already configured."
fi

# Enable user lingering for service persistence
sudo loginctl enable-linger $USER

# Get nice-dns repository
REPO_DIR="$HOME/nice-dns-install"
if [[ -d "$REPO_DIR" ]]; then
  echo "Repository directory exists, updating..."
  cd "$REPO_DIR"
  git fetch origin
  git reset --hard origin/$(git remote show origin | grep 'HEAD branch' | cut -d' ' -f5)
else
  echo "Cloning repository..."
  git clone https://github.com/sureserverman/nice-dns.git "$REPO_DIR"
  cd "$REPO_DIR"
fi

# Build the images
echo "Building container images..."
echo "  Building nice-dns-unbound..."
podman build -t nice-dns-unbound:latest unbound/
echo "  Building nice-dns-pi-hole..."
podman build -t nice-dns-pi-hole:latest pihole/

# Pull the tor-socat image
echo "Pulling tor-socat image..."
podman pull docker.io/sureserver/tor-socat:latest

# Setup quadlet directory
QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
mkdir -p "$QUADLET_DIR"

# Copy quadlet files
echo "Installing quadlet files..."
cp quadlets/*.network "$QUADLET_DIR/"
cp quadlets/*.container "$QUADLET_DIR/"

# Reload systemd to pick up the new quadlets
echo "Reloading systemd user daemon..."
systemctl --user daemon-reload

# Start the services (systemd will create them from quadlets)
# Note: quadlet-generated services should not be enabled with 'systemctl enable'
# The [Install] WantedBy directive in the quadlet files handles persistence
echo "Starting services..."
for service in dnsnet-network.service tor-socat.service unbound.service pi-hole.service; do
  if systemctl --user is-active --quiet "$service"; then
    echo "  $service is already running, restarting..."
    systemctl --user restart "$service"
  else
    echo "  Starting $service..."
    systemctl --user start "$service"
  fi
done

# Configure system DNS
./deb/dns-deb.sh

# Return to original directory
cd -

# Note: Keeping repository at $REPO_DIR for potential future updates

echo ""
echo "Installation complete!"
echo "Services started:"
echo "  - dnsnet-network.service (network)"
echo "  - tor-socat.service"
echo "  - unbound.service"
echo "  - pi-hole.service"
echo ""
echo "Check status with: systemctl --user status pi-hole.service"
echo "View logs with: journalctl --user -u pi-hole.service -f"

