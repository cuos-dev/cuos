# CuOS – Container Update OS

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE.txt)

🚀 **An operating system that is a container image.** You build it with a
Dockerfile, ship it through a registry, and update it by replacing the image —
the whole root filesystem at once, with an automatic rollback if the new one
does not come up.

To turn one into a bootable system, start at
[cuos-release](https://github.com/cuos-dev/cuos-release#readme).

## What it is

CuOS unpacks that image into one of two BTRFS subvolumes. An update pulls the
new image, materialises it into the inactive slot, flips the boot configuration
and reboots; if the system does not reach a running state, it goes back to the
slot it came from. Data lives in a subvolume of its own that updates never
touch.

What makes it worth doing this way is that none of it is a new skill:

- **Your Dockerfile is the OS definition.** Add a package, rebuild, ship.
- **Your registry is the update server.** No separate update infrastructure,
  no package repository to run.
- **Your CI already builds it.** It is a container build like any other.
- **A failed update is not a dead device.** The previous slot is untouched
  until the new one has proven it boots.
- **One file configures a system.** `system.json` carries hostname, network,
  images and their digests — the same file that built the artefact.

Built for devices you do not stand in front of: edge, kiosks, embedded products
and VMs, one machine or a fleet.

## Where to start

| You want to… | Go to |
|---|---|
| build a bootable system — disk image, ISO installer or LXC container | [cuos-release](https://github.com/cuos-dev/cuos-release#readme) |
| deploy and manage services on one | [cuos-iac](https://github.com/cuos-dev/cuos-iac#readme) |
| build your own OS or init app on CuOS | [Development Guide](docs/development-guide.md) |
| see the pieces working end to end | [Quickstart](docs/quickstart.md) |

The name is the description: **C**ontainer **U**pdate **OS** — built from a
container, updates itself, and is a whole operating system rather than a runtime
on top of one.

## Supported platforms

| Platform | Boards / form factor | Docker platform | Support level |
|---|---|---|---|
| x86_64 | BIOS and UEFI machines, VMs | `linux/amd64` | Supported |
| LXC | Containers on an LXC host | `linux/amd64` | Supported |
| Raspberry Pi 64-bit | Pi 3, Pi 4, Pi 5, Zero 2 | `linux/arm64` | Supported |
| Raspberry Pi 32-bit | Pi 1, Pi 2, Zero | `linux/arm/v6` | Legacy — may be removed |
| Orange Pi Zero 3 | Orange Pi Zero 3 only | `linux/arm64` | Example — that board only |

**32-bit Raspberry Pi** is a legacy compatibility target. The image is built for
`linux/arm/v6`, so a single image covers Pi 1, Pi 2 and Zero. Debian provides no
usable ARMv6 base for these boards, so this target is built from the Raspberry
Pi OS repositories instead. Note that most upstream projects no longer publish
32-bit ARM images at all — CuOS may boot while the application containers you
want do not exist for the board. This support may be removed in a future
release.

**Orange Pi Zero 3** is kept as a worked example of a board-specific boot chain
— kernel, device tree blob (DTB) and U-Boot at fixed image offsets — rather than
as a ready-made target. An image is published as `cuos-system-orangepi-zero3`,
but it is tuned for that exact board and will not boot on anything else.

See [Platform and Architecture Support](docs/common/platform-support.md) for the
boot chains, the constraints behind these levels, and what adding a new board
involves.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions need a Developer
Certificate of Origin sign-off (`git commit -s`, see [DCO.txt](DCO.txt)).

## License

Apache-2.0 — see [LICENSE.txt](LICENSE.txt) and [NOTICE](NOTICE). Each source
file carries an `SPDX-License-Identifier` line.
No warranty; see [DISCLAIMER.md](DISCLAIMER.md).
