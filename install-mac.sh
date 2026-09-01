#!/usr/bin/env bash
# Install nice-dns on macOS using Apple's `container` runtime. Intended for
# macOS 26+ on Apple silicon; check-runtime.sh gates unsupported hosts.
#
# Usage: ./install-mac.sh [haproxy|socat|uninstall] [branch]
#   first arg defaults to 'haproxy'; 'uninstall' removes the stack and exits.
#   branch defaults to 'main' and is ignored for 'uninstall'.

set -euo pipefail
ACTION="${1:-haproxy}"
BRANCH="${2:-main}"

if [[ $EUID -eq 0 ]]; then
  echo "Run ${0##*/} as a regular user, not sudo." >&2
  exit 1
fi

case "$ACTION" in
  haproxy|socat|uninstall) ;;
  *) echo "Unknown arg '$ACTION'. Use 'haproxy', 'socat', or 'uninstall'." >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"

# Reverse every piece of nice-dns state installed by the script: the
# LaunchAgent, sudoers rule, privileged helpers, containers/images/network,
# and the system DNS pin — plus the Podman-era jobs from installs predating
# commit 7538f02, which no version of this script had ever removed. Homebrew
# packages (container, git) and Rosetta are left in place — they may be
# shared with other tools.
teardown() {
  for _a in org.nice-dns.start-container org.nice-dns.bridge-eval; do
    _p="$HOME/Library/LaunchAgents/${_a}.plist"
    launchctl unload "$_p" 2>/dev/null || true
    rm -f "$_p"
  done
  sudo rm -f /etc/sudoers.d/start-container \
             /usr/local/sbin/start-container.sh \
             /usr/local/sbin/start-container-root.sh \
             /usr/local/sbin/nice-dns-bridge-eval.sh

  # -- Podman-era purge (installs predating commit 7538f02) --------------
  # mac/mac-rules-persist.sh installed four root/user jobs that this script
  # never knew about, so they survived every later reinstall. They are not
  # merely stale:
  #   org.nice-dns.free-port53   boots out com.apple.mDNSResponder at every
  #                              boot, leaving the host with no system
  #                              resolver at all;
  #   com.local.mullvad-pfctl-disable-on-connect
  #                              runs `pfctl -d` once a second, forever
  #                              (KeepAlive + StartInterval 1);
  #   com.local.loopbackalias    aliases 127.0.0.53 onto lo0;
  #   org.startpodman            starts a Podman VM that no longer exists.
  # Observed in the wild on a host installed pre-7538f02: mDNSResponder had
  # been dead across reboots and a gvproxy from the old VM still held :53.
  for _d in org.nice-dns.free-port53 \
            com.local.loopbackalias \
            com.local.mullvad-pfctl-disable-on-connect; do
    sudo launchctl bootout "system/${_d}" 2>/dev/null || true
    sudo rm -f "/Library/LaunchDaemons/${_d}.plist"
  done
  _legacy_agent="$HOME/Library/LaunchAgents/org.startpodman.plist"
  launchctl unload "$_legacy_agent" 2>/dev/null || true
  rm -f "$_legacy_agent"
  sudo rm -f /etc/sudoers.d/start-podman \
             /usr/local/sbin/start-podman.sh \
             /usr/local/sbin/start-podman-root.sh \
             /usr/local/sbin/mullvad-pfctl-disable-on-connect
  sudo ifconfig lo0 -alias 127.0.0.53 2>/dev/null || true

  # Undo free-port53's damage. bootout only removes the service from the
  # running domain — the SIP-protected plist is intact, so re-bootstrapping
  # restores the resolver without a reboot. No-op when it is already loaded.
  if ! sudo launchctl print system/com.apple.mDNSResponder >/dev/null 2>&1; then
    sudo launchctl bootstrap system \
      /System/Library/LaunchDaemons/com.apple.mDNSResponder.plist 2>/dev/null || true
  fi

  # Stop the old Podman stack if it is still up; gvproxy squats :53 and will
  # fight the new pi-hole for it.
  if command -v podman >/dev/null 2>&1; then
    podman machine stop >/dev/null 2>&1 || true
  fi

  # Container CLI may be absent on a half-installed/fresh host — tolerate.
  local bin="${CONTAINER_BIN:-container}"
  if command -v "$bin" >/dev/null 2>&1; then
    for c in pi-hole unbound tor-haproxy tor-socat; do
      "$bin" stop "$c" >/dev/null 2>&1 || true
      "$bin" rm   "$c" >/dev/null 2>&1 || true
    done
    # Drop the images too, not just the containers. Locally built images are
    # rebuilt below; the pulled tor images are re-pulled. Leaving them behind
    # is what let a stale tor image survive repeated reinstalls. Both the bare
    # and registry-qualified names are removed because the local builds are
    # tagged bare (`-t unbound`) while the tor images carry their full
    # docker.io/... reference.
    for i in pi-hole unbound \
             docker.io/sureserver/tor-haproxy:latest \
             docker.io/sureserver/tor-socat:latest; do
      "$bin" image rm "$i" >/dev/null 2>&1 || true
    done
    "$bin" network rm dnsnet >/dev/null 2>&1 || true
  fi

  # Restore DNS to DHCP defaults on every active network service.
  networksetup -listallnetworkservices 2>/dev/null | sed '1d' \
    | { grep -v '^\*' || true; } \
    | while read -r svc; do
        sudo networksetup -setdnsservers "$svc" Empty 2>/dev/null || true
      done
}

if [[ "$ACTION" == "uninstall" ]]; then
  teardown
  echo "nice-dns uninstalled."
  exit 0
fi

VARIANT="$ACTION"

# -- Phase 0: compatibility gate --
# When invoked via `bash <(curl ...)` there is no local checkout yet, so fetch
# the gate script directly from the requested branch and verify its SHA-256
# before sourcing. The expected hash MUST be bumped whenever check-runtime.sh
# is edited; the pre-commit hook in scripts/update-check-runtime-sha.sh
# automates that.
CHECK_RUNTIME_SHA256='62f80b955124c6f379dc0b71bae81d813d8ba0b64a4c45f5bc1b41a85a075a4e'

if [[ -f "$HERE/mac/check-runtime.sh" ]]; then
  # shellcheck source=mac/check-runtime.sh
  source "$HERE/mac/check-runtime.sh" || exit 1
else
  _gate="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/sureserverman/nice-dns/${BRANCH}/mac/check-runtime.sh" -o "$_gate" \
    || { echo "failed to download compatibility gate" >&2; rm -f "$_gate"; exit 1; }
  _gate_sha="$(shasum -a 256 "$_gate" | awk '{print $1}')"
  if [[ "$_gate_sha" != "$CHECK_RUNTIME_SHA256" ]]; then
    echo "ERROR: compatibility gate SHA-256 mismatch." >&2
    echo "  expected: $CHECK_RUNTIME_SHA256" >&2
    echo "  got:      $_gate_sha" >&2
    echo "  branch:   $BRANCH" >&2
    echo "  Refusing to source potentially-tampered code. If you bumped" >&2
    echo "  check-runtime.sh on purpose, update CHECK_RUNTIME_SHA256 above" >&2
    echo "  (or run scripts/update-check-runtime-sha.sh to do it)." >&2
    rm -f "$_gate"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$_gate" || { rm -f "$_gate"; exit 1; }
  rm -f "$_gate"
fi

# -- Homebrew + container + Rosetta + git --
if ! command -v brew >/dev/null; then
  echo "Homebrew not found. Install from https://brew.sh and re-run." >&2
  exit 1
fi

brew update

# Install what's missing AND upgrade what's outdated. The previous form was
# `brew list ... || brew install`, which only ever installed: once a host had
# `container` at any version, every later reinstall kept it. Observed in the
# wild on a host that had been installed months earlier — still running
# container 0.11.0 while 1.2.2 was current, i.e. five minor releases of
# networking and lifecycle fixes behind, with the installer reporting success.
#
# `brew outdated --quiet` lists only formulae with a newer version available,
# so an up-to-date host does no work here.
for pkg in git container; do
  if ! brew list --formula "$pkg" >/dev/null 2>&1; then
    brew install --formula "$pkg"
  elif brew outdated --formula --quiet 2>/dev/null | grep -qx "$pkg"; then
    if [ "$pkg" = container ] && command -v container >/dev/null 2>&1; then
      # Stop the runtime before its binaries are replaced, so the
      # launchd-registered apiserver isn't left pointing at a path brew is
      # about to rewrite. `container system start` below re-registers it.
      container system stop >/dev/null 2>&1 || true
    fi
    brew upgrade --formula "$pkg"
  fi
done

# Apple's container builder is arm64 native, but its VM mounts the host's
# Rosetta so amd64 binaries can run during multi-arch builds (the builder
# config sets rosetta:true unconditionally, with no flag to disable it).
# Install Rosetta so the mount has something to point at; no-op when present.
if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  sudo softwareupdate --install-rosetta --agree-to-license
fi

# -- Bring up the runtime + default kernel --
CONTAINER_BIN="${CONTAINER_BIN:-/opt/homebrew/bin/container}"
# First-time start prompts [Y/n] for the kata kernel download; feed `yes` so
# the install is non-interactive. The subshell swallows the SIGPIPE that
# hits `yes` when `container` exits, which would otherwise trip pipefail.
{ yes 2>/dev/null || true; } | "$CONTAINER_BIN" system start >/dev/null

teardown

# -- Fetch the repo at the requested branch --
# Place WORK under $HOME -- Apple Container's builder VM cannot read
# /var/folders/.../T/ (the macOS default $TMPDIR), so mktemp -d lands in a
# location the build context transfer can't see, yielding an empty context
# and "lstat /etc: no such file or directory" during ADD/COPY.
WORK="$(mktemp -d "$HOME/.nice-dns-install.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
git clone -q -b "$BRANCH" https://github.com/sureserverman/nice-dns.git "$WORK/nice-dns"
cd "$WORK/nice-dns"
HERE="$WORK/nice-dns"

# -- macOS-only unbound.conf + pihole.toml rewrites (cross-netns) --
# Linux runs pi-hole/unbound/tor-haproxy in a single Podman pod, so they share
# one network namespace and the stock configs (interface/upstream all set to
# 127.0.0.1) Just Work. Apple's `container` 0.11.0 has no pod / shared-netns
# support, so each container gets its own netns and its own IP from `dnsnet`.
# Patch the cloned tree (NOT the on-disk repo) so the macOS-built images
# bind on / forward to the dnsnet peer IPs. Linux is untouched.
_uconf="$HERE/unbound/etc/unbound.conf"
sed -i '' -e 's|^    interface: 127\.0\.0\.1$|    interface: 0.0.0.0|' \
          -e 's|^    access-control: 127\.0\.0\.0/8 allow$|    access-control: 127.0.0.0/8 allow\
    access-control: 172.31.240.248/29 allow|' \
          -e 's|^    forward-addr: 127\.0\.0\.1@853#tor\.cloudflare-dns\.com$|    forward-addr: 172.31.240.252@853#tor.cloudflare-dns.com|' \
          "$_uconf"

# Note: pi-hole's bundled pihole.toml hardcodes upstreams = ["127.0.0.1#5335"]
# for the Linux pod path; on macOS unbound is a peer container at .251. We
# can't sed the toml at build time — pi-hole runs `pihole -g` during image
# build and pre-flights the configured upstream, which would fail (no unbound
# yet). Instead, override at runtime via FTLCONF_dns_upstreams (set on the
# pi-hole container below); see -e FTLCONF_dns_upstreams in the run line.

# -- Build local images --
# --dns 1.1.1.1 because Apple's container builder VM's default DNS forwarding
# is unreliable when the host network's DNS is censoring or partial; the
# pi-hole image build does an upstream pihole -g which needs working DNS.
#
# --pull re-fetches the FROM base on every install. Both Containerfiles build
# on a floating :latest tag (sureserver/hardened-unbound, pihole/pihole), and
# without this the builder silently reuses whatever base it cached the first
# time — so a reinstall months later can still produce an image built on a
# months-old base while reporting success.
#
# --no-cache is the other half, and --pull alone is not enough. The builder's
# layer cache outlives the images themselves: deleting an image and rebuilding
# still replays cached RUN layers, so their *output* is whatever the first
# build produced. That matters here because our RUN steps fetch from the
# network — pihole/Containerfile runs `pihole -g` to download the gravity
# blocklists and `apk -U upgrade` to apply security updates, and
# unbound/Containerfile runs post-install.sh. Cached, a reinstall yields an
# image whose blocklists and package updates are as old as the first install.
# The cost is a slower install; the alternative is an installer that claims
# to have built a current image and hasn't.
"$CONTAINER_BIN" builder start >/dev/null 2>&1 || true
"$CONTAINER_BIN" build --pull --no-cache --dns 1.1.1.1 -t unbound unbound/
"$CONTAINER_BIN" build --pull --no-cache --dns 1.1.1.1 -t pi-hole pihole/

# Builder VM isn't needed once images are built; reclaim ~2 GB RAM. It will
# auto-start again on the next `container build`.
"$CONTAINER_BIN" builder stop >/dev/null 2>&1 || true

# -- Create network and start containers in IP-allocation order --
"$CONTAINER_BIN" network create --subnet 172.31.240.248/29 dnsnet >/dev/null

"$CONTAINER_BIN" run -d --name pi-hole --network dnsnet \
  -c 1 -m 256M \
  -e TZ=Europe/London \
  -e DNS1=172.31.240.251#5335 \
  -e FTLCONF_dns_upstreams=172.31.240.251#5335 \
  -e DISABLE_GITHUB_UPDATES=true \
  pi-hole:latest >/dev/null

"$CONTAINER_BIN" run -d --name unbound --network dnsnet \
  -c 1 -m 256M \
  unbound:latest >/dev/null

# Fetch default obfs4 bridges from the Tor Project on first install, then
# pass them into the container. Idempotent: bridges.env is reused on re-runs.
"$HERE/scripts/fetch-bridges.sh"
# bridges.env is written without surrounding quotes for podman --env-file /
# systemd EnvironmentFile= compatibility (Linux quadlets), so bash `source`
# can't be used here — it would split on whitespace inside the obfs4 line.
# Parse the keys directly with sed instead, taking EVERY BRIDGEn rather than
# the first three. The image accepts BRIDGE1..16, and >=3 is what Conflux needs
# for distinct primary guards -- more is better, not worse. Measured on this
# stack (isolated, alternated, one tor at a time), 3 bridges bootstrapped in a
# 141s median against 41s for 7, with a much worse tail. bridges.env is ranked
# fastest-first and that order is preserved here; slots are renumbered
# contiguously because the image walks BRIDGE1..16 and a gap in the source file
# would hide everything after it.
_bridges_file="${XDG_CONFIG_HOME:-$HOME/.config}/nice-dns/bridges.env"
_bridge_args=()
_nbridges=0
while IFS= read -r _bline; do
  [[ -n "$_bline" ]] || continue
  (( _nbridges < 16 )) || break
  _nbridges=$(( _nbridges + 1 ))
  _bridge_args+=( -e "BRIDGE${_nbridges}=${_bline}" )
done < <(sed -n 's/^BRIDGE[0-9][0-9]*=//p' "$_bridges_file")
if (( _nbridges < 3 )); then
  echo "bridges.env yielded $_nbridges bridge(s); need at least 3." >&2
  exit 1
fi
echo "Using $_nbridges obfs4 bridge(s) from bridges.env."
# The tor proxy is the one image we don't build — it's pulled from Docker Hub.
# `container run` has no --pull flag and reuses any locally cached copy without
# consulting the registry, so an install on a host that ever ran nice-dns would
# silently keep an old image indefinitely. Observed in practice: a host running
# a four-month-old tor-haproxy (ConfluxEnabled 0, NumPrimaryGuards 2, timeout
# server 60s) long after those were fixed upstream, which showed up as multi-
# second cold DNS latency with nothing wrong in this repo. Pull explicitly so
# every install starts from the current published image; this mirrors what
# install-deb.sh already does with `podman pull`.
"$CONTAINER_BIN" image pull "docker.io/sureserver/tor-${VARIANT}:latest"

"$CONTAINER_BIN" run -d --name "tor-${VARIANT}" --network dnsnet \
  -c 1 -m 512M \
  "${_bridge_args[@]}" \
  "docker.io/sureserver/tor-${VARIANT}:latest" >/dev/null

# -- Wait for the chain (Tor bootstrap) before flipping system DNS --
# 60 * 5s = 300s. First-boot obfs4 bridge bootstrap on a censoring network
# can take ~4 minutes before the haproxy primary (Cloudflare onion via Tor)
# marks UP and queries start resolving — 150s was tight enough to fail.
echo "Waiting for the DNS chain to come up (Tor bootstrap takes 1-4 min)..."
healthy=0
for i in $(seq 1 60); do
  if dig @172.31.240.250 +time=3 +tries=1 +short cloudflare.com 2>/dev/null \
      | grep -Eq '^[0-9.]+$'; then
    echo "Chain is resolving."
    healthy=1
    break
  fi
  sleep 5
done

if (( healthy == 0 )); then
  echo "nice-dns did not come up cleanly; refusing to pin system DNS." >&2
  exit 1
fi

# Note: pi-hole's gravity DB is built at IMAGE BUILD time (see pihole/Containerfile),
# so no post-start seed step is needed.

# -- Point the system at pi-hole and install the LaunchAgent --
# start-container-root.sh post also re-bootstraps Mullvad if present;
# harmless at install time when Mullvad wasn't torn down.
sudo "$HERE/mac/start-container-root.sh" post
"$HERE/mac/persist.sh" "$VARIANT"

echo "All done. DNS is set to 172.31.240.250 (pi-hole). Web UI: http://172.31.240.250"
