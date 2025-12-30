#!/bin/bash

# Graceful ZFS Unmount Hook for macOS Shutdown/Logout
# This script is called by LaunchAgent before system shutdown

set -euo pipefail

CONFIG_FILE="$HOME/.config/zfs-mount/config.env"
LOG_FILE="$HOME/Library/Logs/zfs-mount.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SHUTDOWN-HOOK] $*" >> "$LOG_FILE"
}

log "Shutdown hook triggered"

# Load configuration
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    
    if [[ "${ENABLE_SHUTDOWN_HOOK:-true}" != "true" ]]; then
        log "Shutdown hook disabled in config"
        exit 0
    fi
else
    log "Config file not found, skipping shutdown hook"
    exit 0
fi

# Check if VM is running
vm_status=$(osascript -e "tell application \"UTM\" to get status of virtual machine \"$VM_NAME\"" 2>/dev/null || echo "error")

if [[ "$vm_status" != "started" ]]; then
    log "VM not running, nothing to do"
    exit 0
fi

log "VM is running, checking for mounted shares"

# Find mounted shares
mounted_shares=$(mount | grep "$VM_IP" | awk '{print $3}' || true)

if [[ -z "$mounted_shares" ]]; then
    log "No ZFS shares mounted, nothing to unmount"
    exit 0
fi

log "Found mounted shares, initiating graceful unmount"

# Run the unmount script non-interactively
"{{SCRIPT_DIR}}/scripts/unmount-zfs.sh" &>/dev/null &
pid=$!
sleep 30
if kill -0 $pid 2>/dev/null; then
    kill $pid 2>/dev/null
    log "Unmount timed out during shutdown"
else
    wait $pid
    log "Unmount completed successfully"
fi

log "Shutdown hook completed"
exit 0
