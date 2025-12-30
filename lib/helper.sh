#!/bin/bash

# ZFS Mount Automation - Shared Helper Functions
# This file contains common functions used by all ZFS management scripts

# Logging Functions

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ "${ENABLE_LOGGING:-true}" == "true" ]]; then
        echo "[$timestamp] [$level] $message" >> "${LOG_FILE:-$HOME/Library/Logs/zfs-mount.log}"
    fi
    
    case "$level" in
        ERROR)
            echo "[ERROR] $message"
            ;;
        WARN)
            echo "[WARN] $message"
            ;;
        INFO)
            echo "[INFO] $message"
            ;;
        SUCCESS)
            echo "[SUCCESS] $message"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# VM Management Functions

check_vm_status() {
    local status
    status=$(osascript -e "tell application \"UTM\" to get status of virtual machine \"$VM_NAME\"" 2>/dev/null || echo "error")
    echo "$status"
}

check_vm_ssh() {
    if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" "echo 'ready'" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

start_vm() {
    log INFO "Starting VM: $VM_NAME"

    log INFO "Sending start command to VM..."
    if ! osascript <<EOF 2>&1
tell application "UTM"
    set vm to virtual machine "$VM_NAME"
    start vm
end tell
EOF
    then
        log ERROR "Failed to start VM"
        return 1
    fi

    log INFO "Waiting for VM to boot (timeout: ${VM_STARTUP_TIMEOUT}s)"

    local elapsed=0
    while [[ $elapsed -lt $VM_STARTUP_TIMEOUT ]]; do
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" "echo 'ready'" &>/dev/null; then
            log SUCCESS "VM is ready"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log ERROR "VM failed to become ready within ${VM_STARTUP_TIMEOUT}s"
    return 1
}

stop_vm() {
    log INFO "Stopping VM: $VM_NAME"
    
    osascript -e "tell application \"UTM\" to stop virtual machine \"$VM_NAME\"" 2>&1 || {
        log ERROR "Failed to stop VM"
        return 1
    }
    
    local elapsed=0
    local timeout=30
    
    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(check_vm_status)
        
        if [[ "$status" == "stopped" ]]; then
            log SUCCESS "VM stopped successfully"
            return 0
        fi
        
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    log WARN "VM did not stop within ${timeout}s (may still be shutting down)"
    return 0
}

# USB Device Management Functions

find_usb_device() {
    local vendor_id="$1"
    local product_id="$2"
    local pool_name="$3"

    local device_id
    device_id=$(osascript -e "tell application \"UTM\" to get id of first usb device whose vendor id is $vendor_id and product id is $product_id" 2>/dev/null || echo "")

    if [[ -z "$device_id" ]]; then
        log WARN "USB device not found for pool '$pool_name' (vendor: $vendor_id, product: $product_id)"
        return 1
    fi

    echo "$device_id"
}

connect_usb_device() {
    local device_id="$1"
    local pool_name="$2"

    log INFO "Connecting USB device (ID: $device_id) to VM"

    local output
    output=$(osascript <<EOF 2>&1
tell application "UTM"
    set targetDevice to first usb device whose id is $device_id
    connect targetDevice to virtual machine "$VM_NAME"
end tell
EOF
)
    local status=$?

    if [[ $status -ne 0 ]]; then
        if echo "$output" | grep -q "already connected"; then
            log INFO "USB device already connected to VM"
            sleep 1
            return 0
        else
            log ERROR "Failed to connect USB device for pool '$pool_name'"
            echo "$output"
            return 1
        fi
    fi

    sleep 2
    log SUCCESS "USB device connected"
    return 0
}

disconnect_usb_device() {
    local device_id="$1"
    local pool_name="$2"
    
    log INFO "Disconnecting USB device (ID: $device_id) from VM"
    
    if ! osascript <<EOF 2>&1
tell application "UTM"
    set targetDevice to first usb device whose id is $device_id
    disconnect targetDevice
end tell
EOF
    then
        log WARN "Failed to disconnect USB device for pool '$pool_name' (may already be disconnected)"
        return 0
    fi
    
    log SUCCESS "USB device disconnected"
    return 0
}

check_usb_device() {
    local vendor_id="$1"
    local product_id="$2"
    
    local device_id
    device_id=$(osascript -e "tell application \"UTM\" to get id of first usb device whose vendor id is $vendor_id and product id is $product_id" 2>/dev/null || echo "")
    
    if [[ -n "$device_id" ]]; then
        echo "CONNECTED (ID: $device_id)"
        return 0
    else
        echo "NOT_CONNECTED"
        return 1
    fi
}

# ZFS Pool Management Functions

import_zfs_pool() {
    local pool_name="$1"

    log INFO "Importing ZFS pool: $pool_name"

    if ssh "${VM_USER}@${VM_IP}" "zpool list '$pool_name' 2>&1" | grep -q "^$pool_name"; then
        log INFO "Pool '$pool_name' is already imported"
        return 0
    fi

    log INFO "Waiting for device to be recognized..."
    sleep 3

    if ! ssh "${VM_USER}@${VM_IP}" "zpool import 2>&1" | grep -q "$pool_name"; then
        log ERROR "Pool '$pool_name' not available to import. Check USB connection."
        log INFO "Available pools to import:"
        ssh "${VM_USER}@${VM_IP}" "zpool import 2>&1" || true
        log INFO "Block devices:"
        ssh "${VM_USER}@${VM_IP}" "lsblk 2>&1" || true
        return 1
    fi

    if ! ssh "${VM_USER}@${VM_IP}" "zpool import '$pool_name' 2>&1"; then
        log ERROR "Failed to import pool '$pool_name'"
        return 1
    fi

    log SUCCESS "Pool '$pool_name' imported successfully"
    return 0
}

export_zfs_pool() {
    local pool_name="$1"
    local attempt=1
    
    log INFO "Exporting ZFS pool: $pool_name"
    
    if ! ssh "${VM_USER}@${VM_IP}" "zpool list 2>&1 | grep -q '$pool_name'"; then
        log INFO "Pool '$pool_name' is not imported"
        return 0
    fi
    
    while [[ $attempt -le ${RETRY_ATTEMPTS:-3} ]]; do
        log INFO "Export attempt $attempt/${RETRY_ATTEMPTS}"
        
        if ssh "${VM_USER}@${VM_IP}" "zpool export '$pool_name'" 2>&1; then
            log SUCCESS "Successfully exported pool '$pool_name'"
            return 0
        fi
        
        log WARN "Export failed on attempt $attempt"
        
        if [[ $attempt -eq ${RETRY_ATTEMPTS} ]]; then
            echo ""
            log INFO "Pool status:"
            ssh "${VM_USER}@${VM_IP}" "zpool status '$pool_name'" 2>&1 || true
            echo ""
            
            log INFO "Processes using the pool:"
            ssh "${VM_USER}@${VM_IP}" "lsof +D /tank 2>/dev/null || echo '  (none found)'"
            echo ""
            
            if [[ "${UNMOUNT_STRATEGY:-hybrid}" == "hybrid" ]]; then
                log WARN "The pool is still in use. Force export? (y/n)"
                log WARN "WARNING: Force export may cause data corruption if writes are in progress!"
                read -r response
                if [[ "$response" =~ ^[Yy]$ ]]; then
                    log WARN "Force exporting pool '$pool_name'"
                    if ssh "${VM_USER}@${VM_IP}" "zpool export -f '$pool_name'" 2>&1; then
                        log SUCCESS "Force export successful"
                        return 0
                    else
                        log ERROR "Force export failed"
                        return 1
                    fi
                else
                    log ERROR "User cancelled force export"
                    return 1
                fi
            elif [[ "${UNMOUNT_STRATEGY}" == "aggressive" ]]; then
                log WARN "Force exporting pool '$pool_name' (aggressive mode)"
                if ssh "${VM_USER}@${VM_IP}" "zpool export -f '$pool_name'" 2>&1; then
                    log SUCCESS "Force export successful"
                    return 0
                fi
            fi
            
            log ERROR "Failed to export pool '$pool_name' after $attempt attempts"
            return 1
        fi
        
        log INFO "Restarting Samba service before retry..."
        stop_samba_connections "$pool_name"
        
        log INFO "Waiting ${RETRY_DELAY}s before retry..."
        sleep "${RETRY_DELAY:-5}"
        attempt=$((attempt + 1))
    done
    
    return 1
}

check_pool_health() {
    local pool_name="$1"

    if [[ "${CHECK_POOL_HEALTH:-true}" != "true" ]]; then
        return 0
    fi

    log INFO "Checking pool health: $pool_name"

    local pool_status
    pool_status=$(ssh "${VM_USER}@${VM_IP}" "zpool status '$pool_name'" 2>&1)

    if [[ "${WARN_ON_DEGRADED:-true}" == "true" ]] && echo "$pool_status" | grep -q "state: DEGRADED"; then
        log WARN "Pool '$pool_name' is DEGRADED"
        echo ""
        log INFO "Pool Status:"
        log INFO "$pool_status"
        echo ""
    fi

    if [[ "${WARN_ON_ERRORS:-true}" == "true" ]]; then
        if echo "$pool_status" | grep -q "errors: " && ! echo "$pool_status" | grep -q "errors: No known data errors"; then
            log WARN "Pool '$pool_name' has errors"
            echo ""
            log INFO "Pool Status:"
            log INFO "$pool_status"
            echo ""
        fi
    fi

    local health=$(echo "$pool_status" | grep "state:" | awk '{print $2}')
    log INFO "Pool '$pool_name' health: $health"
}

get_pool_status() {
    local pool_name="$1"
    
    if ! check_vm_ssh; then
        echo "VM_NOT_ACCESSIBLE"
        return 1
    fi
    
    if ssh "${VM_USER}@${VM_IP}" "zpool list '$pool_name' 2>&1" | grep -q "no such pool"; then
        echo "NOT_IMPORTED"
        return 0
    fi
    
    local health
    health=$(ssh "${VM_USER}@${VM_IP}" "zpool status '$pool_name' | grep 'state:' | awk '{print \$2}'" 2>/dev/null || echo "UNKNOWN")
    echo "$health"
}

get_pool_capacity() {
    local pool_name="$1"
    
    if ! check_vm_ssh; then
        echo "N/A"
        return 1
    fi
    
    ssh "${VM_USER}@${VM_IP}" "zpool list -H -o capacity,size,allocated '$pool_name' 2>/dev/null || echo 'N/A N/A N/A'"
}

# Samba Management Functions

ensure_samba_running() {
    log INFO "Checking Samba service"

    local samba_status
    samba_status=$(ssh "${VM_USER}@${VM_IP}" "rc-service samba status" 2>&1 || echo "stopped")

    if echo "$samba_status" | grep -q "started"; then
        log INFO "Samba is already running"
        ssh "${VM_USER}@${VM_IP}" "rc-service samba restart" 2>&1 || {
            log WARN "Failed to restart Samba, but continuing"
        }
    else
        log INFO "Starting Samba service"
        ssh "${VM_USER}@${VM_IP}" "rc-service samba start" 2>&1 || {
            log ERROR "Failed to start Samba"
            return 1
        }
    fi

    sleep "${SAMBA_STARTUP_DELAY:-3}"
    log SUCCESS "Samba service is running"
}

stop_samba_connections() {
    local pool_name="$1"
    
    log INFO "Checking Samba connections for pool: $pool_name"
    
    local connections
    connections=$(ssh "${VM_USER}@${VM_IP}" "smbstatus --shares 2>/dev/null | grep -i '$pool_name' || true")
    
    if [[ -n "$connections" ]]; then
        log INFO "Active Samba connections found, restarting Samba service"
        ssh "${VM_USER}@${VM_IP}" "rc-service samba restart" 2>&1 || {
            log WARN "Failed to restart Samba, but continuing"
        }
        sleep 2
    else
        log INFO "No active Samba connections"
    fi
}

# macOS Mount Management Functions

mount_samba_share() {
    local pool_name="$1"
    local samba_share="$2"
    local mount_point="${MOUNT_BASE}/${pool_name}"

    log INFO "Mounting Samba share: //$VM_IP/$samba_share"

    if mount | grep -q "on $mount_point"; then
        log WARN "Already mounted at $mount_point"
        return 0
    fi

    local smb_url="smb://${SAMBA_USER}@${VM_IP}/${samba_share}"

    log INFO "Mounting via Finder protocol..."
    if ! osascript -e "mount volume \"$smb_url\"" 2>&1; then
        log ERROR "Failed to mount Samba share"
        return 1
    fi

    sleep 2

    local actual_mount
    actual_mount=$(mount | grep "$VM_IP.*$samba_share" | awk '{print $3}' | head -1)

    if [[ -z "$actual_mount" ]]; then
        log ERROR "Mount command succeeded but mount point not found"
        return 1
    fi

    if ! ls "$actual_mount" &>/dev/null; then
        log ERROR "Cannot access mounted share at $actual_mount"
        return 1
    fi

    log SUCCESS "Mounted at: $actual_mount"
    return 0
}

unmount_samba_share() {
    local mount_point="$1"
    local pool_name="$2"
    local attempt=1
    
    log INFO "Unmounting Samba share: $mount_point"
    
    if ! mount | grep -q "$mount_point"; then
        log INFO "Share not mounted at $mount_point"
        return 0
    fi
    
    while [[ $attempt -le ${RETRY_ATTEMPTS:-3} ]]; do
        log INFO "Unmount attempt $attempt/${RETRY_ATTEMPTS}"
        
        if diskutil unmount "$mount_point" 2>&1; then
            log SUCCESS "Successfully unmounted $mount_point"
            return 0
        fi
        
        log WARN "Unmount failed on attempt $attempt"
        
        if [[ $attempt -eq ${RETRY_ATTEMPTS} ]]; then
            echo ""
            log INFO "Processes using $mount_point:"
            lsof "$mount_point" 2>/dev/null || log INFO "  (none found)"
            echo ""
            
            if [[ "${UNMOUNT_STRATEGY:-hybrid}" == "hybrid" ]]; then
                log WARN "The share is still in use. Force unmount? (y/n)"
                read -r response
                if [[ "$response" =~ ^[Yy]$ ]]; then
                    log WARN "Force unmounting $mount_point"
                    if diskutil unmount force "$mount_point" 2>&1; then
                        log SUCCESS "Force unmount successful"
                        return 0
                    else
                        log ERROR "Force unmount failed"
                        return 1
                    fi
                else
                    log ERROR "User cancelled force unmount"
                    return 1
                fi
            elif [[ "${UNMOUNT_STRATEGY}" == "aggressive" ]]; then
                log WARN "Force unmounting $mount_point (aggressive mode)"
                if diskutil unmount force "$mount_point" 2>&1; then
                    log SUCCESS "Force unmount successful"
                    return 0
                fi
            fi
            
            log ERROR "Failed to unmount $mount_point after $attempt attempts"
            return 1
        fi
        
        log INFO "Waiting ${RETRY_DELAY}s before retry..."
        sleep "${RETRY_DELAY:-5}"
        attempt=$((attempt + 1))
    done
    
    return 1
}

find_mounted_shares() {
    mount | grep "$VM_IP" | awk '{print $3}' || true
}

check_mount_status() {
    local pool_name="$1"
    local samba_share="$2"
    
    local mount_point_pool="${MOUNT_BASE}/${pool_name}"
    local mount_point_share="${MOUNT_BASE}/${samba_share}"
    
    if mount | grep -q "on $mount_point_pool "; then
        echo "$mount_point_pool"
        return 0
    elif mount | grep -q "on $mount_point_share "; then
        echo "$mount_point_share"
        return 0
    else
        echo "NOT_MOUNTED"
        return 1
    fi
}

check_remaining_mounts() {
    local mounts
    mounts=$(find_mounted_shares)
    
    if [[ -n "$mounts" ]]; then
        return 1
    else
        return 0
    fi
}

# Utility Functions

get_pool_from_mount() {
    local mount_point="$1"
    basename "$mount_point"
}
