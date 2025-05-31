#!/usr/bin/env bash
set -euo pipefail

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
