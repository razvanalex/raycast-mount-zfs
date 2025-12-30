# ZFS Mount Automation for macOS

Automated Raycast scripts to mount and unmount ZFS pools from USB drives using a UTM Linux VM with Samba sharing.

Features: 

- Fully automated USB device passthrough via AppleScript
- Automatic VM lifecycle management (start/stop)
- ZFS pool health monitoring
- Robust error handling with retry logic
- Smart VM shutdown (only stops if all pools unmounted)
- Graceful shutdown hook for macOS logout
- Multiple pool support

## Requirements

- macOS with Raycast installed
- UTM with Linux VM (Alpine/Ubuntu/Fedora)
- ZFS installed in VM
- Samba configured in VM
- SSH key authentication to VM (passwordless)
- USB drive with ZFS pool

> [!IMPORTANT]
> Enable "Show menu bar icon" in UTM settings for headless operation and "Prevent system from sleeping when any VM is running" to avoid random hanging of the drive while in use.


## Quick Start

1. Run the installer: `./install.sh`
2. Configure: Edit `~/.config/zfs-mount/config.env` with your settings
3. Add the scripts to Raycast
4. Use: Open Raycast and type "Mount ZFS", "Unmount ZFS", or "ZFS Status"

## Installation

### Using the Installer

```bash
./install.sh
```

The installer will:
- Create configuration directory
- Copy config template
- Detect USB devices
- Help you edit configuration
- Optionally install shutdown hook

### Manual Installation

1. **Create configuration**:

```bash
mkdir -p ~/.config/zfs-mount
cp config/config.env.example ~/.config/zfs-mount/config.env
```

2. **Find USB Device IDs**:

```bash
# With USB drive plugged in:
osascript -e 'tell application "UTM" to get properties of every usb device'
```

Note the `vendor id` and `product id`.

3. **Edit Configuration**:

Update these values inside `~/.config/zfs-mount/config.env`:

```bash
VM_NAME="ZFS-Linux"              # Your UTM VM name
VM_IP="192.168.64.2"             # Your VM IP
POOL_tank_USB_VENDOR=4184        # Your USB vendor ID
POOL_tank_USB_PRODUCT=9766       # Your USB product ID
POOL_tank_SAMBA_SHARE="ZFS_Shared"  # Your Samba share name
```

4. **Add scripts to Raycast**

5. **Test**:

- Open Raycast
- Type "ZFS Status" to check current state
- Type "Mount ZFS" to mount your pool

### Script Metadata

Each script includes metadata that Raycast uses:

- **Mount ZFS** (`mount-zfs.sh`): Mounts your ZFS pool via VM
- **Unmount ZFS** (`unmount-zfs.sh`): Safely unmounts and exports pool
- **ZFS Status** (`status-zfs.sh`): Shows detailed status of VM, USB, and pools

## Usage

### Mount ZFS Pool

**Raycast**: Type `Mount ZFS` and press Enter

**What it does**:
1. Starts VM if stopped
2. Connects USB device to VM
3. Imports ZFS pool
4. Checks pool health
5. Starts Samba
6. Mounts share on macOS

### Unmount ZFS Pool

**Raycast**: Type `Unmount ZFS` and press Enter

**What it does**:
1. Unmounts Samba share from macOS
2. Exports ZFS pool in VM
3. Disconnects USB from VM
4. Stops VM (if no other pools mounted)

### Check Status

**Raycast**: Type `ZFS Status` and press Enter

**Shows**:
- VM status (running/stopped)
- USB connection status
- Pool import status
- Pool health (ONLINE/DEGRADED)
- Mount status
- Capacity usage

## Configuration

Edit `~/.config/zfs-mount/config.env`:

```bash
# VM Settings
VM_NAME="ZFS-Linux"
VM_IP="192.168.64.2"
VM_USER="root"
VM_STARTUP_TIMEOUT=60

# Pool Configuration
POOL_tank_NAME="tank"
POOL_tank_USB_VENDOR=4184
POOL_tank_USB_PRODUCT=9766
POOL_tank_SAMBA_SHARE="ZFS_Shared"
POOL_tank_VM_MOUNT_PATH="/tank"
POOL_tank_DESCRIPTION="Main ZFS Storage"

# List of all pool names
POOL_NAMES="tank"

# Behavior Settings
UNMOUNT_STRATEGY="hybrid"    # conservative | hybrid | aggressive
VM_SHUTDOWN_MODE="smart"     # smart | always | ask
RETRY_ATTEMPTS=3
RETRY_DELAY=5

# Health Checks
CHECK_POOL_HEALTH=true
WARN_ON_DEGRADED=true
WARN_ON_ERRORS=true

# Logging
ENABLE_LOGGING=true
LOG_FILE="$HOME/Library/Logs/zfs-mount.log"
```

### Adding Multiple Pools

To add a second pool, edit config.env:

```bash
# Add second pool
POOL_backup_NAME="backup"
POOL_backup_USB_VENDOR=1234
POOL_backup_USB_PRODUCT=5678
POOL_backup_SAMBA_SHARE="ZFS_Backup"
POOL_backup_VM_MOUNT_PATH="/backup"
POOL_backup_DESCRIPTION="Backup Drive"

# Update pool list
POOL_NAMES="tank backup"
```

### Samba Configuration

Your VM should have Samba configured. Example `/etc/samba/smb.conf`:

```ini
[global]
   workgroup = LOCAL-ZFS
   server string = Alpine Local ZFS
   server role = standalone server

   # Network & Security
   hosts allow = 192.168.64.
   dns proxy = no
   host msdfs = no
   security = user
   map to guest = Bad User
   min protocol = SMB2

   # Logging
   log file = /var/log/samba/%m.log
   max log size = 50

   # MAC optimizations
   vfs objects = catia fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

[ZFS_Shared]
   path = /tank/shared
   browsable = yes
   writable = yes
   read only = no
   force group = shared
   create mask = 0777
   directory mask = 0777
```

Also, make sure to add your user that will access from MacOS to samba.

## Troubleshooting

### Viewing Logs

Check logs for detailed error messages:
```bash
tail -f ~/Library/Logs/zfs-mount.log
```

### Common Issues

**USB device not found**

Error: "USB device not found for pool 'tank'"

Solution:
- Verify device is plugged in: `diskutil list`
- Check vendor/product IDs: `osascript -e 'tell application "UTM" to get properties of every usb device'`
- Update config.env with correct IDs

**Pool won't import**

Error: "Pool 'tank' not available to import"

Solution:
- Check USB is visible in VM: `ssh root@192.168.64.2 "lsblk"`
- Verify pool exists: `ssh root@192.168.64.2 "zpool import"`
- Check ZFS modules are loaded in VM

**Mount failed**

Error: "Failed to mount Samba share"

Solution:
- Check Samba is running: `ssh root@192.168.64.2 "rc-service samba status"`
- Test manual mount: `mount_smbfs -N //guest@192.168.64.2/ZFS_Shared /tmp/test`
- Check Samba logs: `ssh root@192.168.64.2 "tail /var/log/samba/log.smbd"`

**Pool is busy / won't unmount**

Error: "Pool is still in use"

Solution:
- Close all applications accessing the mount
- Check what's using it: `lsof /Volumes/ZFS_Shared`
- The script will offer to force unmount (use with caution)

**VM won't start**

Solution:
- Check UTM is running
- Try starting VM manually via UTM app
- Verify SSH key is configured: `ssh root@192.168.64.2 echo "test"`

### Testing Components

Test individual components:

```bash
# Test VM control
osascript -e 'tell application "UTM" to start virtual machine "ZFS-Linux"'
osascript -e 'tell application "UTM" to get status of virtual machine "ZFS-Linux"'

# Test SSH
ssh root@192.168.64.2 "echo test"

# Test ZFS in VM
ssh root@192.168.64.2 "zpool import"
ssh root@192.168.64.2 "zpool list"

# Test Samba
ssh root@192.168.64.2 "rc-service samba status"

# Test USB devices
osascript -e 'tell application "UTM" to get properties of every usb device'
```

## Advanced Features

### Graceful Shutdown Hook

The shutdown hook automatically unmounts pools when you log out of macOS.

Install:
```bash
cp config/com.user.zfs-shutdown-hook.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.zfs-shutdown-hook.plist
```

Enable in config:
```bash
ENABLE_SHUTDOWN_HOOK=true
```

Uninstall:
```bash
launchctl unload ~/Library/LaunchAgents/com.user.zfs-shutdown-hook.plist
rm ~/Library/LaunchAgents/com.user.zfs-shutdown-hook.plist
```

## Architecture

```
macOS
  |-- USB Drive (ZFS pool)
  |-- UTM VM (ZFS-Linux)
  |     |-- USB passed through via AppleScript
  |     |-- ZFS pool imported
  |     |-- Samba server shares pool
  |-- Samba mount at /Volumes/ZFS_Shared
```

## How It Works

### Mount Process

1. Check if UTM VM is running, start if needed
2. Use AppleScript to connect USB device to VM
3. Wait for VM to recognize the USB device
4. Run `zpool import <pool>` in VM
5. Check pool health with `zpool status`
6. Ensure Samba service is running
7. Mount Samba share on macOS using osascript

### Unmount Process

1. Find all mounted Samba shares from the VM
2. Unmount from macOS with retry logic
3. Restart Samba to clear lingering connections
4. Run `zpool export <pool>` in VM
5. Disconnect USB device from VM
6. Stop VM if no other pools are mounted (smart mode)

## License

MIT
