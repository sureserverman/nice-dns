#!/usr/bin/env bash
# Usage: install-deb.sh [haproxy|socat|uninstall] [branch]
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

  # Two pieces are sufficient to keep /etc/resolv.conf pinned at 127.0.0.1
  # under NetworkManager:
  #
  #   1. dns=none — tell NM to stop managing /etc/resolv.conf entirely.
  #      With this set, per-connection ipv4.dns / ipv4.ignore-auto-dns
  #      have no observable effect; NM never writes resolv.conf, so
  #      whatever custom-dns-deb wrote stays.
  #
  #   2. dispatcher hook — re-run custom-dns-deb on every NM state change,
  #      so if anything *else* on the system (cloud-init, dhclient, a
  #      package upgrade) ever rewrites resolv.conf, the next NM event
  #      pins it back. Cheap defense-in-depth.
  #
  # An earlier version of this function also iterated every active
  # connection to set ipv4.dns 127.0.0.1 and then re-upped them all. With
  # dns=none in effect those modifications had no observable behaviour —
  # and the re-up loop kicked libvirt bridges (virbr0 etc.) into a
  # deactivate→detach-ports→reactivate cycle that orphaned VM tap
  # interfaces (vnet0…). Removed.
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

  sudo systemctl reload NetworkManager 2>/dev/null || sudo systemctl restart NetworkManager
}

configure_ipv6_disable() {
  sudo tee /etc/sysctl.d/99-nice-dns-disable-ipv6.conf >/dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sudo sysctl --system >/dev/null

  # sysctl-only on purpose. The kernel cmdline flag ipv6.disable=1 (shipped by
  # earlier versions as a grub.d drop-in) removes AF_INET6 entirely, so any
  # software that creates an IPv6 socket fails with EAFNOSUPPORT (os error 97)
  # — observed bricking Mullvad's userspace WireGuard (gotatun binds ::), which
  # then fail-closes the whole machine at boot. The sysctl above gives the same
  # posture (no v6 addresses, no v6 traffic) while keeping sockets creatable.
  # Remove the legacy drop-in left by previous installs.
  if [ -f /etc/default/grub.d/99-nice-dns-ipv6.cfg ]; then
    sudo rm /etc/default/grub.d/99-nice-dns-ipv6.cfg
    if command -v update-grub >/dev/null 2>&1; then
      sudo update-grub
    fi
  fi
}

# Podman 5.x defaults the network firewall_driver to "nftables", but the
# netavark nftables driver was only added in netavark 1.9.0. The sejug/podman
# PPA ships Podman 5.x and aardvark-dns but NOT netavark, so on stock Ubuntu the
# resolved netavark stays at 1.4.0 (iptables-only). With that skew every rootless
# podman bridge fails to come up — the pod's infra container exits 125 with
# "netavark: nftables support presently not available", which cascades into
# dependency failures on tor/unbound/pi-hole and the whole stack stays down.
#
# Pin the rootless firewall_driver to whatever the installed netavark can
# actually do. Written as a scoped containers.conf.d drop-in: it never touches
# the system /etc/containers/containers.conf nor the user's own containers.conf,
# and teardown removes it so a later netavark upgrade isn't shadowed.
configure_netavark_firewall_driver() {
  local drop_in nv_ver
  drop_in="$HOME/.config/containers/containers.conf.d/90-nice-dns-firewall.conf"
  nv_ver=$(podman info --format '{{.Host.NetworkBackendInfo.Version}}' 2>/dev/null \
    | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
  # netavark >= 1.9.0 has the nftables driver; leave Podman's default alone.
  if printf '1.9.0\n%s\n' "$nv_ver" | sort -V -C; then
    rm -f "$drop_in"
    return 0
  fi
  mkdir -p "$(dirname "$drop_in")"
  cat > "$drop_in" <<'EOF'
# Installed by nice-dns. netavark < 1.9.0 has no nftables firewall driver, but
# Podman 5.x defaults firewall_driver to "nftables" — the mismatch makes every
# rootless bridge fail with "nftables support presently not available". Pin the
# driver this netavark can actually use. Removed by `install-deb.sh uninstall`.
[network]
firewall_driver = "iptables"
EOF
}

# Reverse every piece of nice-dns state installed by the script (user-mode
# quadlets, containers/images/network, the system-level custom-dns-deb unit,
# and a stale resolv.conf pointer). System-wide tweaks (PPA pin, sysctl,
# AppArmor, subuid/subgid, cgroup delegation) are left in place — they're
# harmless and may be shared with other Podman workloads.
teardown() {
  # Swap /etc/resolv.conf to public resolvers so apt-get and git still work
  # during install, and so the host keeps DNS after uninstall.
  if grep -qxF 'nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null; then
    printf 'nameserver 9.9.9.9\nnameserver 1.1.1.1\nnameserver 1.0.0.1\n' \
      | sudo tee /etc/resolv.conf >/dev/null
  fi

  # Stop and disable user-mode quadlet services, then remove quadlet files.
  # nice-dns-warmup is here only to clean up after older installs that
  # shipped the (since-removed) cache pre-seed unit; current installs
  # never lay it down. Safe to drop from this list once enough cycles
  # of `uninstall` have run in the wild.
  for svc in pi-hole unbound tor-haproxy tor-socat nice-dns-pod nice-dns-network nice-dns-warmup; do
    systemctl --user disable --now "${svc}.service" 2>/dev/null || true
  done
  rm -f "$HOME/.config/containers/systemd/"{pi-hole,unbound,tor-haproxy,tor-socat}.container \
        "$HOME/.config/containers/systemd/nice-dns.pod" \
        "$HOME/.config/containers/systemd/nice-dns.network" \
        "$HOME/.config/systemd/user/nice-dns-warmup.service" \
        "$HOME/.local/bin/nice-dns-warmup" \
        "$HOME/.config/nice-dns/warmup-domains.txt" \
        "$HOME/.config/containers/containers.conf.d/90-nice-dns-firewall.conf"
  systemctl --user daemon-reload 2>/dev/null || true

  # Containers, images, network
  podman pod rm -f nice-dns 2>/dev/null || true
  for name in tor-socat tor-haproxy unbound pi-hole; do
    podman rm -f "$name" 2>/dev/null || true
    podman image rm -f "$name" 2>/dev/null || true
  done
  # The loop above removes the locally built images (tagged bare: unbound,
  # pi-hole) but not the pulled tor images: those are stored under their full
  # docker.io/sureserver/... reference, which a bare name does not match, so
  # they survived every reinstall. The pull on install refreshes them anyway,
  # but leaving them here contradicts the "Containers, images, network"
  # comment above and keeps dead layers on disk after an uninstall.
  for ref in docker.io/sureserver/tor-haproxy:latest \
             docker.io/sureserver/tor-socat:latest; do
    podman image rm -f "$ref" 2>/dev/null || true
  done
  podman network rm dnsnet 2>/dev/null || true

  # System-level custom-dns-deb.service
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

# Pin all sejug/podman PPA packages (podman, crun, containers-common, ...) at
# priority 600 so apt installs the PPA's coherent stack rather than mixing with
# Ubuntu archive versions. Inert if the PPA isn't added yet.
printf 'Package: *\nPin: release o=LP-PPA-sejug-podman\nPin-Priority: 600\n' \
  | sudo tee /etc/apt/preferences.d/podman-ppa >/dev/null

teardown

# Repair package state if a previous install left the PPA half-configured
if grep -rqs 'sejug/podman' /etc/apt/sources.list.d/ 2>/dev/null; then
  sudo apt-get update -q
  sudo apt-get install -yq --fix-broken
fi

# Base packages. catatonit is the pause binary Podman uses when building the
# pod's infra container (`podman pod create` errors out with "finding pause
# binary: exec: catatonit: executable file not found in $PATH" without it).
# netavark is Podman 5.x's network backend and aardvark-dns is the in-network
# resolver; both are pulled via Recommends on stock Ubuntu, but we use
# --no-install-recommends, so name them explicitly. Without netavark, `podman
# network create dnsnet` fails with "netavark: not found".
sudo apt-get install -yq --no-install-recommends git podman netavark aardvark-dns catatonit

# Ensure user-level registries.conf knows about docker.io
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

# Ensure Podman >= 5.3.0. The .pod quadlet type itself only exists in Podman
# 5.0+, so a stale 4.x binary will silently ignore deb/quadlet/nice-dns.pod
# and `systemctl --user restart nice-dns-pod.service` fails with
# "Unit nice-dns-pod.service not found." Re-check after the upgrade so we
# fail fast with a clear message instead of bombing out later in
# persistent-podman.sh.
MIN_PODMAN="5.3.0"
CUR_PODMAN=$(podman --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
if ! printf '%s\n%s\n' "$MIN_PODMAN" "$CUR_PODMAN" | sort -V -C; then
  echo "Podman $CUR_PODMAN < $MIN_PODMAN — upgrading via ppa:sejug/podman..."
  sudo add-apt-repository -y ppa:sejug/podman
  sudo apt-get update -q
  sudo apt-get install -yq --fix-broken
  # PPA's containers-common replaces golang-github-containers-{common,image}
  # from Ubuntu repos; remove them first to avoid dpkg file conflicts
  for pkg in golang-github-containers-common golang-github-containers-image; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
      sudo dpkg --remove --force-depends "$pkg"
    fi
  done
  # Ubuntu's podman-compose and PPA's podman both ship
  # /usr/share/man/man1/podman-compose.1.gz; divert *before* installing the
  # PPA podman so dpkg doesn't fail with a file conflict. Must happen before
  # the `apt-get install podman crun` below.
  sudo dpkg-divert --add --rename --package podman \
    --divert /usr/share/man/man1/podman-compose.1.gz.dpkg-divert \
    /usr/share/man/man1/podman-compose.1.gz 2>/dev/null || true
  sudo apt-get install -yq --no-install-recommends podman crun
  # Re-check that the upgrade actually moved us to >= 5.3.0. The PPA does not
  # ship every Ubuntu release / arch combo, and apt-get can return success
  # without changing the binary version (no candidate, version held, etc.).
  CUR_PODMAN=$(podman --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
  if ! printf '%s\n%s\n' "$MIN_PODMAN" "$CUR_PODMAN" | sort -V -C; then
    echo "ERROR: Podman is still at $CUR_PODMAN after the upgrade attempt." >&2
    echo "       nice-dns requires Podman >= $MIN_PODMAN (the .pod quadlet" >&2
    echo "       type was added in Podman 5.0). Check whether ppa:sejug/podman" >&2
    echo "       has a build for $(lsb_release -cs 2>/dev/null || uname -m):" >&2
    echo "         apt-cache policy podman" >&2
    echo "       If no PPA candidate is available for your Ubuntu release/arch," >&2
    echo "       upgrade to a release that ships Podman 5.x natively (Ubuntu 25.04+)." >&2
    exit 1
  fi
fi

# Ensure crun >= 1.14.3 (older versions reject OCI runtime-spec 1.2.x from Podman 5)
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
  # Standalone (non-pod) containers run with --userns=keep-id place their netns
  # under run/user/<uid>/netns/ rather than the containers/ subtree; pasta must
  # read that dir to enter the namespace. Without this, the host-side bridge-eval
  # "manage" job (nice-dns-fetch-bridges.service) dies with pasta "netns dir
  # open: Permission denied" (exit 126), so bridges.env never refreshes.
  @{run}/user/@{uid}/netns/ r,
  @{run}/user/@{uid}/netns/** rwlk,

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

# Disable dns=dnsmasq in NetworkManager if present (conflicts with pi-hole)
NM_CONFIG="/etc/NetworkManager/NetworkManager.conf"
if [ -f "$NM_CONFIG" ] && grep -Eq '^[[:space:]]*dns[[:space:]]*=[[:space:]]*dnsmasq' "$NM_CONFIG"; then
  sudo sed -i -E 's|^[[:space:]]*dns[[:space:]]*=[[:space:]]*dnsmasq|#&|' "$NM_CONFIG"
  sudo systemctl restart NetworkManager
fi

# Add UID/GID mappings for current user if missing. Accept any pre-existing
# range — usermod --add-sub{u,g}ids fails if the user already has an entry
# and we have no reason to force our specific range over whatever is there.
if ! grep -q "^$USER:" /etc/subuid 2>/dev/null; then
  sudo usermod --add-subuids 100000-165535 "$USER"
fi
if ! grep -q "^$USER:" /etc/subgid 2>/dev/null; then
  sudo usermod --add-subgids 100000-165535 "$USER"
fi

# Enable cgroups v2 delegation for systemd services
sudo mkdir -p /etc/systemd/system/user@.service.d
sudo tee /etc/systemd/system/user@.service.d/delegate.conf >/dev/null << EOF
[Service]
Delegate=cpu cpuset io memory pids
EOF
sudo systemctl daemon-reload

# Enable user lingering for service persistence
sudo loginctl enable-linger "$USER"

# Re-exec the user's systemd manager so it picks up the new cgroup
# delegation config. daemon-reload only affects PID 1 (system level);
# the user instance keeps the old settings until re-exec or reboot.
systemctl --user daemon-reexec

# Pick up subuid/subgid and cgroup delegation changes
podman system migrate

# Reconcile the rootless firewall driver with the installed netavark's
# capabilities before the stack starts (see function comment above).
configure_netavark_firewall_driver

# Work from an in-tree checkout if present; otherwise fetch a fresh clone
# into a scoped temp dir so we never touch any unrelated 'nice-dns/' the
# user happens to have in their cwd.
if [[ -d deb/quadlet && -f deb/custom-dns-deb ]]; then
  WORKDIR="$(pwd)"
  CLONED=""
else
  CLONED="$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-install.XXXXXXXX")"
  git clone -b "$BRANCH" https://github.com/sureserverman/nice-dns.git "$CLONED/nice-dns"
  WORKDIR="$CLONED/nice-dns"
fi

cd "$WORKDIR"
# Bridge selection is no longer done here. persistent-podman.sh installs the
# host-side bridge-eval "manage" service (fetch Moat + rdsys distributor,
# accumulate a persistent pool, test real obfs4 usability, write the
# *reachable* set to ~/.config/nice-dns/bridges.env) and runs it once before
# the stack starts.
# --dns 1.1.1.1 ensures the pi-hole image build's `pihole -g` precheck
# always succeeds, even on hosts whose default resolver is partial.
#
# --pull=newer re-fetches the FROM base when the registry has a newer one.
# Both Containerfiles build on a floating :latest tag (sureserver/hardened-
# unbound, pihole/pihole) and podman build defaults to --pull=missing, which
# reuses a cached base forever — so a reinstall could keep producing images
# built on a months-old base. "newer" rather than "always" so an unchanged
# base costs a digest check instead of a full re-download.
podman build --pull=newer --dns 1.1.1.1 -t unbound unbound/
podman build --pull=newer --dns 1.1.1.1 -t pi-hole pihole/
podman pull "docker.io/sureserver/tor-${VARIANT}:latest"
./deb/persistent-podman.sh "$VARIANT"
# Note: pi-hole's gravity DB is built at IMAGE BUILD time (see pihole/Containerfile),
# so no post-start seed step is needed — pihole-FTL serves DNS immediately.

# Install and start custom-dns-deb.service
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
