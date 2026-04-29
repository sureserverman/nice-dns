#!/usr/bin/env bash
# Hardened-base sibling of install-deb.sh.
#
# Identical to install-deb.sh in every system-level concern (NetworkManager
# pin, IPv6 disable, podman PPA, AppArmor profile, subuid/subgid, lingering,
# quadlet install, custom-dns-deb.service). The ONLY differences are:
#
#   1. Before building pihole/, build localhost/pi-hole-hardened-base:latest
#      from the sibling ../pi-hole-hardened repo (or pull
#      sureserver/pi-hole-hardened:latest from Docker Hub if no sibling).
#
#   2. Build pihole-hardened/Containerfile (FROM the hardened base) instead
#      of pihole/Containerfile (FROM pihole/pihole:latest).
#
#   3. Final image is still tagged localhost/pi-hole:latest, so the existing
#      quadlets and custom-dns-deb pick it up unchanged.
#
# Diff this against install-deb.sh to confirm the surface area.
#
# Usage: install-deb-hardened.sh [haproxy|socat|uninstall] [branch]
#   first arg defaults to 'haproxy'; 'uninstall' removes the stack and exits.
#   branch defaults to 'main' and is ignored for 'uninstall'.

set -euo pipefail

ACTION="${1:-haproxy}"
BRANCH="${2:-main}"

# Runs as an unprivileged user; rootless Podman + user-mode systemd
# require this. sudo is used internally for the few privileged steps.
if [[ $EUID -eq 0 ]]; then
  echo "Please run ${0##*/} as a regular user, not with sudo." >&2
  exit 1
fi

case "$ACTION" in
  haproxy|socat|uninstall) ;;
  *) echo "Unknown arg '$ACTION'. Use 'haproxy', 'socat', or 'uninstall'." >&2; exit 1 ;;
esac

configure_nm_dns_lockdown() {
  if ! command -v nmcli >/dev/null 2>&1; then
    return 0
  fi
  if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
    return 0
  fi

  sudo mkdir -p /etc/NetworkManager/conf.d /etc/NetworkManager/dispatcher.d
  sudo tee /etc/NetworkManager/conf.d/90-nice-dns.conf >/dev/null <<'EOF'
[main]
dns=none
EOF
  sudo tee /etc/NetworkManager/dispatcher.d/90-nice-dns-pin >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -x /usr/bin/custom-dns-deb ]; then
  /usr/bin/custom-dns-deb
fi
EOF
  sudo chmod 755 /etc/NetworkManager/dispatcher.d/90-nice-dns-pin

  while IFS=: read -r uuid type; do
    [ -n "$uuid" ] || continue
    case "$type" in
      bridge|loopback|tun|vpn) continue ;;
    esac
    ipv4_method="$(nmcli -g ipv4.method connection show "$uuid" 2>/dev/null || true)"
    [ "$ipv4_method" = "disabled" ] && continue
    if ! sudo nmcli connection modify "$uuid" \
      ipv4.ignore-auto-dns yes \
      ipv4.dns "127.0.0.1"; then
      echo "Warning: skipped NetworkManager DNS pin for connection $uuid ($type)." >&2
    fi
  done < <(nmcli -t -f UUID,TYPE connection show)

  sudo systemctl reload NetworkManager 2>/dev/null || sudo systemctl restart NetworkManager

  while IFS=: read -r uuid device; do
    [ -n "$uuid" ] || continue
    [ -n "$device" ] || continue
    sudo nmcli connection up "$uuid" >/dev/null 2>&1 || true
  done < <(nmcli -t -f UUID,DEVICE connection show --active)
}

configure_ipv6_disable() {
  sudo tee /etc/sysctl.d/99-nice-dns-disable-ipv6.conf >/dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sudo sysctl --system >/dev/null

  if [ -f /etc/default/grub ] || [ -d /etc/default/grub.d ]; then
    sudo mkdir -p /etc/default/grub.d
    sudo tee /etc/default/grub.d/99-nice-dns-ipv6.cfg >/dev/null <<'EOF'
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX ipv6.disable=1"
EOF

    if command -v update-grub >/dev/null 2>&1; then
      sudo update-grub
    fi
  fi
}

# Build (or pull-and-tag) localhost/pi-hole-hardened-base:latest. Called once
# per install run, before the downstream pihole-hardened/Containerfile build.
# Lives in this installer (not install-deb.sh) so the legacy path is unaffected.
build_pihole_hardened_base() {
  local base_img="localhost/pi-hole-hardened-base:latest"
  local sibling_repo
  sibling_repo="$(cd "$WORKDIR/.." && pwd)/pi-hole-hardened"

  echo "▸ Resolving hardened base image…"
  if [[ -f "$sibling_repo/Dockerfile" && -f "$sibling_repo/post-install.sh" ]]; then
    echo "  • Sibling pi-hole-hardened repo found at $sibling_repo — building locally."
    podman build --dns 1.1.1.1 -t "$base_img" "$sibling_repo"
    return 0
  fi

  local remote="docker.io/sureserver/pi-hole-hardened:latest"
  echo "  • No sibling pi-hole-hardened/ checkout — pulling $remote."
  if podman pull "$remote"; then
    podman tag "$remote" "$base_img"
    return 0
  fi

  echo "ERROR: could not build or pull the hardened base." >&2
  echo "  Either:" >&2
  echo "   - clone https://github.com/sureserverman/pi-hole-hardened next to nice-dns/, OR" >&2
  echo "   - wait for sureserver/pi-hole-hardened:latest to publish on Docker Hub." >&2
  exit 1
}

# Reverse every piece of nice-dns state installed by the script (user-mode
# quadlets, containers/images/network, the system-level custom-dns-deb unit,
# and a stale resolv.conf pointer). System-wide tweaks (PPA pin, sysctl,
# AppArmor, subuid/subgid, cgroup delegation) are left in place — they're
# harmless and may be shared with other Podman workloads.
#
# Note: this teardown also wipes pi-hole-hardened-base, so re-installing the
# legacy variant after the hardened one (or vice-versa) starts from a clean
# image set every time.
teardown() {
  if grep -qxF 'nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null; then
    printf 'nameserver 9.9.9.9\nnameserver 1.1.1.1\nnameserver 1.0.0.1\n' \
      | sudo tee /etc/resolv.conf >/dev/null
  fi

  for svc in pi-hole unbound tor-haproxy tor-socat nice-dns-pod nice-dns-network; do
    systemctl --user disable --now "${svc}.service" 2>/dev/null || true
  done
  rm -f "$HOME/.config/containers/systemd/"{pi-hole,unbound,tor-haproxy,tor-socat}.container \
        "$HOME/.config/containers/systemd/nice-dns.pod" \
        "$HOME/.config/containers/systemd/nice-dns.network"
  systemctl --user daemon-reload 2>/dev/null || true

  podman pod rm -f nice-dns 2>/dev/null || true
  for name in tor-socat tor-haproxy unbound pi-hole pi-hole-hardened-base; do
    podman rm -f "$name" 2>/dev/null || true
    podman image rm -f "$name" 2>/dev/null || true
  done
  podman network rm dnsnet 2>/dev/null || true

  sudo systemctl disable --now custom-dns-deb.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/custom-dns-deb.service /usr/bin/custom-dns-deb
  sudo rm -f /etc/NetworkManager/conf.d/90-nice-dns.conf \
    /etc/NetworkManager/dispatcher.d/90-nice-dns-pin \
    /etc/sysctl.d/99-nice-dns-disable-ipv6.conf \
    /etc/default/grub.d/99-nice-dns-ipv6.cfg
  sudo systemctl daemon-reload
  sudo systemctl reload NetworkManager 2>/dev/null || true
  sudo sysctl --system >/dev/null 2>&1 || true
  if command -v update-grub >/dev/null 2>&1; then
    sudo update-grub >/dev/null 2>&1 || true
  fi
}

if [[ "$ACTION" == "uninstall" ]]; then
  teardown
  echo "nice-dns uninstalled."
  exit 0
fi

VARIANT="$ACTION"

# Pin all sejug/podman PPA packages at priority 600 so apt installs the PPA's
# coherent stack rather than mixing with Ubuntu archive versions.
printf 'Package: *\nPin: release o=LP-PPA-sejug-podman\nPin-Priority: 600\n' \
  | sudo tee /etc/apt/preferences.d/podman-ppa >/dev/null

teardown

if grep -rqs 'sejug/podman' /etc/apt/sources.list.d/ 2>/dev/null; then
  sudo apt-get update -q
  sudo apt-get install -yq --fix-broken
fi

sudo apt-get install -yq --no-install-recommends git podman aardvark-dns

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/containers/registries.conf"
mkdir -p "$(dirname "$CONFIG")"
if [[ ! -f "$CONFIG" ]]; then
  cat > "$CONFIG" <<'EOF'
# registries.conf for Podman

unqualified-search-registries = ["docker.io"]

[[registry]]
prefix = "docker.io"
location = "registry-1.docker.io"
EOF
fi
if grep -q '^[[:space:]]*unqualified-search-registries' "$CONFIG"; then
  if ! grep -q '^[[:space:]]*unqualified-search-registries.*docker.io' "$CONFIG"; then
    sed -i 's|^[[:space:]]*unqualified-search-registries.*|unqualified-search-registries = ["docker.io"]|' "$CONFIG"
  fi
else
  echo 'unqualified-search-registries = ["docker.io"]' >> "$CONFIG"
fi
if ! grep -q '^[[:space:]]*prefix[[:space:]]*=[[:space:]]*"docker.io"' "$CONFIG"; then
  cat >> "$CONFIG" <<'EOF'

[[registry]]
prefix = "docker.io"
location = "registry-1.docker.io"
EOF
fi

MIN_PODMAN="5.3.0"
CUR_PODMAN=$(podman --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
if ! printf '%s\n%s\n' "$MIN_PODMAN" "$CUR_PODMAN" | sort -V -C; then
  echo "Podman $CUR_PODMAN < $MIN_PODMAN — upgrading via ppa:sejug/podman..."
  sudo add-apt-repository -y ppa:sejug/podman
  sudo apt-get update -q
  sudo apt-get install -yq --fix-broken
  for pkg in golang-github-containers-common golang-github-containers-image; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
      sudo dpkg --remove --force-depends "$pkg"
    fi
  done
  sudo apt-get install -yq --no-install-recommends podman crun
fi

MIN_CRUN="1.14.3"
CUR_CRUN=$(crun --version 2>/dev/null | grep -oP 'crun version \K\d+\.\d+(\.\d+)?' || echo "0.0.0")
if ! printf '%s\n%s\n' "$MIN_CRUN" "$CUR_CRUN" | sort -V -C; then
  echo "crun $CUR_CRUN < $MIN_CRUN — upgrading via ppa:sejug/podman..."
  if ! grep -rqs 'sejug/podman' /etc/apt/sources.list.d/ 2>/dev/null; then
    sudo add-apt-repository -y ppa:sejug/podman
    sudo apt-get update -q
  fi
  sudo apt-get install -yq --no-install-recommends crun
fi

if grep -rqs 'sejug/podman' /etc/apt/sources.list.d/ 2>/dev/null; then
  sudo dpkg-divert --add --rename --package podman \
    --divert /usr/share/man/man1/podman-compose.1.gz.dpkg-divert \
    /usr/share/man/man1/podman-compose.1.gz 2>/dev/null || true
fi

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
  sudo tee /etc/sysctl.d/99-podman-privileged-ports.conf >/dev/null
sudo sysctl --system

NM_CONFIG="/etc/NetworkManager/NetworkManager.conf"
if [ -f "$NM_CONFIG" ] && grep -Eq '^[[:space:]]*dns[[:space:]]*=[[:space:]]*dnsmasq' "$NM_CONFIG"; then
  sudo sed -i -E 's|^[[:space:]]*dns[[:space:]]*=[[:space:]]*dnsmasq|#&|' "$NM_CONFIG"
  sudo systemctl restart NetworkManager
fi

if ! grep -q "^$USER:" /etc/subuid 2>/dev/null; then
  sudo usermod --add-subuids 100000-165535 "$USER"
fi
if ! grep -q "^$USER:" /etc/subgid 2>/dev/null; then
  sudo usermod --add-subgids 100000-165535 "$USER"
fi

sudo mkdir -p /etc/systemd/system/user@.service.d
sudo tee /etc/systemd/system/user@.service.d/delegate.conf >/dev/null << EOF
[Service]
Delegate=cpu cpuset io memory pids
EOF
sudo systemctl daemon-reload

sudo loginctl enable-linger "$USER"

systemctl --user daemon-reexec

podman system migrate

if [[ -d deb/quadlet && -f deb/custom-dns-deb && -f pihole-hardened/Containerfile ]]; then
  WORKDIR="$(pwd)"
  CLONED=""
else
  CLONED="$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-install.XXXXXXXX")"
  git clone -b "$BRANCH" https://github.com/sureserverman/nice-dns.git "$CLONED/nice-dns"
  WORKDIR="$CLONED/nice-dns"
fi

cd "$WORKDIR"
./scripts/fetch-bridges.sh

# --dns 1.1.1.1 ensures the pi-hole image build's `pihole -g` precheck
# always succeeds, even on hosts whose default resolver is partial.
podman build --dns 1.1.1.1 -t unbound unbound/

# ─── Hardened-base Pi-hole build (the one line that differs from install-deb.sh) ───
# Step A: build localhost/pi-hole-hardened-base:latest from ../pi-hole-hardened
#         (or pull from Docker Hub if no sibling repo exists).
# Step B: build localhost/pi-hole:latest from pihole-hardened/Containerfile,
#         which `FROM`s the hardened base and layers on the gravity DB,
#         allowlist seeds, and post-install.sh lockdown.
build_pihole_hardened_base
podman build --dns 1.1.1.1 -t pi-hole -f pihole-hardened/Containerfile .
# ─── End of hardened-only block ───

podman pull "docker.io/sureserver/tor-${VARIANT}:latest"
./deb/persistent-podman.sh "$VARIANT"

sudo cp deb/custom-dns-deb.service /etc/systemd/system/custom-dns-deb.service
sudo install -m 755 deb/custom-dns-deb /usr/bin/custom-dns-deb
sudo systemctl daemon-reload
sudo systemctl enable --now custom-dns-deb.service
sudo systemctl restart custom-dns-deb.service
configure_nm_dns_lockdown
configure_ipv6_disable
sudo /usr/bin/custom-dns-deb

cd - >/dev/null
if [[ -n "$CLONED" ]]; then
  rm -rf "$CLONED"
fi
