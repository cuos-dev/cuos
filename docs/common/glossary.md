# CuOS Glossary

Canonical terminology used across the CuOS project. Use these precise forms in documentation and commit messages.

---
## Core Concepts

| Term | Definition | Notes |
|------|------------|-------|
| CuOS | Container Update OS; system generated from a container image | Four levels of use — see the [Development Guide](../development-guide.md) |
| System Image | Docker/OCI image containing kernel, userspace, systemd, CuOS scripts | Referenced via `os_image` (arch specific overrides possible) |
| Updater Image | Image implementing update logic (pull, prepare, switch, rollback) | `updater_image` in `system.json` |
| CuOS Init App | The one container CuOS starts, and from which everything else is started; runs as `cuos-app` | Controlled by `init_image*` fields |
| `cuos-app-init` | The service that pulls and launches the CuOS Init App, and re-triggers it after updates | `system/cuos/app-init.sh` |
| A/B Subvolumes | Two BTRFS subvolume “slots” used for atomic OS updates | Implemented with `@os` roots, not literal block partitions |
| BTRFS Snapshot | Copy-on-write subvolume facilitating rollback and efficient image deployment | Foundation for update safety |
| Factory Reset | Operation removing persistent state / data to a clean baseline | Initiated via `cuos factory-reset` |
| Rollback | Revert to previous working OS subvolume if update fails | Triggered automatically or via `cuos rollback` |
| System State | Runtime status JSON (e.g. `running`, `updating`) | Accessible via `cuos state` |
| State File | `/data/state.json` persisted state metadata | Mutated by core scripts |
| Config File | `/system.json` active configuration | Source of truth after merges/patches |
| Next Config File | `/system_next.json` rollback / staging config | Swapped during updates |
| Active Slot File | `/etc/active_slot` indicating active slot name | Used by update & rollback logic |
| Trigger File | `/data/run-update` forces app container refresh | Created by API patch/update logic |
| API Socket | `/var/run/cuos.sock` UNIX domain socket for commands | JSON line based protocol |
| Resources Command | `cuos resources` JSON system metrics | CPU / memory / disk / network summary |
| Digest | SHA256 content hash of an image reference | Use for integrity & pinning |

---
## Configuration Fields (Selected)

| Field | Purpose | Example |
|-------|---------|---------|
| `os_image` | Base OS image reference | `ghcr.io/cuos-dev/cuos-system` |
| `os_image_version` | Tag of base OS image | `1.2.3` |
| `os_image_digest` | Integrity pin | `sha256:...` |
| `rpi-arm64_image` | Raspberry Pi specific OS build | `...-rpi-arm64` |
| `lxc_image` | LXC optimized OS build | `...-lxc` |
| `updater_image` | Update mechanism image | `ghcr.io/cuos-dev/cuos-updater` |
| `init_image` | CuOS Init App image | `ghcr.io/org/app` |
| `docker_net_space` | Pool for dynamic networks | `10.235.240.0/20` |
| `custom_ca_certs` | Additional trust anchors (PEM) | Inline string or array |
| `network` | Array of interface configs | DHCP or static modes |

---
## Runtime Files & Paths

| Path | Description |
|------|-------------|
| `/system.json` | Active merged configuration |
| `/system_next.json` | Previous / rollback or staged configuration |
| `/data/` | Persistent root (logs, docker, state) |
| `/data/log/` | Journald persistent logs (via symlink) |
| `/etc/image` | Current active system image reference string |
| `/etc/active_slot` | Current active slot indicator (logical A/B) |
| `/var/run/cuos.sock` | API communication socket |
| `/usr/local/cuos/` | Core CuOS scripts and helpers |

---
## Update / Lifecycle Terms

| Term | Meaning |
|------|---------|
| Prepare Phase | Pull new system image & materialize filesystem into inactive subvolume |
| Switch Phase | Update boot configuration to point to new subvolume |
| Verification | Post-boot confirmation that system reached `running` state |
| Automatic Rollback | Triggered if startup / app init fails threshold criteria |
| Patch Operation | In-place config modification without full OS image replacement |
| Config Merge | Deep object merge (new config over existing) during update / patch |

---
## Networking Terms

| Term | Meaning |
|------|---------|
| DHCP Mode | Interface acquires address automatically |
| Static Mode | Explicit `ip-address`, `network-mask`, `gateway` set |
| NTP Server | Time synchronization host list |
| DNS Server | Resolver endpoints for name resolution |

---
## Security Terms

| Term | Meaning |
|------|---------|
| Image Pinning | Using digest to avoid mutable tag ambiguity |
| Trust Chain | Combined guarantees: registry TLS + digest verification + controlled build pipeline |
| Privileged Container | Container with extended host access (e.g. device, pid, net sharing) |
| CA Bundle Injection | Adding root certs to trust store via `custom_ca_certs` |

---
## Common Abbreviations

| Abbrev | Expands To | Context |
|--------|------------|---------|
| API | Application Programming Interface | CuOS command interface |
| BTRFS | B-tree File System | Copy-on-write FS powering updates |
| ESP | EFI System Partition | Boot environment for UEFI |
| VM | Virtual Machine | Test / deployment target |
| LXC | Linux Containers | Alternative virtualization method |

---
## Naming Recommendations

- Use lowercase with dashes for files & scripts (`do-update.sh`).
- Use snake_case for internal JSON keys where already established; do not rename existing fields.
- Avoid mixing "partition" when referring to subvolumes; prefer “A/B subvolumes”.
