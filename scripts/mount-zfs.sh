#!/bin/bash

# Raycast Script Command Template
#
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Mount ZFS
# @raycast.mode fullOutput
#
# Optional parameters:
# @raycast.icon 💾
# @raycast.packageName ZFS Management
# @raycast.description Mount ZFS pool from USB drive via UTM VM
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
    echo "║                       ZFS Pool Mount Utility                        ║"
    echo "╚═════════════════════════════════════════════════════════════════════╝"
}

ensure_vm_running() {
    log INFO "Checking VM status..."
    local vm_status
    vm_status=$(check_vm_status)

    if [[ "$vm_status" == "stopped" ]]; then
        log INFO "VM is stopped. Starting VM..."
        if ! start_vm; then
            log ERROR "Failed to start VM. Exiting."
            exit 1
        fi
    elif [[ "$vm_status" == "started" ]]; then
        log INFO "VM is already running"
    else
        log ERROR "VM status unknown: $vm_status"
        exit 1
    fi
}

get_pool_config() {
    local pool_key="$1"
    
    local pool_name_var="POOL_${pool_key}_NAME"
    local pool_vendor_var="POOL_${pool_key}_USB_VENDOR"
    local pool_product_var="POOL_${pool_key}_USB_PRODUCT"
    local pool_samba_var="POOL_${pool_key}_SAMBA_SHARE"
    local pool_desc_var="POOL_${pool_key}_DESCRIPTION"

    echo "${!pool_name_var}"
    echo "${!pool_vendor_var}"
    echo "${!pool_product_var}"
    echo "${!pool_samba_var}"
    echo "${!pool_desc_var:-}"
}

mount_pool() {
    local pool_key="$1"
    
    local pool_config
    pool_config=($(get_pool_config "$pool_key"))
    local pool_name="${pool_config[0]}"
    local pool_vendor="${pool_config[1]}"
    local pool_product="${pool_config[2]}"
    local pool_samba="${pool_config[3]}"
    
    # Check if already mounted by looking for the VM IP and share name
    if mount | grep -q "${VM_IP}/${pool_samba}"; then
        echo "ALREADY_MOUNTED"
        return 0
    fi
    
    local device_id
    device_id=$(find_usb_device "$pool_vendor" "$pool_product" "$pool_name") || return 1
    
    connect_usb_device "$device_id" "$pool_name" >/dev/null || return 1
    
    import_zfs_pool "$pool_name" >/dev/null || return 1
    
    check_pool_health "$pool_name" >/dev/null || true
    
    ensure_samba_running >/dev/null || return 1
    
    mount_samba_share "$pool_name" "$pool_samba" >/dev/null || return 1
    
    echo "NEWLY_MOUNTED"
    return 0
}

mount_all_pools() {
    local mounted_pools=()
    local already_mounted_pools=()
    local failed_pools=()

    for pool_key in $POOL_NAMES; do
        local pool_config
        pool_config=($(get_pool_config "$pool_key"))
        local pool_name="${pool_config[0]}"
        
        local result
        result=$(mount_pool "$pool_key" 2>&1)
        local status=$?
        
        if [[ $status -eq 0 ]]; then
            if echo "$result" | grep -q "ALREADY_MOUNTED"; then
                already_mounted_pools+=("$pool_name")
            else
                mounted_pools+=("$pool_name")
            fi
        else
            failed_pools+=("$pool_name")
        fi
    done
    
    echo "${mounted_pools[*]:-}"
    echo "---"
    echo "${already_mounted_pools[*]:-}"
    echo "---"
    echo "${failed_pools[*]:-}"
}

show_mount_summary() {
    local mounted_pools=("$@")
    
    echo "╔═════════════════════════════════════════════════════════════════════╗"
    echo "║                            Mount Summary                            ║"
    echo "╚═════════════════════════════════════════════════════════════════════╝"

    if [[ ${#mounted_pools[@]} -gt 0 && -n "${mounted_pools[0]}" && "${mounted_pools[0]}" != "---" ]]; then
        log SUCCESS "Successfully mounted ${#mounted_pools[@]} pool(s):"
        for pool in "${mounted_pools[@]}"; do
            log INFO "  • $pool → ${MOUNT_BASE}/${pool}"
        done
    fi
}

show_already_mounted() {
    local already_mounted_pools=("$@")
    
    if [[ ${#already_mounted_pools[@]} -gt 0 && -n "${already_mounted_pools[0]}" && "${already_mounted_pools[0]}" != "---" ]]; then
        log INFO "Already mounted ${#already_mounted_pools[@]} pool(s):"
        for pool in "${already_mounted_pools[@]}"; do
            log INFO "  • $pool → ${MOUNT_BASE}/${pool}"
        done
    fi
}

show_mount_failures() {
    local failed_pools=("$@")
    
    if [[ ${#failed_pools[@]} -gt 0 && -n "${failed_pools[0]}" && "${failed_pools[0]}" != "---" ]]; then
        log ERROR "Failed to mount ${#failed_pools[@]} pool(s):"
        for pool in "${failed_pools[@]}"; do
            log ERROR "  • $pool"
        done
        log INFO "Check the log file for details: ${LOG_FILE:-$HOME/Library/Logs/zfs-mount.log}"
    fi
}

main() {
    show_banner
    log INFO "Starting ZFS mount process"
    
    ensure_vm_running
    
    log INFO "Mounting pools..."
    
    local results
    results=$(mount_all_pools)
    
    local mounted_line
    local already_mounted_line
    local failed_line
    mounted_line=$(echo "$results" | sed -n '1p')
    already_mounted_line=$(echo "$results" | sed -n '3p')
    failed_line=$(echo "$results" | sed -n '5p')
    
    IFS=' ' read -ra mounted_pools <<< "$mounted_line"
    IFS=' ' read -ra already_mounted_pools <<< "$already_mounted_line"
    IFS=' ' read -ra failed_pools <<< "$failed_line"
    
    show_mount_summary "${mounted_pools[@]+"${mounted_pools[@]}"}"
    show_already_mounted "${already_mounted_pools[@]+"${already_mounted_pools[@]}"}"
    show_mount_failures "${failed_pools[@]+"${failed_pools[@]}"}"
    
    if [[ ${#mounted_pools[@]} -eq 0 && ${#already_mounted_pools[@]} -eq 0 ]] || [[ -z "${mounted_pools[0]:-}" && -z "${already_mounted_pools[0]:-}" ]]; then
        log ERROR "No pools were mounted successfully"
        exit 1
    fi

    log SUCCESS "Mount process completed"
}

main
