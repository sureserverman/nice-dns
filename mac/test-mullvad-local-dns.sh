#!/usr/bin/env bash
set -euo pipefail

PLIST="/Library/LaunchDaemons/net.mullvad.daemon.plist"
LABEL="net.mullvad.daemon"
KEY_PATH=":EnvironmentVariables:TALPID_DISABLE_LOCAL_DNS_RESOLVER"

usage() {
  cat <<USAGE
Usage: $0 [--check|--apply|--revert] [--restart]

Options:
  --check    Only report current state (default)
  --apply    Set TALPID_DISABLE_LOCAL_DNS_RESOLVER=1 in Mullvad plist
  --revert   Remove TALPID_DISABLE_LOCAL_DNS_RESOLVER from Mullvad plist
  --restart  Restart Mullvad daemon after apply/revert

Examples:
  $0 --check
  $0 --apply --restart
  $0 --revert --restart
USAGE
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0 $*" >&2
    exit 1
  fi
}

plist_has_key() {
  /usr/libexec/PlistBuddy -c "Print ${KEY_PATH}" "$PLIST" >/dev/null 2>&1
}

print_binding_state() {
  echo "== Port 53 listeners (TCP/UDP) =="
  if ! lsof -nP -iUDP:53 -iTCP:53; then
    echo "No listeners found on port 53"
  fi
  echo

  echo "== Mullvad listeners on port 53 =="
  if ! lsof -nP -iUDP:53 -iTCP:53 2>/dev/null | grep -i mullvad; then
    echo "Mullvad is not listening on port 53"
  fi
  echo
}

print_plist_state() {
  echo "== Plist state =="
  if [[ ! -f "$PLIST" ]]; then
    echo "Missing: $PLIST"
    return
  fi

  if plist_has_key; then
    local value
    value=$(/usr/libexec/PlistBuddy -c "Print ${KEY_PATH}" "$PLIST" 2>/dev/null || true)
    echo "${KEY_PATH}=${value}"
  else
    echo "${KEY_PATH} is not set"
  fi
  echo
}

apply_setting() {
  require_root "$@"

  if [[ ! -f "$PLIST" ]]; then
    echo "Missing: $PLIST" >&2
    exit 1
  fi

  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Set ${KEY_PATH} 1" "$PLIST" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add ${KEY_PATH} string 1" "$PLIST"

  echo "Set ${KEY_PATH}=1"
}

revert_setting() {
  require_root "$@"

  if [[ ! -f "$PLIST" ]]; then
    echo "Missing: $PLIST" >&2
    exit 1
  fi

  /usr/libexec/PlistBuddy -c "Delete ${KEY_PATH}" "$PLIST" >/dev/null 2>&1 || true

  echo "Removed ${KEY_PATH}"
}

restart_daemon() {
  require_root "$@"

  echo "Restarting ${LABEL}..."
  if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
  fi

  if launchctl bootstrap system "$PLIST" >/dev/null 2>&1; then
    echo "Restart done via bootstrap"
    return
  fi

  rc=$?
  echo "launchctl bootstrap failed (rc=${rc}). Trying enable+kickstart fallback..."
  launchctl enable "system/${LABEL}" >/dev/null 2>&1 || true
  if launchctl kickstart -k "system/${LABEL}" >/dev/null 2>&1; then
    echo "Restart done via kickstart fallback"
    return
  fi

  echo "Fallback failed. Diagnostics:"
  plutil -lint "$PLIST" || true
  launchctl print "system/${LABEL}" 2>/dev/null | sed -n '1,80p' || true
  exit "$rc"
}

MODE="check"
DO_RESTART="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    --revert)
      MODE="revert"
      shift
      ;;
    --restart)
      DO_RESTART="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$MODE" in
  apply)
    apply_setting
    ;;
  revert)
    revert_setting
    ;;
  check)
    ;;
esac

if [[ "$DO_RESTART" == "true" ]]; then
  restart_daemon
fi

print_plist_state
print_binding_state

echo "Done"
