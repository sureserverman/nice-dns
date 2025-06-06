#!/usr/bin/env bash
set -euo pipefail

#Check if there are installed previous versions
if [ "$(podman ps -a | grep -c "tor-socat\|unbound\|pi-hole")" -gt 0 ]
  then
    #Remove them if exist
    podman stop pi-hole &>/dev/null
    podman rm pi-hole &>/dev/null
    podman image rm nice-dns-web-pi-hole:latest &>/dev/null
    podman stop unbound &>/dev/null
    podman rm unbound &>/dev/null
    podman image rm nice-dns-web-unbound:latest&>/dev/null
    podman stop tor-socat &>/dev/null
    podman rm tor-socat &>/dev/null
    podman image rm sureserver/tor-socat:latest &>/dev/null
    podman network rm nice-dns-web_dnsnet &>/dev/null
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
      exit 0
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

#Start podman containers
git clone https://github.com/sureserverman/nice-dns.git
cd nice-dns
podman network create \
  --driver bridge \
  --subnet 172.31.240.248/29 \
  dnsnet
PODMAN_COMPOSE_PROVIDER=podman-compose podman compose up -d
./persistent-podman.sh
./dns-deb.sh
cd -
rm -rf nice-dns
