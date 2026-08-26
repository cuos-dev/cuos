<!-- SPDX-License-Identifier: Apache-2.0 -->
# Platform and Architecture Support

This document describes the current platform model used by CuOS and the constraints that apply when adding support for embedded boards.

## Supported targets today

CuOS currently supports the following families:

- x86_64 / amd64 system images
- ARM64 Raspberry Pi images (Raspberry Pi 3, 4, 5 and Zero 2)
- LXC container deployment
- Legacy ARM32 Raspberry Pi images for Raspberry Pi 1, Raspberry Pi 2, and Raspberry Pi Zero

The exact level of support differs by platform. Some targets are full first-class image targets, while others are compatibility or integration paths kept as examples for future platform support.

## Raspberry Pi ARM32 support

The ARM32 Raspberry Pi path is deliberately limited and should be treated as a legacy compatibility target.

### Constraints

- Debian images cannot be used directly for Raspberry Pi 1 and Zero because Debian does not provide a usable ARMv6 base for those boards.
- For those boards, the build relies on the Raspberry Pi OS repositories.
- Docker images must match the target board architecture exactly:
  - Raspberry Pi 2: `linux/arm/v7`
  - Raspberry Pi 1 and Zero: `linux/arm/v6`
- Many upstream projects no longer publish images for these architectures, so compatibility depends on whether the required packages still exist for those targets.
- This support may be removed in the future if maintenance cost becomes too high.

This support remains in place so developers can understand how a non-mainstream architecture can be integrated into the CuOS build flow.

## Design direction for future board support

The long-term design goal is to separate the OS image from the board-specific boot configuration.

Booting Linux on an ARM board requires more than a root filesystem. The minimal boot chain is a board-specific kernel, the matching device tree blob (DTB) for that exact board, and a bootloader. Because a bootloader expects a known partition layout and fixed offsets, a generated image is specific to the board it was created for.

A possible abstraction is:

- a Docker image that defines the OS content and package set
- a board metadata layer that describes the supported boards
- a generation step that creates board-specific image artifacts from the same base image

In this model, a single Docker image could support multiple boards, and the build logic would generate the correct board-specific output for each target. This would make it feasible to add more supported boards without duplicating the whole OS definition. The board-specific pieces remain small and explicit: kernel, DTB, bootloader, and boot offsets.

## LXC and virtualized targets

CuOS also supports LXC-based deployments and container-oriented targets. These are separate from bare-metal board images and usually do not require the same bootloader and DTB handling as embedded hardware targets.
