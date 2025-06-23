#!/bin/bash
# Podman auto-start script for LaunchDaemon

# Set PATH in case environment from launchd is limited
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

unset SSH_AUTH_SOCK

# Start Podman machine (if not already running)
echo "$(date): Starting Podman machine..." >> ~/Library/Logs/podman-autostart.out 2>&1
podman machine start >> ~/Library/Logs/podman-autostart.out 2>&1

# Wait for VM to be responsive
echo "$(date): Waiting for Podman service..." >> ~/Library/Logs/podman-autostart.out 2>&1
tries=0
until podman info >> ~/Library/Logs/podman-autostart.out 2>&1; do
    ((tries++))
    if [ $tries -ge 30 ]; then 
      echo "$(date): Podman service did not become ready in time, exiting." >> ~/Library/Logs/podman-autostart.err 2>&1
      exit 1
    fi
    sleep 2
done

# Start all containers with restart=always
echo "$(date): Starting containers (restart=always)..." >> ~/Library/Logs/podman-autostart.out 2>&1
podman start --filter restart-policy=always --all >> ~/Library/Logs/podman-autostart.out 2>&1
