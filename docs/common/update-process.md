# CuOS Update Process

This document describes the full lifecycle of a system (OS) update and in-place configuration changes (patch operations): phases, exit codes, rollback logic, and best practices.

---

## Update Mechanism Goals

| Goal | Description |
|------|-------------|
| Atomicity | New root filesystem prepared before switching |
| Fast rollback | Previous version kept untouched until verification succeeds |
| Integrity | Optional digest verification for OS / updater / app images |
| Minimal downtime | Only one short reboot for actual OS switch |
| Config independence | In-place patches without full OS replacement |

---

## Terminology

| Term | Meaning |
|------|---------|
| Update | Replace active OS subvolume with a new one (A/B switch) |
| Patch | In-place modification of fields in `system.json` (no slot change) |
| Rollback | Switch back to previous subvolume / previous config |
| Digest | SHA256 content verification hash of an image |
| Trigger file | `/data/run-update` signals app restart after change |

---

## Phases: OS Update (High-Level)

```mermaid
flowchart LR
  A[Trigger: cuos update] --> B[Validate configuration]
  B --> C[Merge: new config → /system_next.json]
  C --> D[Pull OS image (updater)]
  D --> E[Materialize new @os subvolume]
  E --> F[Write boot configuration]
  F --> G[Reboot]
  G --> H[Boot & verification]
  H --> I{Success?}
  I -- Yes --> J[Finalize: /system_next.json -> /system.json]
  I -- No --> K[Rollback to previous subvolume]
```

---

## Detailed Steps

| Step | Description | Failure reaction |
|------|-------------|------------------|
| 1. Trigger | `cuos update` with optional partial config | Invalid JSON → abort |
| 2. Validation | Schema / structure check (`check_config`) | Message + no switch |
| 3. Merge | Old config + patch → `/system_next.json` | Write failure → abort |
| 4. Pull OS image | Updater pulls new OS image (`docker pull`) | Network/registry error → retry/abort |
| 5. Subvolume prep | Create new root under inactive slot | BTRFS error → abort |
| 6. Boot switch | GRUB / cmdline switched to new subvolume | Write error → abort |
| 7. Reboot | System restarts | Boot failure → potential rollback |
| 8. Verification | App init / state sets `running` | Timeout / app fail → rollback |
| 9. Finalize | New config becomes active | On rollback old remains |

---

## Verification & Success Criteria

| Criterion | Check |
|-----------|-------|
| OS subvolume accessible | Mount succeeds (@os) |
| App container starts | `cuos-app` not in crash loop |
| State set | `cuos state` shows `running` |
| No critical log spam | `cuos log` lacks repeated `digest_check_failed` |

Failure: app doesn't start or timeout > 3600s → rollback.

---

## Patch Process (In-Place)

Flow for `cuos patch` / `cuos patch-network` / `cuos patch-hostname`:

1. Copy current active config to `/system_next.json`
2. Apply diff directly to `/system.json`
3. Re-init specific components (`init.sh --reinit ...`)
4. App restart trigger (`/data/run-update`)

No reboot required; OS slot unchanged.

---

## Rollback Conditions

| Condition | Trigger |
|-----------|--------|
| App start failure after update | Repeated container crashes |
| Update timeout | > 3600s until verification |
| Forced rollback | User action `cuos rollback` |
| Security failure (future) | Signature / digest critical mismatch |

Rollback actions:

* Restore boot configuration
* Keep or revert `/system_next.json` appropriately
* Maintain previous state info (future: explicit `rollback` state)

---

## Exit Codes (API Layer)

| Code | Meaning |
|------|---------|
| 0 | Success / update initiated |
| 1 | General error (e.g. invalid config) |
| 2 | No OS switch needed (same image) – config applied / app restart only |
| 3 | Insufficient space for update (planned return) |

> Note: Internal scripts may have other raw exit codes; API normalizes.

---

## Security Considerations

| Topic | Recommendation |
|-------|---------------|
| Trust | Use digests for OS / updater / app |
| Registry auth | Don't bake credentials into images; mount secrets securely |
| Integrity checks | Alert / abort on repeated digest mismatches (monitor logs) |
| Minimal privileges | Updater needs block device access; limit broader privileges |

---

## Data & Files

| File | Role |
|------|------|
| `/system.json` | Active configuration |
| `/system_next.json` | Staging / rollback source |
| `/etc/image` | Active OS image label |
| `/etc/active_slot` | Active slot indicator, A or B |
| `/data/run-update` | App restart trigger |
| `/data/state.json` | Runtime state |

---

## Example: Config Patch Without OS Switch

```bash
NEW_NET='{"config":{"dhcp":true},"network_id":0}'
cuos patch-network - <<< "${NEW_NET}"
# Expected: exit code 0, no reboot, app restart
```

---

## Example: OS Update (Version Change)

```bash
NEW_CFG=$(jq '.os_image_version = "1.2.4"' system.json)
cuos update - <<< "{\"config\": $NEW_CFG }"
# Expected: pull, subvolume change, reboot, state=running
```

---

## References

* `system/cuos/api.sh` – update & patch commands
* `system/cuos/do-update.sh` – low-level update steps
* `system/cuos/do-rollback.sh` – rollback logic
* `system/cuos/app.sh` – app container behavior post-update
* `docs/architecture.md` – overall architecture
* `docs/common/cuos-app-init.md` – app lifecycle details
