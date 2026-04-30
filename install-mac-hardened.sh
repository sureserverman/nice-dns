#!/usr/bin/env bash
# Hardened-base sibling of install-mac.sh.
#
# Identical to install-mac.sh in every system-level concern (Homebrew, Apple
# `container` runtime bring-up, Rosetta install, network creation, LaunchAgent
# install). The ONLY differences are:
#
#   1. Before building pihole/, build localhost/pi-hole-hardened-base:latest
#      from the sibling ../pi-hole-hardened repo (or pull
#      sureserver/pi-hole-hardened:latest from Docker Hub if no sibling).
#
#   2. Build pihole-hardened/Containerfile (FROM the hardened base) instead
#      of pihole/Containerfile (FROM pihole/pihole:latest).
#
#   3. Final image is still tagged pi-hole:latest, so mac/persist.sh and the
#      LaunchAgent pick it up unchanged.
#
# Diff this against install-mac.sh to confirm the surface area.
#
# Usage: ./install-mac-hardened.sh [haproxy|socat|uninstall] [branch]
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

teardown() {
  AGENT="$HOME/Library/LaunchAgents/org.nice-dns.start-container.plist"
  launchctl unload "$AGENT" 2>/dev/null || true
  rm -f "$AGENT"
  sudo rm -f /etc/sudoers.d/start-container \
             /usr/local/sbin/start-container.sh \
             /usr/local/sbin/start-container-root.sh

  local bin="${CONTAINER_BIN:-container}"
  if command -v "$bin" >/dev/null 2>&1; then
    for c in pi-hole unbound tor-haproxy tor-socat; do
      "$bin" stop "$c" >/dev/null 2>&1 || true
      "$bin" rm   "$c" >/dev/null 2>&1 || true
    done
    "$bin" image rm pi-hole-hardened-base >/dev/null 2>&1 || true
    "$bin" network rm dnsnet >/dev/null 2>&1 || true
  fi

  networksetup -listallnetworkservices 2>/dev/null | sed '1d' \
    | { grep -v '^\*' || true; } \
    | while read -r svc; do
        sudo networksetup -setdnsservers "$svc" Empty 2>/dev/null || true
      done
}

# Build (or pull-and-tag) localhost/pi-hole-hardened-base:latest. Called once
# per install run, before the downstream pihole-hardened/Containerfile build.
build_pihole_hardened_base() {
  local base_img="pi-hole-hardened-base:latest"
  local sibling_repo="$HERE/../pi-hole-hardened"

  echo "▸ Resolving hardened base image…"
  if [[ -f "$sibling_repo/Dockerfile" && -f "$sibling_repo/post-install.sh" ]]; then
    echo "  • Sibling pi-hole-hardened repo found at $sibling_repo — building locally."
    "$CONTAINER_BIN" build --dns 1.1.1.1 -t "$base_img" "$sibling_repo"
    return 0
  fi

  local remote="docker.io/sureserver/pi-hole-hardened:latest"
  echo "  • No sibling pi-hole-hardened/ checkout — pulling $remote."
  if "$CONTAINER_BIN" image pull "$remote"; then
    "$CONTAINER_BIN" image tag "$remote" "$base_img" 2>/dev/null \
      || true   # Apple `container` may not implement tag; fall back to alias by env
    return 0
  fi

  echo "ERROR: could not build or pull the hardened base." >&2
  echo "  Either:" >&2
  echo "   - clone https://github.com/sureserverman/pi-hole-hardened next to nice-dns/, OR" >&2
  echo "   - wait for sureserver/pi-hole-hardened:latest to publish on Docker Hub." >&2
  exit 1
}

if [[ "$ACTION" == "uninstall" ]]; then
  teardown
  echo "nice-dns uninstalled."
  exit 0
fi

VARIANT="$ACTION"

# -- Phase 0: compatibility gate --
# Same hash-pinned check as install-mac.sh; if check-runtime.sh changes,
# update the hash in BOTH installers (or call scripts/update-check-runtime-sha.sh).
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
for pkg in git container; do
  brew list --formula "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done

if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  sudo softwareupdate --install-rosetta --agree-to-license
fi

# -- Bring up the runtime + default kernel --
CONTAINER_BIN="${CONTAINER_BIN:-/opt/homebrew/bin/container}"
{ yes 2>/dev/null || true; } | "$CONTAINER_BIN" system start >/dev/null

teardown

# -- Fetch the repo at the requested branch --
WORK="$(mktemp -d "$HOME/.nice-dns-install.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Honor an in-tree checkout when present so a clone with the new
# pihole-hardened/ files is preserved instead of overwritten by a fresh
# clone of $BRANCH (which may not yet contain those files). Whichever path
# we take, WORK_REPO is a writable copy under $WORK — the macOS-only
# unbound.conf rewrite below patches it, and we don't want that to touch
# the user's on-disk checkout.
if [[ -f "$HERE/pihole-hardened/Containerfile" ]]; then
  cp -R "$HERE/." "$WORK/nice-dns"
else
  git clone -q -b "$BRANCH" https://github.com/sureserverman/nice-dns.git "$WORK/nice-dns"
fi
WORK_REPO="$WORK/nice-dns"
cd "$WORK_REPO"
HERE="$WORK_REPO"

# -- macOS-only unbound.conf rewrite (cross-netns) --
# Linux runs pi-hole/unbound/tor-haproxy in a single Podman pod, so they share
# one network namespace and unbound's stock config (interface 127.0.0.1, allow
# 127.0.0.0/8, forward-addr 127.0.0.1@853) Just Works. Apple's `container`
# 0.11.0 has no pod / shared-netns support, so each container gets its own
# netns and its own IP from `dnsnet`. Patch the cloned tree (NOT the on-disk
# repo) so the macOS-built image binds on dnsnet, accepts queries from peers,
# and forwards DoT to tor-haproxy at .252:853. Linux is untouched.
# (Ported from install-mac.sh fix facf5c6.)
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
# pi-hole container below). (Ported from install-mac.sh fix b79e3bc.)

# -- Build local images --
"$CONTAINER_BIN" builder start >/dev/null 2>&1 || true
"$CONTAINER_BIN" build --dns 1.1.1.1 -t unbound unbound/

# ─── Hardened-base Pi-hole build (the one block that differs from install-mac.sh) ───
build_pihole_hardened_base
"$CONTAINER_BIN" build --dns 1.1.1.1 -t pi-hole -f pihole-hardened/Containerfile .
# ─── End of hardened-only block ───

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

"$HERE/scripts/fetch-bridges.sh"
_bridges_file="${XDG_CONFIG_HOME:-$HOME/.config}/nice-dns/bridges.env"
BRIDGE1="$(sed -n 's/^BRIDGE1=//p' "$_bridges_file")"
BRIDGE2="$(sed -n 's/^BRIDGE2=//p' "$_bridges_file")"
: "${BRIDGE1:?bridges.env did not export BRIDGE1}"
: "${BRIDGE2:?bridges.env did not export BRIDGE2}"
"$CONTAINER_BIN" run -d --name "tor-${VARIANT}" --network dnsnet \
  -c 1 -m 512M \
  -e "BRIDGE1=${BRIDGE1}" \
  -e "BRIDGE2=${BRIDGE2}" \
  "docker.io/sureserver/tor-${VARIANT}:latest" >/dev/null

# -- Wait for the chain (Tor bootstrap) before flipping system DNS --
# 60 * 5s = 300s. First-boot obfs4 bridge bootstrap on a censoring network
# can take ~4 minutes before the haproxy primary (Cloudflare onion via Tor)
# marks UP and queries start resolving — 150s was tight enough to fail.
# (Ported from install-mac.sh fix facf5c6.)
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

# -- Point the system at pi-hole and install the LaunchAgent --
sudo "$HERE/mac/start-container-root.sh" post
"$HERE/mac/persist.sh" "$VARIANT"

echo "All done. DNS is set to 172.31.240.250 (pi-hole, hardened base). Web UI: http://172.31.240.250"
