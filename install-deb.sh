#!/usr/bin/env bash
set -euo pipefail

# This script is intended to be run as an unprivileged user. It uses sudo
# internally for the few commands that require escalation. Running the entire
# script with sudo will break the rootless Podman setup.
if [[ $EUID -eq 0 ]]; then
  echo "Please run install-deb.sh as a regular user, not with sudo." >&2
  exit 1
fi


#Check if there are installed previous versions
if [ "$(podman ps -a | grep -c "tor-socat\|unbound\|pi-hole")" -gt 0 ]
  then
    #Remove them if exist

    echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
    podman rm -f -a || true
    podman image rm -f -a || true
    podman network rm dnsnet || true
  else
    #Install required software
    sudo apt-get install -yq git podman podman-compose
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
fi


echo 'net.ipv4.ip_unprivileged_port_start = 53' | \
  sudo tee /etc/sysctl.d/99-podman-privileged-ports.conf
sudo sysctl --system

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
sudo mkdir -p /etc/systemd/system/user@.service.d
sudo tee /etc/systemd/system/user@.service.d/delegate.conf << EOF
[Service]
Delegate=cpu cpuset io memory pids
EOF
sudo systemctl daemon-reload

# Enable user lingering for service persistence
sudo loginctl enable-linger $USER

#Start podman containers
rm -rf nice-dns
git clone https://github.com/sureserverman/nice-dns.git
cd nice-dns
podman network exists dnsnet || \
  podman network create \
    --driver bridge \
    --subnet 172.31.240.248/29 \
    dnsnet
PODMAN_COMPOSE_PROVIDER=podman-compose BUILDAH_FORMAT=docker \
podman compose --podman-run-args="--health-on-failure=restart" up -d
./deb/persistent-podman.sh
./deb/dns-deb.sh
cd -
rm -rf nice-dns

