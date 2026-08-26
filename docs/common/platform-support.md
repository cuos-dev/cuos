# Platform and Architecture Support

This document describes the current platform model used by CuOS and the constraints that apply when adding support for embedded boards.

## Supported targets today

CuOS currently supports the following families:

- x86_64 / amd64 system images
- ARM64 Raspberry Pi images (Raspberry Pi 3, 4, 5 and Zero 2)
- LXC container deployment
- Legacy ARM32 Raspberry Pi images for Raspberry Pi 1, Raspberry Pi 2, and Raspberry Pi Zero
- Board-specific image builds for selected ARM SoC platforms

The exact level of support differs by platform. Some targets are full first-class image targets, while others are compatibility or integration paths kept as examples for future platform support.

## Raspberry Pi ARM32 support

The ARM32 Raspberry Pi path is deliberately limited and should be treated as a legacy compatibility target.

### Constraints

- Debian base images cannot be used directly for Raspberry Pi 1 and Zero because Debian only provides ARMv5 support, while those boards require ARMv6-compatible images. The build uses the Raspberry Pi OS repositories as the base source for the ARM32 target.
- If you want to run docker images, they must match the board architecture: Raspberry Pi 2: `linux/arm/v7`, Raspberry Pi 1 and Zero: `linux/arm/v6`. As debian does not have `linux/arm/v6` images, you can use `linux/arm/v5` by specifing the platform explicitly. As most projects no longer provide any of those architectures, you would need to create custom images for your platform, basing on Debian `linux/arm/v5` or on alpine.

This support may be removed in the future once the maintenance burden outweighs the benefit. The intention is to keep the platform available for now so developers can understand how a non-mainstream architecture can be integrated into the CuOS build flow.


## Orange Pi Zero 3 support

The Orange Pi Zero 3 path is based on Armbian and is a good example of how board-specific boot components are assembled.

For this platform, booting Linux requires more than just a root filesystem image. The minimal boot chain is:

1. A board-specific kernel built for the target SoC
2. The matching device tree blob (DTB) for that exact board
3. A bootloader, here U-Boot

In other words, a system image for an ARM board is not simply a standard rootfs plus a generic kernel. The board-specific boot layout and offsets must match the bootloader expectations.

### Why the images are board-specific

Because U-Boot expects a known partition layout and fixed offsets, the generated image is specific to the board it was created for. For the Orange Pi Zero 3, the image is currently tuned for that exact hardware.

This is not conceptually difficult to extend, but it does require a clear mapping between:

- the target board model
- the matching DTB
- the correct kernel package or image
- the board-specific U-Boot configuration and offsets

## Design direction for future board support

The long-term design goal is to separate the OS image from the board-specific boot configuration.

A possible abstraction is:

- a Docker image that defines the OS content and package set
- a board metadata layer that describes the supported boards
- a generation step that creates board-specific image artifacts from the same base image

In this model, a single Docker image could support multiple boards, and the build logic would generate the correct board-specific output for each target.

This would make it feasible to add more supported boards without duplicating the whole OS definition. The board-specific pieces remain small and explicit: kernel, DTB, U-Boot, and boot offsets.

## LXC and virtualized targets

CuOS also supports LXC-based deployments and container-oriented targets. These are separate from bare-metal board images and usually do not require the same bootloader and DTB handling as embedded hardware targets.

