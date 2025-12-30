#!/bin/bash

# ZFS Mount Automation - Installation Script
# This script sets up the configuration and prepares the environment

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CONFIG_DIR="$HOME/.config/zfs-mount"
CONFIG_FILE="$CONFIG_DIR/config.env"

banner() {
    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║     ZFS Mount Automation - Installation Script         ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
}

create_config() {
    echo "Creating configuration directory..."
    mkdir -p "$CONFIG_DIR"
    echo "[OK] Created $CONFIG_DIR"
    echo ""

    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}[WARNING] Configuration file already exists at $CONFIG_FILE${NC}"
        echo "Do you want to:"
        echo "  1) Keep existing configuration"
        echo "  2) Backup and create new configuration"
        read -p "Enter choice (1 or 2): " choice
        
        if [[ "$choice" == "2" ]]; then
            BACKUP_FILE="$CONFIG_FILE.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$CONFIG_FILE" "$BACKUP_FILE"
            echo "[OK] Backed up existing config to $BACKUP_FILE"
            cp "$SCRIPT_DIR/config/config.env.example" "$CONFIG_FILE"
            echo "[OK] Created new configuration file"
        else
            echo "[OK] Keeping existing configuration"
        fi
    else
        echo "Creating configuration file..."
        cp "$SCRIPT_DIR/config/config.env.example" "$CONFIG_FILE"
        echo "[OK] Created $CONFIG_FILE"
    fi
    echo ""
}

detect_usb_devices() {
    echo "Detecting USB devices..."
    echo "Querying UTM for connected USB devices..."
    echo ""

    if osascript -e 'tell application "UTM" to get properties of every usb device' 2>/dev/null; then
        echo ""
        echo -e "${GREEN}[OK] Found USB devices above${NC}"
        echo ""
        echo "Please note the 'vendor id' and 'product id' for your ZFS drive."
    else
        echo -e "${YELLOW}[WARNING] Could not query UTM for USB devices${NC}"
        echo "  Make sure:"
        echo "  - UTM is installed and running"
        echo "  - Your USB drive is plugged in"
        echo ""
        echo "  You can check devices later with:"
        echo "  osascript -e 'tell application \"UTM\" to get properties of every usb device'"
    fi
    echo ""
}

configure_settings() {
    echo "You need to edit the configuration file with your settings:"
    echo ""
    echo "  nano $CONFIG_FILE"
    echo ""
    echo "Required settings to update:"
    echo "  - VM_NAME: Your UTM VM name (default: ZFS-Linux)"
    echo "  - VM_IP: Your VM's IP address (default: 192.168.64.2)"
    echo "  - POOL_tank_USB_VENDOR: Vendor ID from USB devices above"
    echo "  - POOL_tank_USB_PRODUCT: Product ID from USB devices above"
    echo "  - POOL_tank_SAMBA_SHARE: Your Samba share name"
    echo ""

    read -p "Would you like to edit the configuration now? (y/n): " edit_now

    if [[ "$edit_now" =~ ^[Yy]$ ]]; then
        ${EDITOR:-vi} "$CONFIG_FILE"
        echo ""
        echo "[OK] Configuration saved"
    fi
    echo ""
}

shutdown_hook() {
    echo "[Optional] Install shutdown hook..."
    echo ""
    echo "The shutdown hook automatically unmounts ZFS pools when you log out."
    echo ""
    read -p "Install shutdown hook? (y/n): " install_hook

    if [[ "$install_hook" =~ ^[Yy]$ ]]; then
        LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
        LAUNCH_AGENT_FILE="$LAUNCH_AGENT_DIR/com.user.zfs-shutdown-hook.plist"
        
        mkdir -p "$LAUNCH_AGENT_DIR"
        
        # Replace placeholders in plist
        sed -e "s|{{SCRIPT_DIR}}|$SCRIPT_DIR|g" \
            -e "s|{{HOME}}|$HOME|g" \
            "$SCRIPT_DIR/config/com.user.zfs-shutdown-hook.plist" > "$LAUNCH_AGENT_FILE"
        
        # Replace placeholders in shutdown hook script
        sed -e "s|{{SCRIPT_DIR}}|$SCRIPT_DIR|g" \
            "$SCRIPT_DIR/lib/shutdown-hook.sh" > "$SCRIPT_DIR/lib/shutdown-hook.sh.tmp"
        mv "$SCRIPT_DIR/lib/shutdown-hook.sh.tmp" "$SCRIPT_DIR/lib/shutdown-hook.sh"
        chmod +x "$SCRIPT_DIR/lib/shutdown-hook.sh"
        
        launchctl unload "$LAUNCH_AGENT_FILE" 2>/dev/null || true
        launchctl load "$LAUNCH_AGENT_FILE"
        
        echo "[OK] Shutdown hook installed and loaded"
        echo ""
    else
        echo "[SKIPPED] Shutdown hook not installed"
        echo "  You can install it later by running this install script again"
    fi
    echo ""
}

verify_vm_connection() {
    echo "Verifying VM connection..."
    echo ""

    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        
        if vm_status=$(osascript -e "tell application \"UTM\" to get status of virtual machine \"$VM_NAME\"" 2>/dev/null); then
            echo -e "${GREEN}[OK] VM '$VM_NAME' found with status: $vm_status${NC}"
            
            if [[ "$vm_status" == "started" ]]; then
                echo "  Testing SSH connection..."
                if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" "echo 'SSH OK'" 2>/dev/null; then
                    echo -e "${GREEN}[OK] SSH connection successful${NC}"
                else
                    echo -e "${YELLOW}[WARNING] SSH connection failed${NC}"
                    echo "  Make sure SSH key authentication is configured"
                fi
            else
                echo "  VM is not running. Start it to test SSH connection."
            fi
        else
            echo -e "${YELLOW}[WARNING] Could not find VM '$VM_NAME'${NC}"
            echo "  Make sure VM_NAME in config matches your UTM VM"
        fi
    fi
    echo ""
}

finalize() {
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║              Installation Complete!                    ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Make sure your configuration is correct:"
    echo "   ${EDITOR:-vi} $CONFIG_FILE"
    echo ""
    echo "2. Test the scripts in Raycast:"
    echo "   - Open Raycast (Cmd+Space or your hotkey)"
    echo "   - Type 'ZFS Status' to check current state"
    echo "   - Type 'Mount ZFS' to mount your pool"
    echo "   - Type 'Unmount ZFS' to unmount"
    echo ""
    echo "3. Check logs if you encounter issues:"
    echo "   tail -f ~/Library/Logs/zfs-mount.log"
    echo ""
    echo "For more information, see $SCRIPT_DIR/README.md "
    echo ""
}

# Main
banner
create_config
detect_usb_devices
configure_settings
shutdown_hook
verify_vm_connection
finalize
