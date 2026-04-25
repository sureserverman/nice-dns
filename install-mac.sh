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
# and the system DNS pin. Homebrew packages (container, git) and Rosetta are
# left in place — they may be shared with other tools.
teardown() {
  AGENT="$HOME/Library/LaunchAgents/org.nice-dns.start-container.plist"
  launchctl unload "$AGENT" 2>/dev/null || true
  rm -f "$AGENT"
  sudo rm -f /etc/sudoers.d/start-container \
             /usr/local/sbin/start-container.sh \
             /usr/local/sbin/start-container-root.sh

  # Container CLI may be absent on a half-installed/fresh host — tolerate.
  local bin="${CONTAINER_BIN:-container}"
  if command -v "$bin" >/dev/null 2>&1; then
    for c in pi-hole unbound tor-haproxy tor-socat; do
      "$bin" stop "$c" >/dev/null 2>&1 || true
      "$bin" rm   "$c" >/dev/null 2>&1 || true
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
for pkg in git container; do
  brew list --formula "$pkg" >/dev/null 2>&1 || brew install "$pkg"
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

# -- Build local images --
"$CONTAINER_BIN" builder start >/dev/null 2>&1 || true
"$CONTAINER_BIN" build -t unbound unbound/
"$CONTAINER_BIN" build -t pi-hole pihole/

# Builder VM isn't needed once images are built; reclaim ~2 GB RAM. It will
# auto-start again on the next `container build`.
"$CONTAINER_BIN" builder stop >/dev/null 2>&1 || true

# -- Create network and start containers in IP-allocation order --
"$CONTAINER_BIN" network create --subnet 172.31.240.248/29 dnsnet >/dev/null

"$CONTAINER_BIN" run -d --name pi-hole --network dnsnet \
  -c 1 -m 256M \
  -e TZ=Europe/London \
  -e DNS1=172.31.240.251 \
  -e DISABLE_GITHUB_UPDATES=true \
  pi-hole:latest >/dev/null

"$CONTAINER_BIN" run -d --name unbound --network dnsnet \
  -c 1 -m 256M \
  unbound:latest >/dev/null

# Fetch default obfs4 bridges from the Tor Project on first install, then
# pass them into the container. Idempotent: bridges.env is reused on re-runs.
"$HERE/scripts/fetch-bridges.sh"
# shellcheck disable=SC1090,SC1091
. "${XDG_CONFIG_HOME:-$HOME/.config}/nice-dns/bridges.env"
: "${BRIDGE1:?bridges.env did not export BRIDGE1}"
: "${BRIDGE2:?bridges.env did not export BRIDGE2}"
"$CONTAINER_BIN" run -d --name "tor-${VARIANT}" --network dnsnet \
  -c 1 -m 512M \
  -e "BRIDGE1=${BRIDGE1}" \
  -e "BRIDGE2=${BRIDGE2}" \
  "docker.io/sureserver/tor-${VARIANT}:latest" >/dev/null

# -- Wait for the chain (Tor bootstrap) before flipping system DNS --
echo "Waiting for the DNS chain to come up (Tor bootstrap takes ~30-60s)..."
healthy=0
for i in $(seq 1 30); do
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

# Note: pi-hole's gravity DB is built at IMAGE BUILD time (see pihole/Dockerfile),
# so no post-start seed step is needed.

# -- Point the system at pi-hole and install the LaunchAgent --
# start-container-root.sh post also re-bootstraps Mullvad if present;
# harmless at install time when Mullvad wasn't torn down.
sudo "$HERE/mac/start-container-root.sh" post
"$HERE/mac/persist.sh" "$VARIANT"

echo "All done. DNS is set to 172.31.240.250 (pi-hole). Web UI: http://172.31.240.250"
