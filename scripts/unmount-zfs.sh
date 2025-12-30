#!/bin/bash

# Raycast Script Command Template
#
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Unmount ZFS
# @raycast.mode fullOutput
#
# Optional parameters:
# @raycast.icon 💾
# @raycast.packageName ZFS Management
# @raycast.description Unmount ZFS pool and stop UTM VM
#
# @raycast.author razvanalex
# @raycast.authorURL https://github.com/razvanalex

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && cd .. && pwd )"
CONFIG_FILE="$HOME/.config/zfs-mount/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Configuration file not found at $CONFIG_FILE"
    echo "Please create the config file first."
    exit 1
fi

source "$CONFIG_FILE"
source "$SCRIPT_DIR/lib/helper.sh"


show_banner() {
    echo "╔═════════════════════════════════════════════════════════════════════╗"
    echo "║                      ZFS Pool Unmount Utility                       ║"
    echo "╚═════════════════════════════════════════════════════════════════════╝"
}

check_vm_running() {
    log INFO "Checking VM status..."
    local vm_status
    vm_status=$(check_vm_status)
    
    if [[ "$vm_status" == "stopped" ]]; then
        log WARN "VM is already stopped"
        log INFO "Nothing to unmount."
        exit 0
    elif [[ "$vm_status" != "started" ]]; then
        log ERROR "VM status unknown: $vm_status"
        exit 1
    fi
    
    log INFO "VM is running"
}

check_and_list_shares() {
    local mounted_shares
    mounted_shares=$(find_mounted_shares)
    
    if [[ -z "$mounted_shares" ]]; then
        log INFO "No ZFS shares currently mounted"
        handle_no_shares
        exit 0
    fi
    
    # Return only the mounted shares (no log output)
    echo "$mounted_shares"
}

display_found_shares() {
    local mounted_shares="$1"
    
    log INFO "Found mounted shares:"
    echo "$mounted_shares" | while read -r mount; do
        log INFO "  • $mount"
    done
}

handle_no_shares() {
    if [[ "${VM_SHUTDOWN_MODE:-smart}" == "always" ]]; then
        log INFO "Stopping VM (shutdown mode: always)..."
        stop_vm
    else
        log INFO "VM is still running. Stop it? (y/n)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            stop_vm
        else
            log INFO "VM left running"
        fi
    fi
}

find_pool_key_for_name() {
    local pool_name="$1"
    
    for key in $POOL_NAMES; do
        local name_var="POOL_${key}_NAME"
        if [[ "${!name_var}" == "$pool_name" ]]; then
            echo "$key"
            return 0
        fi
    done
    
    return 1
}

unmount_pool() {
    local mount_point="$1"
    local pool_name
    pool_name=$(get_pool_from_mount "$mount_point")
    
    local pool_key
    pool_key=$(find_pool_key_for_name "$pool_name")
    
    unmount_samba_share "$mount_point" "$pool_name" >/dev/null || return 1
    
    stop_samba_connections "$pool_name" >/dev/null || true
    
    export_zfs_pool "$pool_name" >/dev/null || return 1
    
    if [[ -n "$pool_key" ]]; then
        local vendor_var="POOL_${pool_key}_USB_VENDOR"
        local product_var="POOL_${pool_key}_USB_PRODUCT"
        local vendor="${!vendor_var}"
        local product="${!product_var}"
        
        local device_id
        device_id=$(osascript -e "tell application \"UTM\" to get id of first usb device whose vendor id is $vendor and product id is $product" 2>/dev/null || echo "")
        
        if [[ -n "$device_id" ]]; then
            disconnect_usb_device "$device_id" "$pool_name" >/dev/null || true
        fi
    fi
    
    return 0
}

unmount_all_pools() {
    local mounted_shares="$1"
    local unmounted_pools=()
    local failed_pools=()
    
    while IFS= read -r mount_point; do
        [[ -z "$mount_point" ]] && continue
        
        local pool_name
        pool_name=$(get_pool_from_mount "$mount_point")
        
        if unmount_pool "$mount_point"; then
            unmounted_pools+=("$pool_name")
        else
            failed_pools+=("$pool_name")
        fi
    done <<< "$mounted_shares"
    
    echo "${unmounted_pools[*]:-}"
    echo "---"
    echo "${failed_pools[*]:-}"
}

show_unmount_summary() {
    local unmounted_pools=("$@")
    
    echo "╔═════════════════════════════════════════════════════════════════════╗"
    echo "║                           Unmount Summary                           ║"
    echo "╚═════════════════════════════════════════════════════════════════════╝"
    
    if [[ ${#unmounted_pools[@]} -gt 0 && -n "${unmounted_pools[0]}" ]]; then
        log SUCCESS "Successfully unmounted ${#unmounted_pools[@]} pool(s):"
        for pool in "${unmounted_pools[@]}"; do
            log INFO "  • $pool"
        done
    fi
}

show_unmount_failures() {
    local failed_pools=("$@")
    
    if [[ ${#failed_pools[@]} -gt 0 && -n "${failed_pools[0]}" && "${failed_pools[0]}" != "---" ]]; then
        log ERROR "Failed to unmount ${#failed_pools[@]} pool(s):"
        for pool in "${failed_pools[@]}"; do
            log ERROR "  • $pool"
        done
        log INFO "Check the log file for details: ${LOG_FILE:-$HOME/Library/Logs/zfs-mount.log}"
        log WARN "VM will not be stopped due to unmount failures"
        return 1
    fi
    return 0
}

decide_vm_shutdown() {
    log INFO "Checking if VM should be stopped..."
    
    local should_stop=false
    
    case "${VM_SHUTDOWN_MODE:-smart}" in
        always)
            log INFO "Shutdown mode: always"
            should_stop=true
            ;;
        smart)
            if check_remaining_mounts; then
                log INFO "Shutdown mode: smart - no remaining mounts"
                should_stop=true
            else
                log INFO "Shutdown mode: smart - other pools still mounted"
                should_stop=false
            fi
            ;;
        ask)
            log INFO "Stop the VM? (y/n)"
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                should_stop=true
            fi
            ;;
    esac
    
    if [[ "$should_stop" == "true" ]]; then
        log INFO "Stopping VM..."
        stop_vm || {
            log WARN "Failed to stop VM cleanly"
        }
    else
        log INFO "VM left running"
    fi
}

main() {
    show_banner
    log INFO "Starting ZFS unmount process"
    
    check_vm_running
    
    log INFO "Finding mounted ZFS shares..."
    local mounted_shares
    mounted_shares=$(check_and_list_shares)
    
    display_found_shares "$mounted_shares"
    
    log INFO "Unmounting pools..."
    
    local results
    results=$(unmount_all_pools "$mounted_shares")
    
    local unmounted_line
    local failed_line
    unmounted_line=$(echo "$results" | head -1)
    failed_line=$(echo "$results" | tail -1)
    
    IFS=' ' read -ra unmounted_pools <<< "$unmounted_line"
    IFS=' ' read -ra failed_pools <<< "$failed_line"
    
    show_unmount_summary "${unmounted_pools[@]+"${unmounted_pools[@]}"}"
    
    if ! show_unmount_failures "${failed_pools[@]+"${failed_pools[@]}"}"; then
        exit 1
    fi
    
    decide_vm_shutdown
    
    log SUCCESS "Unmount process completed"
}

main
