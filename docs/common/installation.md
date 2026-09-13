# Installing CuOS

What the installer does, and how a system finds its configuration on first boot.

**To build an installer**, see
[Building an installer](https://github.com/cuos-dev/cuos-release/blob/main/docs/building-installers.md)
in `cuos-release`. "Installation" means the OS is written onto another drive
from removable media; to copy it directly onto the target's storage, see
[What a CuOS image contains](./building-images.md).

The installer is **x86 only**. For ARM64 boards such as the Raspberry Pi, write
a disk image instead.

## What the installation media contains

- A bootloader configuration
- A choice of installation target
- The system image to be installed

## First boot configuration

A freshly installed system needs a `system.json`. It is read from the **boot
partition**, which is the FAT partition labelled `boot`:

- Network settings
- Hostname
- Update sources
- The initial application container

If the file is missing or is not valid JSON, the system reports the problem and
reboots rather than starting half-configured.

See the [system.json reference](./system-json-reference.md) for the keys, and
[system.json](./system-json.md) for how a configuration is put together.

An LXC container has no boot partition and is configured differently — see
[CuOS in an LXC container](./lxc-deployment.md).

### Cloud-init

CuOS also accepts cloud-init configuration: put it on the boot partition or a
cloud-init drive, and the system applies it on first boot. It is translated into
the same `system.json` model (`system/cuos/cloud-init-to-system-json.sh`).

## Troubleshooting

| Symptom | Check |
|---|---|
| Does not boot | Firmware settings (UEFI or legacy BIOS), Secure Boot disabled, boot order, image integrity |
| Boots but no network | Network settings in `system.json`, physical connection, then the system log |
| Application container missing | Registry credentials and DNS; `cuos log` on the running system |
| Reboots shortly after starting | An invalid `system.json` on the boot partition |
