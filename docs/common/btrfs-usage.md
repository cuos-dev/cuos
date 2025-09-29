# Advanced BTRFS Usage in CuOS

This document explains how CuOS uses BTRFS subvolumes for system management and updates.

## Overview

CuOS uses BTRFS subvolumes instead of traditional partitions for its A/B update system. This approach provides:
- Efficient storage usage through copy-on-write (CoW)
- Atomic system updates
- Fast rollbacks
- Data persistence across updates

## System Layout

### Disk Structure

```
/dev/sdX               # Physical disk
├── partition1         # BIOS boot partition
├── partition2: boot   # EFI System Partition (ESP)
└── partition3: system # BTRFS root partition
    ├── @os            # OS subvolume
    │   └── docker     # Docker dir only used while updating
    │       ├── btrfs  # 
    │       │   ├──    # image layers as btrfs subvolumes
    │       │   └──    # use use for the OS.
    │       └── ...
    ├── @data          # Persistent data
    │   ├── docker     # System docker dir
    │   ├── log        # System logs: /var/log
    │   └── ...
    └── @swap          # For the swap file
```

GRUB is setup as boot loader for both UEFI and non-UEFI setups.

For partition switch we write two grub files and configure the default.

### Raspberry Pi

```
/dev/sdX               # Physical disk
├── partition1: boot   # /boot/firmware partition  (vfat)
└── partition2: system # BTRFS root partition (as above)
```

Boot partition has the raspbian default structure. [RaspberryPi Documentation](https://www.raspberrypi.com/documentation/computers/config_txt.html#what-is-config-txt)

For partition switch we write the subvol in cmdline.txt.

### Mount Points
```
/          → /dev/sdX3/@os/docker/btrfs/...  # Current system root
/data      → /dev/sdX3/@data           # Persistent data
/swap      → /dev/sdX3/@swap           # For the swap file
```

## Update Process

1. **Preparation**
   ```
   system_A (active)
   system_B (ready for update)
   ```

2. **During Update**
   - Docker pulls new image
   - Creates new root filesystem in inactive subvolume
   - Updates boot configuration

3. **After Update**
   ```
   system_A (old, fallback)
   system_B (new, active)
   ```
