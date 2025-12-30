#!/bin/bash

# Raycast Script Command Template
#
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title ZFS Status
# @raycast.mode fullOutput
#
# Optional parameters:
# @raycast.icon 💾
# @raycast.packageName ZFS Management
# @raycast.description Check status of ZFS pools and VM
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
    echo "║                        ZFS Status Overview                          ║"
    echo "╚═════════════════════════════════════════════════════════════════════╝"
}

# Data collection functions (no display, only return values)

get_vm_status_info() {
    check_vm_status
}

get_pool_mount_count() {
    local mounted_pools=0
    
    for pool_key in $POOL_NAMES; do
        local pool_name_var="POOL_${pool_key}_NAME"
        local pool_samba_var="POOL_${pool_key}_SAMBA_SHARE"
        local pool_name="${!pool_name_var}"
        local pool_samba="${!pool_samba_var}"
        
        local mount_status
        mount_status=$(check_mount_status "$pool_name" "$pool_samba")
        if [[ "$mount_status" != "NOT_MOUNTED" ]]; then
            mounted_pools=$((mounted_pools + 1))
        fi
    done
    
    echo "$mounted_pools"
}

get_total_pools() {
    local total=0
    for pool_key in $POOL_NAMES; do
        total=$((total + 1))
    done
    echo "$total"
}

# Display functions (show information, no return values)

display_vm_status() {
    local vm_status="$1"
    
    echo "┌─ VM Status ─────────────────────────────────────────────────────────┐"
    echo "│                                                                     │"
    
    case "$vm_status" in
        started)
            printf "│  Status:  %-58s│\n" "Running"
            if check_vm_ssh; then
                printf "│  SSH:     %-58s│\n" "Accessible"
            else
                printf "│  SSH:     %-58s│\n" "Not accessible"
            fi
            ;;
        stopped)
            printf "│  Status:  %-58s│\n" "Stopped"
            printf "│  SSH:     %-58s│\n" "N/A"
            ;;
        starting)
            printf "│  Status:  %-58s│\n" "Starting"
            printf "│  SSH:     %-58s│\n" "Waiting..."
            ;;
        stopping)
            printf "│  Status:  %-58s│\n" "Stopping"
            printf "│  SSH:     %-58s│\n" "N/A"
            ;;
        *)
            printf "│  Status:  Unknown (%-48s)│\n" "$vm_status"
            printf "│  SSH:     %-58s│\n" "N/A"
            ;;
    esac
    
    printf "│  Name:    %-58s│\n" "$VM_NAME"
    printf "│  IP:      %-58s│\n" "$VM_IP"
    echo "│                                                                     │"
    echo "└─────────────────────────────────────────────────────────────────────┘"
}

display_pool_vm_status() {
    local pool_name="$1"
    
    local pool_health
    pool_health=$(get_pool_status "$pool_name")
    
    case "$pool_health" in
        ONLINE)
            printf "│  Pool Status:  %-53s│\n" "ONLINE (imported)"
            ;;
        DEGRADED)
            printf "│  Pool Status:  %-53s│\n" "DEGRADED (imported)"
            ;;
        NOT_IMPORTED)
            printf "│  Pool Status:  %-53s│\n" "Not imported in VM"
            ;;
        VM_NOT_ACCESSIBLE)
            printf "│  Pool Status:  %-53s│\n" "VM not accessible"
            ;;
        *)
            printf "│  Pool Status:  %-53s│\n" "$pool_health"
            ;;
    esac
    
    if [[ "$pool_health" != "NOT_IMPORTED" && "$pool_health" != "VM_NOT_ACCESSIBLE" ]]; then
        local capacity_info
        capacity_info=$(get_pool_capacity "$pool_name")
        read -r capacity size allocated <<< "$capacity_info"
        
        if [[ "$capacity" != "N/A" ]]; then
            printf "│  Capacity:     %-53s│\n" "$capacity used ($allocated / $size)"
        fi
    fi
}

display_single_pool_status() {
    local pool_key="$1"
    local vm_status="$2"
    
    local pool_name_var="POOL_${pool_key}_NAME"
    local pool_vendor_var="POOL_${pool_key}_USB_VENDOR"
    local pool_product_var="POOL_${pool_key}_USB_PRODUCT"
    local pool_samba_var="POOL_${pool_key}_SAMBA_SHARE"
    local pool_desc_var="POOL_${pool_key}_DESCRIPTION"
    
    local pool_name="${!pool_name_var}"
    local pool_vendor="${!pool_vendor_var}"
    local pool_product="${!pool_product_var}"
    local pool_samba="${!pool_samba_var}"
    local pool_desc="${!pool_desc_var:-}"
    
    local pool_header="Pool: $pool_name"

    local header_len=${#pool_header}
    local dashes_needed=$((66 - header_len))
    local dashes=$(printf "%${dashes_needed}s")
    dashes=${dashes// /─}
    printf "┌─ %s %s┐\n" "$pool_header" "$dashes"
    echo "│                                                                     │"
    
    if [[ -n "$pool_desc" ]]; then
        printf "│  Description:  %-53s│\n" "$pool_desc"
    fi
    
    local usb_status
    usb_status=$(check_usb_device "$pool_vendor" "$pool_product") || true
    if [[ "$usb_status" == NOT_CONNECTED ]]; then
        printf "│  USB Device:   %-53s│\n" "Not connected to Mac"
    else
        printf "│  USB Device:   %-53s│\n" "$usb_status"
    fi
    
    if [[ "$vm_status" == "started" ]]; then
        display_pool_vm_status "$pool_name"
    else
        printf "│  Pool Status:  %-53s│\n" "N/A (VM not running)"
    fi
    
    local mount_status
    mount_status=$(check_mount_status "$pool_name" "$pool_samba") || true
    if [[ "$mount_status" != "NOT_MOUNTED" ]]; then
        printf "│  macOS Mount:  %-53s│\n" "$mount_status"
    else
        printf "│  macOS Mount:  %-53s│\n" "Not mounted"
    fi
    
    local samba_path="//$VM_IP/$pool_samba"
    if [[ ${#samba_path} -gt 50 ]]; then
        samba_path="${samba_path:0:46}..."
    fi
    printf "│  Samba Share:  %-53s│\n" "$samba_path"
    echo "│                                                                     │"
    echo "└─────────────────────────────────────────────────────────────────────┘"
}

display_all_pools_status() {
    local vm_status="$1"
    
    for pool_key in $POOL_NAMES; do
        display_single_pool_status "$pool_key" "$vm_status"
    done
}

display_summary() {
    local total_pools="$1"
    local mounted_pools="$2"
    
    echo "┌─ Summary ───────────────────────────────────────────────────────────┐"
    echo "│                                                                     │"
    printf "│  Total Pools:     %-50s│\n" "$total_pools"
    printf "│  Mounted Pools:   %-50s│\n" "$mounted_pools"
    
    if [[ $mounted_pools -eq $total_pools && $total_pools -gt 0 ]]; then
        printf "│  Overall Status:  %-50s│\n" "All pools mounted"
    elif [[ $mounted_pools -gt 0 ]]; then
        printf "│  Overall Status:  %-50s│\n" "Partially mounted"
    else
        printf "│  Overall Status:  %-50s│\n" "No pools mounted"
    fi
    
    echo "│                                                                     │"
    echo "└─────────────────────────────────────────────────────────────────────┘"
}

main() {
    show_banner
    
    local vm_status
    vm_status=$(get_vm_status_info)
    
    local total_pools
    total_pools=$(get_total_pools)
    
    local mounted_pools
    mounted_pools=$(get_pool_mount_count)
    
    display_vm_status "$vm_status"
    display_all_pools_status "$vm_status"
    display_summary "$total_pools" "$mounted_pools"
}

main
