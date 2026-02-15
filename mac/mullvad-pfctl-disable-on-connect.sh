#!/bin/bash
set -euo pipefail

# mullvad-pfctl-disable-on-connect
# Disables PF (pfctl -d) once each time Mullvad VPN transitions into Connected state.
# Designed to run as a LaunchDaemon (root).

readonly STATE_DIR="/var/db/mullvad-pfctl-disable-on-connect"
readonly STATE_FILE="${STATE_DIR}/last_state"

log() { printf '%s [mullvad-pfctl] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# --- Require root ---
if [[ "$(id -u)" -ne 0 ]]; then
    log "ERROR: must run as root (current uid=$(id -u))"
    exit 1
fi

# --- State directory ---
if [[ ! -d "$STATE_DIR" ]]; then
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
fi

# --- Locate Mullvad CLI ---
find_mullvad_bin() {
    local bin
    if bin="$(command -v mullvad 2>/dev/null)"; then
        printf '%s' "$bin"
        return 0
    fi
    local app_path="/Applications/Mullvad VPN.app/Contents/Resources/mullvad"
    if [[ -x "$app_path" ]]; then
        printf '%s' "$app_path"
        return 0
    fi
    return 1
}

MULLVAD_BIN=""
if ! MULLVAD_BIN="$(find_mullvad_bin)"; then
    log "Mullvad CLI not found; will exit and retry later"
    exit 0
fi
readonly MULLVAD_BIN
log "Using Mullvad CLI: ${MULLVAD_BIN}"

# --- State helpers ---
current_state() {
    local line
    line="$("$MULLVAD_BIN" status 2>/dev/null | head -n 1 | tr -d '\r')"
    # First token only (e.g. "Connected", "Disconnected", "Connecting")
    printf '%s' "${line%% *}"
}

read_prev_state() {
    cat "$STATE_FILE" 2>/dev/null || true
}

write_state() {
    printf '%s' "$1" > "$STATE_FILE"
}

# --- Edge-triggered pfctl -d ---
handle_state() {
    local cur="$1"
    local prev
    prev="$(read_prev_state)"

    if [[ "$cur" == "Connected" && "$prev" != "Connected" ]]; then
        log "Transition ${prev:-<none>} -> Connected; running pfctl -d"
        if pfctl -d 2>&1; then
            log "pfctl -d succeeded"
        else
            log "WARNING: pfctl -d exited with status $?"
        fi
    fi

    write_state "$cur"
}

# --- Event-driven mode (preferred) ---
run_listen() {
    log "Starting event-driven mode (mullvad status listen)"
    "$MULLVAD_BIN" status listen 2>&1 | while IFS= read -r line; do
        line="${line%%$'\r'}"
        local token="${line%% *}"
        case "$token" in
            Connected|Disconnected|Connecting|Disconnecting|Error)
                handle_state "$token"
                ;;
        esac
    done
    # status listen exited unexpectedly
    log "mullvad status listen exited; sleeping before restart"
    sleep 5
}

# --- Polling mode (fallback) ---
run_poll() {
    local cur
    cur="$(current_state || echo "Unknown")"
    handle_state "$cur"
}

# --- Main ---
supports_listen() {
    # Quick probe: run status listen, see if it emits anything within 2s
    local output
    output="$(timeout 2 "$MULLVAD_BIN" status listen 2>/dev/null | head -n 1)" || true
    [[ -n "$output" ]]
}

if supports_listen; then
    while true; do
        run_listen
    done
else
    log "status listen unavailable; running single-shot poll"
    run_poll
fi
