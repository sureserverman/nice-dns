#!/usr/bin/env bash
#set -euo pipefail

#Check if there are installed previous versions
if [ "$(podman ps -a | grep -c "tor-socat\|unbound\|pi-hole")" -gt 0 ]
  then
    #Remove them if exist
    podman stop pi-hole || true
    podman rm pi-hole || true
    podman image rm -f nice-dns_pi-hole || true
    podman stop unbound || true
    podman rm unbound || true
    podman image rm -f nice-dns_unbound || true
    podman stop tor-socat || true
    podman rm tor-socat || true
    podman image rm -f sureserver/tor-socat || true
    podman image rm -f pihole/pihole || true
    podman image rm -f alpinelinux/unbound || true
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

#Start podman containers
git clone https://github.com/sureserverman/nice-dns.git
cd nice-dns
podman network create \
  --driver bridge \
  --subnet 172.31.240.248/29 \
  dnsnet
PODMAN_COMPOSE_PROVIDER=podman-compose BUILDAH_FORMAT=docker \
podman compose --podman-run-args="--health-on-failure=restart" up -d
./persistent-podman.sh
./dns-deb.sh
cd -
rm -rf nice-dns
