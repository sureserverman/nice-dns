#!/usr/bin/env bash
# Installs the LaunchAgent and its privileged helper for the Apple `container`
# runtime, without the Podman-era pfctl/port-53 assets.
#
# Usage: ./mac/persist.sh [haproxy|socat]

set -euo pipefail

VARIANT="${1:-haproxy}"
case "$VARIANT" in haproxy|socat) ;; *)
  echo "variant must be 'haproxy' or 'socat'" >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"

# The rule below runs /usr/local/sbin/start-container-root.sh as root without
# a password: a directory on that path this user can write would let the user
# swap the helper and run anything as root. ND_PERSIST_ROOT is for the fixture
# tests only.
for d in "${ND_PERSIST_ROOT:-}/usr/local" "${ND_PERSIST_ROOT:-}/usr/local/sbin"; do
  [ -e "$d" ] || [ -L "$d" ] || continue
  if [ -L "$d" ] || [ -z "$(find "$d" -maxdepth 0 -user root ! -perm -g+w ! -perm -o+w)" ]; then
    echo "$d must be a directory owned by root and writable by no one else: the agent's passwordless rule would let this user replace its root helper. Fix its owner and mode (sudo chown root:wheel; sudo chmod 755) and re-run." >&2
    exit 1
  fi
done

# -- sudoers: allow the LaunchAgent to run only the pre/post helper --
tmp_sudoers="$(mktemp)"
trap 'rm -f "$tmp_sudoers"' EXIT
sed "s/__USERNAME__/$(whoami)/" "$HERE/start-container.sudoers" > "$tmp_sudoers"
# Checked before it goes live: a rule sudo cannot parse breaks sudo for
# everyone.
sudo visudo -cf "$tmp_sudoers"
sudo install -m 440 "$tmp_sudoers" /etc/sudoers.d/start-container
sudo visudo -cf /etc/sudoers.d/start-container

# -- install scripts (ensure /usr/local/sbin exists on fresh macOS) --
sudo install -d -m 755 /usr/local/sbin
sudo install -m 755 "$HERE/start-container.sh"            /usr/local/sbin/start-container.sh
sudo install -m 755 "$HERE/start-container-root.sh"       /usr/local/sbin/start-container-root.sh
# fetch-bridges.sh is invoked from start-container.sh at every LaunchAgent
# fire so the stack always uses the fastest bridges from the current network.
sudo install -m 755 "$HERE/../scripts/fetch-bridges.sh"   /usr/local/sbin/nice-dns-fetch-bridges.sh
# Host-side bridge selection. fetch-bridges.sh deliberately does not rank the
# pool it writes — a TCP probe cannot tell a working bridge from one that is
# TCP-open but PT-dead — and the proxy consumes bridges.env as-is, so without
# this every fetched bridge became a Bridge line, dead ones included. Linux has
# had the equivalent since deb/persistent-podman.sh grew its
# nice-dns-fetch-bridges.service unit.
sudo install -m 755 "$HERE/bridge-eval.sh"                /usr/local/sbin/nice-dns-bridge-eval.sh

# -- The controller (health/nice-dns-health; Sub-plan 3 Task 2.1): a versioned
# bundle and the org.nice-dns.health agent running `nice-dns-health tick`
# every minute (and on wake). It replaces the old 30-minute `run` agent in
# place, and only after the new bundle loads. A failure leaves the stack
# running but unwatched, so it fails the install loudly.
"$HERE/../health/nice-dns-health" install || {
  echo "The nice-dns controller did not install; the stack runs without health checks or recovery." >&2
  exit 1
}
# The installed copy must load its bundle before the agent below can pin DNS.
CTRL_RECEIPT="$HOME/Library/Application Support/nice-dns-health/install.tsv"
CTRL_BIN="$(awk -F '\t' 'NR == 1 && $0 != "schema\tnice-dns-health-install/1" { exit } $1 == "entrypoint" { print $2; exit }' "$CTRL_RECEIPT" 2>/dev/null)"
if [ -z "$CTRL_BIN" ] || ! /bin/bash "$CTRL_BIN" self-check >/dev/null; then
  echo "The installed nice-dns controller fails its self-check; not loading the start-container agent (which pins DNS)." >&2
  exit 1
fi

# -- LaunchAgent: start container system + stack at login --
# Loaded only after the controller installed and its installed copy passed
# its self-check (Sub-plan 4 Task 1.2): the agent's first run pins every
# network service to the stack (start-container-root.sh post), so a failed
# controller install or self-check above exits before any pin.
AGENT_DST="$HOME/Library/LaunchAgents/org.nice-dns.start-container.plist"
launchctl unload "$AGENT_DST" 2>/dev/null || true
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s/__USERNAME__/$(whoami)/" -e "s/__VARIANT__/$VARIANT/" \
  "$HERE/org.nice-dns.start-container.plist" > "$AGENT_DST"
chmod 644 "$AGENT_DST"
launchctl load "$AGENT_DST"

# The out-of-band bridge refresh is the controller's daily
# org.nice-dns.health-bridges agent (installed above; Sub-plan 3 Task 2.2). It
# evaluates off the startup path, as the old org.nice-dns.bridge-eval agent
# did, but adopts a changed set only at the proxy's next start. The old agent
# is retired once the controller has installed.
EVAL_DST="$HOME/Library/LaunchAgents/org.nice-dns.bridge-eval.plist"

echo "LaunchAgent installed (variant=$VARIANT): start-container."

# The replacement runs: retire the legacy bridge-eval agent, which wrote
# bridges.env directly.
if [ -f "$EVAL_DST" ]; then
  launchctl unload "$EVAL_DST" 2>/dev/null || true
  rm -f "${EVAL_DST:?}"
  echo "Retired the legacy org.nice-dns.bridge-eval agent (the controller refreshes bridges daily)."
fi
