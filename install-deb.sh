#!/usr/bin/env bash
set -euo pipefail
BRANCH="${1:-main}"

# This script is intended to be run as an unprivileged user. It uses sudo
# internally for the few commands that require escalation. Running the entire
# script with sudo will break the rootless Podman setup.
if [[ $EUID -eq 0 ]]; then
  echo "Please run install-deb.sh as a regular user, not with sudo." >&2
  exit 1
fi


# Repair package state if a previous install left the PPA with a narrow pin
if grep -rqs 'sejug/podman' /etc/apt/sources.list.d/ 2>/dev/null; then
  printf 'Package: *\nPin: release o=LP-PPA-sejug-podman\nPin-Priority: 600\n' \
    | sudo tee /etc/apt/preferences.d/podman-ppa >/dev/null
  sudo apt-get update -q
  sudo apt-get install -yq --fix-broken
fi

#Check if there are installed previous versions
NICE_DNS_CONTAINERS="tor-socat|tor-haproxy|unbound|pi-hole"
if [ "$(podman ps -a | grep -Ec "$NICE_DNS_CONTAINERS")" -gt 0 ]
  then
    #Remove them if exist

    printf 'nameserver 9.9.9.9\nnameserver 1.1.1.1\nnameserver 1.0.0.1\n' | sudo tee /etc/resolv.conf
    for name in tor-socat tor-haproxy unbound pi-hole; do
      podman rm -f "$name" 2>/dev/null || true
      podman image rm -f "$name" 2>/dev/null || true
    done
    podman network rm dnsnet || true
  else
    #Install required software
    sudo apt-get install -yq --no-install-recommends git podman
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


# Ensure Podman >= 5.3.0 (quadlets broken on mixed cgroup v1+v2 before this)
MIN_PODMAN="5.3.0"
CUR_PODMAN=$(podman --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
if ! printf '%s\n%s\n' "$MIN_PODMAN" "$CUR_PODMAN" | sort -V -C; then
  echo "Podman $CUR_PODMAN < $MIN_PODMAN — upgrading via ppa:sejug/podman..."
  sudo add-apt-repository -y ppa:sejug/podman
  # Pin all PPA packages so the entire container stack resolves from one source
  printf 'Package: *\nPin: release o=LP-PPA-sejug-podman\nPin-Priority: 600\n' \
    | sudo tee /etc/apt/preferences.d/podman-ppa >/dev/null
  sudo apt-get update -q
  sudo apt-get install -yq --fix-broken
  # PPA's containers-common replaces golang-github-containers-{common,image}
  # from Ubuntu repos; remove them first to avoid dpkg file conflicts
  for pkg in golang-github-containers-common golang-github-containers-image; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
      sudo dpkg --remove --force-depends "$pkg"
    fi
  done
  sudo apt-get install -yq --no-install-recommends podman
  echo "Podman upgraded to $(podman --version)."
fi

# Ubuntu's podman-compose and PPA's podman both ship podman-compose.1.gz;
# divert the man page so both packages can coexist without a file conflict
if grep -rqs 'sejug/podman' /etc/apt/sources.list.d/ 2>/dev/null; then
  sudo dpkg-divert --add --rename --package podman \
    --divert /usr/share/man/man1/podman-compose.1.gz.dpkg-divert \
    /usr/share/man/man1/podman-compose.1.gz 2>/dev/null || true
fi

# pasta is a symlink to passt, so AppArmor applies the passt profile.
# Ubuntu Noble's stock passt (0.0~git20240220) ships a profile written before
# Podman 5.x rootless-netns. The PPA upgrades the binary but marks the
# conffiles obsolete, so they'll never be overwritten by package upgrades.
# Replace the entire profile with one that covers rootless-netns.
if [ -f /etc/apparmor.d/usr.bin.passt ]; then
  sudo tee /etc/apparmor.d/usr.bin.passt > /dev/null <<'APPARMOR'
abi <abi/3.0>,

include <tunables/global>

profile passt /usr/bin/passt{,.avx2} flags=(attach_disconnected) {
  include <abstractions/pasta>

  # Podman 5.x rootless-netns with pasta
  allow userns,
  ptrace (read) peer=crun,
  signal (receive) peer=podman,
  @{PROC}/[0-9]*/ns/ r,
  @{PROC}/sys/net/** r,
  @{run}/user/@{uid}/containers/** rwlk,

  owner /tmp/**				w,
  owner @{HOME}/**			w,

  include if exists <local/usr.bin.passt>
}
APPARMOR
  sudo apparmor_parser -r --skip-cache /etc/apparmor.d/usr.bin.passt
fi

echo 'net.ipv4.ip_unprivileged_port_start = 53' | \
  sudo tee /etc/sysctl.d/99-podman-privileged-ports.conf
sudo sysctl --system

CONFIG="/etc/NetworkManager/NetworkManager.conf"

# Check for an uncommented 'dns=dnsmasq' line
if [ -f "$CONFIG" ] && grep -Eq '^[[:space:]]*dns[[:space:]]*=[[:space:]]*dnsmasq' "$CONFIG"; then
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
  sudo usermod --add-subuids 100000-165535 "$USER"
fi
if ! grep -q "^$USER:100000:65536" /etc/subgid 2>/dev/null; then
  sudo usermod --add-subgids 100000-165535 "$USER"
fi

# Enable cgroups v2 delegation for systemd services
sudo mkdir -p /etc/systemd/system/user@.service.d
sudo tee /etc/systemd/system/user@.service.d/delegate.conf << EOF
[Service]
Delegate=cpu cpuset io memory pids
EOF
sudo systemctl daemon-reload

# Enable user lingering for service persistence
sudo loginctl enable-linger "$USER"

#Start podman containers
rm -rf nice-dns
git clone -b "$BRANCH" https://github.com/sureserverman/nice-dns.git
cd nice-dns
podman build -t unbound unbound/
podman build -t pi-hole pihole/
./deb/persistent-podman.sh haproxy
./deb/dns-deb.sh
cd -
rm -rf nice-dns
