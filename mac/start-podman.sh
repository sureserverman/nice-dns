#!/bin/bash
# Podman auto-start script for LaunchAgent

LOG=~/Library/Logs/podman-autostart.log
ROOT_HELPER=/usr/local/sbin/start-podman-root.sh

log() { echo "$(date): $*" >> "$LOG"; }

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset SSH_AUTH_SOCK

# Wait for system to settle after login
sleep 10

# Start Podman machine with retries
log "Starting Podman machine..."
tries=0
until podman machine start >> "$LOG" 2>&1; do
    ((tries++))
    if [ $tries -ge 5 ]; then
      log "Failed to start Podman machine after $tries attempts."
      exit 1
    fi
    log "Podman machine start failed, retrying ($tries/5)..."
    sleep 10
done

# Wait for VM to be responsive
log "Waiting for Podman service..."
tries=0
until podman info >/dev/null 2>&1; do
    ((tries++))
    if [ $tries -ge 30 ]; then
      log "Podman service did not become ready in time."
      exit 1
    fi
    sleep 2
done
log "Podman service is ready."

log "Running privileged pre-start actions..."
if ! sudo -n "$ROOT_HELPER" pre >> "$LOG" 2>&1; then
  log "Privileged pre-start actions failed. Check sudoers for $ROOT_HELPER."
  exit 1
fi

# Start all containers
log "Starting containers..."
podman restart --all >> "$LOG" 2>&1

sleep 5
log "Running privileged post-start actions..."
if ! sudo -n "$ROOT_HELPER" post >> "$LOG" 2>&1; then
  log "Privileged post-start actions failed. Check sudoers for $ROOT_HELPER."
  exit 1
fi

log "Done."
