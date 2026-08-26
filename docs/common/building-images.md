# Building CuOS Image Files

This guide explains how to build CuOS system images for different platforms (from Docker images).

"Image" means, that it copies the OS directly on the target. To install it using a secondary media (e.g., USB stich or virtual cdrom device) see [Installer](./installation.md).

## Prerequisites

   * A `system.json` configuration file (see [under the variants](../development-guide.md))
   * A Docker environment to build the installation media ON the same machine architecture as the target system. Note: Building ARM64 images on x86_64 hosts (or vice versa) is not supported
  * Access to a container registry
 
## Image Factory

The image-factory creates bootable images with the CuOS partition scheme.

### Configuration

Create a `system.json` file with your image configuration:

```json
{
  "os_image": "your-registry/your-os-image",
  "os_image_version": "1.0.0",
  "os_image_digest": "",
  "updater_image": "ghcr.io/cuos-dev/cuos-updater",
  "updater_image_version": "latest",
  "updater_image_digest": ""
}
```

### Creating Images

```bash
./image-factory/start.sh path/to/system.json
```

The created image will be available at `./output/image.img`.

### Image Structure

The created image includes:
1. BIOS boot partition
2. EFI System Partition (ESP)
3. Root filesystem partition
   - BTRFS filesystem
   - Automatic snapshot management

For more details, see [BTRFS Usage Guide](./btrfs-usage.md).


## Platform-Specific Images

### x86_64 Systems
Standard image creation process as described above.

### Raspberry Pi (ARM64)
Use the Raspberry Pi specific image configuration:
```json
{
  "rpi-arm64_image": "your-registry/your-rpi-image",
  "rpi-arm64_image_version": "1.0.0",
  "rpi-arm64_image_digest": ""
}
```

### Legacy Raspberry Pi (ARM32)
CuOS still contains a legacy ARM32 build path for Raspberry Pi 1, Raspberry Pi 2, and Raspberry Pi Zero via `system/Dockerfile.rpi-arm32`. This support is intentionally limited and should be treated as an example of how other platforms can be integrated rather than as a broadly supported target.

Important constraints:

- Debian base images cannot be used directly for Raspberry Pi 1 and Zero because Debian only provides ARMv5 support, while those boards require ARMv6-compatible images.
- The build uses the Raspberry Pi OS repositories as the base source for the ARM32 target.
- Docker images must match the board architecture exactly:
  - Raspberry Pi 2: `linux/arm/v7`
  - Raspberry Pi 1 and Zero: `linux/arm/v6`
- Some older projects still publish Alpine or Debian images for `arm/v5` or similar legacy targets, but most upstream projects no longer provide those architectures.
- This support may be removed in the future once the maintenance burden outweighs the benefit.

The intention is to keep the platform available for now so developers can understand how a non-mainstream architecture can be integrated into the CuOS build flow.

## Image Formats and Conversion

Convert between formats using qemu-img:
```bash
# Convert to QCOW2
qemu-img convert -f raw -O qcow2 image.img image.qcow2

# Convert to VHD
qemu-img convert -f raw -O vpc image.img image.vhd
```

## Using the Image on Physical disks:

1. Write the image to a physical device (e.g., USB drive):
   ```bash
   dd if=image.img of=/dev/sdX bs=1M status=progress
   ```
2. Boot from the device and follow on-screen instructions.

Note: The first boot may take longer as the system resizes partitions and sets up the filesystem.

## Using the image on Proxmox VE

1. Upload the `image.img` to your Proxmox server.
2. Convert the raw image to a Proxmox-compatible format (e.g., QCOW2):
   ```bash
   qemu-img convert -f raw -O qcow2 image.img image.qcow2
   ```
3. Create a new VM in Proxmox without a disk.
4. Upload the converted image to the VM's disk storage:
   ```bash
   qm importdisk <VMID> image.qcow2 <STORAGE>
   ```
5. Attach the disk to the VM and configure boot options.
