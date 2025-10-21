# CuOS Architecture

This document provides a technical overview of CuOS: components, data flows and lifecycle.

Audience: engineers, integrators, DevOps/SRE.

---

## Overview

CuOS defines the operating system as a container image. Updates create new root filesystems (BTRFS subvolumes) and switch atomically via boot configuration.

Core building blocks:

| Layer | Component | Responsibility |
|-------|-----------|----------------|
| Boot | Firmware / GRUB | Load kernel + initramfs, select active root subvolume (@os) |
| Base OS | System image (`os_image`) | Kernel, systemd, CuOS scripts |
| Init | `cuos-init` (script + systemd service) | Apply `system.json` (hostname, network, CA, Docker setup) |
| API Layer | `cuos-api` (`api.sh`, socket) | Commands: update, rollback, patch-*, resources, state |
| App Layer | `cuos-app` (Application Init Container) | Validate & run `initial_image` workload |
| Update Layer | Updater image (`updater_image`) | Prepare new subvolume + boot switch, digest checks |
| Persistence | BTRFS subvolumes `@os`, `@data`, `@swap` | Separate replaceable system from stable data |
| Config files | `/system.json`, `/system_next.json` | Active vs staged (rollback) configuration |
| Status files | `/data/state.json`, `/etc/partition_mode` | Runtime state + active slot indicator |

---

## Directory & Path Reference

| Path | Meaning |
|------|---------|
| `/usr/local/cuos/` | CuOS scripts (install, update, API, init) |
| `/etc/image` | Current system image reference |
| `/etc/partition_mode` | Logical slot (A/B) |
| `/system.json` | Active configuration |
| `/system_next.json` | Staging / rollback configuration |
| `/data/` | Persistent data (logs, docker, state) |
| `/var/run/cuos.sock` | API socket (single-line JSON protocol) |
| `/data/run-update` | Trigger file for application restart |

---

## Boot Sequence (High-Level)

```mermaid
sequenceDiagram
  participant FW as Firmware
  participant GRUB
  participant Kernel
  participant Initramfs
  participant systemd
  participant cuosInit as cuos-init
  participant cuosApi as cuos-api
  participant cuosApp as cuos-app

  FW->>GRUB: Transfer control
  GRUB->>Kernel: Load kernel + initramfs (slot @os active)
  Kernel->>Initramfs: Basic hardware init
  Initramfs->>systemd: Start PID 1
  systemd->>cuosInit: Apply config (hostname, network, CA, docker)
  cuosInit->>cuosApi: Activate API layer (socket)
  cuosApi->>cuosApp: Trigger application init
  cuosApp->>cuosApi: Optional /api/update hook finished
  cuosApi->>systemd: State = running
```

---

## Update Sequence (OS Switch)

```mermaid
sequenceDiagram
  participant User as User/API
  participant cuosApi as cuos-api
  participant Updater as updater container
  participant Docker as Docker Engine
  participant BTRFS as BTRFS
  participant BootCfg as Boot Config
  participant System as New OS Slot

  User->>cuosApi: update (config)
  cuosApi->>cuosApi: Validate + merge config → /system_next.json
  cuosApi->>Updater: Start do-update.sh
  Updater->>Docker: Pull new OS image
  Updater->>BTRFS: Create new @os subvolume (inactive)
  Updater->>BootCfg: Switch boot loader to new slot
  Updater->>cuosApi: Return success (exit code)
  cuosApi->>System: Reboot
  System->>cuosApi: Startup & verification
  cuosApi->>User: State running or rollback on failure
```

Rollback triggers: application start failures, timeout, integrity problems.

---

## Lifecycle States

| State | Meaning | Transitions |
|-------|---------|-------------|
| `starting` | Boot / startup phase | After reboot / update begin |
| `updating` | Update in progress | Set by `cuos update` + updater script |
| `running` | Normal operation | After successful verification |
| `error` | Fault state / failed startup | May lead to rollback |

The state file is modified by helper functions (see `api.sh`).

---

## A/B Mechanism on BTRFS

Instead of physical A/B partitions CuOS uses two subvolume slots. Advantages:

* Copy-on-write duplicates only changed blocks
* Fast creation of new root filesystem versions
* Rollback via boot configuration switch
* Persistent data (logs, docker layers, app state) stays in `@data`

---

## Configuration Flow

1. Base `system.json` merged with update payload (patch / update)
2. Result stored as `/system_next.json`
3. On update: new slot consumes `/system_next.json` → becomes new `/system.json` after successful boot
4. Rollback: swap files back

In-place patch (`cuos patch*`) modifies `/system.json` directly and keeps previous version at `/system_next.json` for potential rollback.

---

## Security (Brief)

| Area | Recommendation |
|------|----------------|
| Image integrity | Enforce digests for OS, updater, app |
| Registry access | Avoid baking credentials; use secure host secret management |
| Network | Minimal exposed ports, host network only if required |
| Privileges | App container without `--privileged`; granular capabilities |
| CA | Inject custom CA via `custom_ca_certs` & rotate regularly |

---

## References

* `system/cuos/api.sh` – API commands
* `system/cuos/app.sh` – App container lifecycle
* `image-factory/create_image.sh` – Raw image creation
* `installer-factory/create_iso.sh` – Installer ISO
* `docs/common/btrfs-usage.md` – Subvolume layout
