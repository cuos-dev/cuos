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
    ├── @os            # OS subvolumes, one per slot
    │   ├── system-A   # One of the two is the running root
    │   └── system-B   # The other is the rollback target
    ├── @data          # Persistent data
    │   ├── docker     # System docker dir
    │   ├── log        # System logs: /var/log
    │   └── ...
    └── @swap          # For the swap file
```

GRUB is setup as boot loader for both UEFI and non-UEFI setups.

For a slot switch we write two GRUB files and configure the default.

### Raspberry Pi

```
/dev/sdX               # Physical disk
├── partition1: boot   # /boot/firmware partition  (vfat)
└── partition2: system # BTRFS root partition (as above)
```

Boot partition has the raspbian default structure. [RaspberryPi Documentation](https://www.raspberrypi.com/documentation/computers/config_txt.html#what-is-config-txt)

For a slot switch we write the subvol in `cmdline.txt`.

### Mount Points
```
/          → /dev/sdX3/@os/system-A    # Current system root, A or B
/data      → /dev/sdX3/@data           # Persistent data
/swap      → /dev/sdX3/@swap           # For the swap file
```

The slot is written into `/etc/fstab` as `subvol=@os/system-A` and onto the
kernel command line as `rootflags=subvol=…`, so a slot switch is a boot
configuration change and nothing else.

## Update Process

1. **Preparation**
   ```
   system-A (active)
   system-B (ready for update)
   ```

2. **During Update**
   - Docker pulls new image
   - Creates the new root as a fresh subvolume in the inactive slot
   - Updates boot configuration

3. **After Update**
   ```
   system-A (old, fallback)
   system-B (new, active)
   ```
