# What a CuOS image contains

The structure the image factory produces, and what varies per platform.

**To build one**, see
[Building disk images](https://github.com/cuos-dev/cuos-release/blob/main/docs/building-images.md)
in `cuos-release`. "Image" means the OS is copied directly onto the target's
storage; to install from removable media instead, see
[Installation](./installation.md).

## Partition layout

Two layouts exist, chosen by the target platform.

**GPT — PC-style firmware** (x86, the default):

| # | Purpose |
|---|---|
| 1 | BIOS boot partition (`bios_grub`), 1–3 MiB |
| 2 | EFI System Partition, FAT32, label `boot` |
| 3 | Root filesystem, BTRFS, label `system` |

GRUB is installed twice against the same disk — once for UEFI and once for
legacy BIOS — so one image boots on both firmware generations.

**MBR — boards booting from a FAT partition** (Raspberry Pi, Orange Pi Zero 3):

| # | Purpose |
|---|---|
| 1 | Boot partition, FAT32, label `boot` |
| 2 | Root filesystem, BTRFS, label `system` |

The BTRFS filesystem carries the `@os`, `@data` and `@swap` subvolumes; the
A/B update mechanism swaps between subvolumes, not partitions. See
[BTRFS Usage Guide](./btrfs-usage.md).

## Platform notes

Which platforms exist and how well each is supported is in
[Platform support](./platform-support.md). Two constraints that affect what you
can build:

- **Cross-architecture builds are not supported.** Build ARM images on an ARM
  machine.
- **The OS image is chosen per platform.** A configuration can carry
  `os_image` plus `<platform>_image` variants — `rpi-arm64_image`,
  `lxc_image`, and so on — each with its own `_version` and `_digest`. The
  platform-specific key wins, `os_image` is the fallback.

### Legacy Raspberry Pi (ARM32)

CuOS still contains an ARM32 build path for Raspberry Pi 1, 2 and Zero via
`system/Dockerfile.rpi-arm32`. It is intentionally limited and is best treated
as an example of how another platform can be integrated, not as a broadly
supported target.

- Debian base images cannot be used for the Pi 1 and Zero: Debian provides
  ARMv5, those boards need ARMv6. The build uses the Raspberry Pi OS
  repositories instead.
- Application containers you run must match the board: `linux/arm/v7` for the
  Pi 2, `linux/arm/v6` for the Pi 1 and Zero. Since Debian publishes no
  `linux/arm/v6` images, `linux/arm/v5` works if specified explicitly. Most
  projects publish none of these, so expect to build your own from a Debian
  `linux/arm/v5` or Alpine base.

This support may be removed once its maintenance cost outweighs the benefit.
