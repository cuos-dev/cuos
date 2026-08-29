# CuOS Installation Guide

This guide explains how to create and use CuOS installation media, and how to install CuOS on different platforms.

"Installation" means, that it installes the OS on an other drive. To directly copy it on the target media see [Images](./building-images.md).

The installer only works on AMD64/x86_64 systems. For ARM64 systems like the Raspberry Pi, use the image writing method described in [Building CuOS Images](./building-images.md).

## Creating Installation Media

Preconditions:

  * A `system.json` configuration file (see [under the variants](../development-guide.md))
  * A Docker environment to build the installation media ON the same machine architecture as the target system. Note: Building ARM64 images on x86_64 hosts (or vice versa) is not supported

### Using the Installer Factory

Installers are built with `tool.sh` from the
[cuos-release](https://github.com/cuos-dev/cuos-release) repository, which runs
the installer factory for you:

```bash
./tool.sh installer path/to/system.json
```

The ISO is written to `./output/`, named after your configuration
(`./tool.sh name path/to/system.json` prints the name).

If you already have an installer ISO and only want to put a different
configuration on it, build from that one instead of from scratch:

```bash
./tool.sh installer --base existing-installer.iso path/to/system.json
```

This writes a **new** ISO; the base one is not modified.

### Installation Media Contents

The installation media includes:
- Boot loader configuration
- Installation media choice
- Image to be installed

## Using the Installation Media

### Direct Image Writing

For physical machines or VMs:
```bash
# Write to physical device
dd if=image.iso of=/dev/sdX bs=1M status=progress
```

### Virtual Machine Installation

1. Create a new VM
2. Attach the image as a cdrom disk
2. Attach additional disks for the OS installation
3. Configure boot options
4. Start the VM

### Physical Hardware Installation

1. Write image to storage device (e.g., USB drive)
2. Configure BIOS/UEFI settings
3. Boot from the device

## First Boot Configuration

### System Configuration

Place a `system.json` file in the boot partition to configure:
- Network settings
- System hostname
- Update sources
- Initial applications

See [Documentation system.json](../common/system-json.md)

### Cloud-Init Integration

CuOS supports cloud-init configuration:
1. Create cloud-init configuration
2. Add to boot partition or cloud-init drive
3. System will configure on first boot

## Troubleshooting

### Common Issues

1. Boot Problems
   - Check BIOS/UEFI settings
   - Verify image integrity
   - Check boot partition configuration

2. Network Issues
   - Verify network configuration
   - Check physical connections
   - Review system logs

3. Storage Issues
   - Verify disk partitioning
   - Check filesystem integrity
   - Ensure sufficient space
