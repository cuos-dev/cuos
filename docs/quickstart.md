# CuOS Quickstart

A minimal end-to-end walkthrough to build, boot and update a CuOS based system.

> Audience: Engineers who want to try CuOS quickly (Variant 2 or 3 style) without reading all reference docs first.
>
> Prerequisites: Linux/macOS build host, Docker, `jq`, ~6 GB free disk space, a VM platform (QEMU/VirtualBox/Proxmox) or spare USB device.

---

## 1. Clone & Inspect

```bash
git clone https://github.com/cuos-dev/cuos.git
cd cuos
```

Focus areas:

- `system/` → Base system Dockerfiles / CuOS services
- `image-factory/` → Raw disk image creation
- `installer-factory/` → (Optional) ISO installer
- `system/cuos/` → Runtime scripts (API, update, init)

---

## 2. Create a Minimal `system.json`

`system.json` drives system identity & updates. Minimal example (x86_64):

```json
{
  "os_image": "ghcr.io/cuos-dev/cuos-system",
  "os_image_version": "latest",
  "os_image_digest": "",
  "updater_image": "ghcr.io/cuos-dev/cuos-updater",
  "updater_image_version": "latest",
  "updater_image_digest": "",
  "initial_image": "docker.io/library/nginx",
  "initial_image_version": "latest",
  "initial_image_digest": ""
}
```

Place it where you will pass it into the factory scripts (e.g. `./system.json`).

> Tip: For production pin versions & use digests.

---

## 3. Build a Raw Disk Image

Use the image factory (raw BTRFS based target image):

```bash
./image-factory/start.sh ./system.json
```

Result: `./output/image.img`

---

## 4. Launch in a VM (Example: QEMU)

Raw image can be started directly; allocate enough RAM & enable UEFI if desired.

```bash
qemu-system-x86_64 \
  -m 2048 \
  -drive format=raw,file=output/image.img \
  -nographic
```

(Use another terminal with `screen`/`tmux` if no graphical console.)

Alternatively write to a USB device (DANGEROUS – ensure `of=` is correct!):

```bash
sudo dd if=output/image.img of=/dev/sdX bs=4M status=progress conv=fsync
```

---

## 5. First Boot Expectations

During first boot CuOS will:

1. Mount BTRFS subvolumes (@os, @data, @swap)
2. Initialize network (DHCP if not configured)
3. Start CuOS services (`cuos-init`, `cuos-api`, `cuos-app` logic)
4. Pull & run the `initial_image` as container `cuos-app`

Verify:

```bash
cuos version
cuos state
cuos resources
```

Check logs:

```bash
cuos log
```

Your application container (nginx in the example) should be running:

```bash
docker ps | grep cuos-app
```

---

## 6. Perform a System Update (Simulation)

Edit `system.json` locally and change `os_image_version` (or point to a forked custom image).

Example update trigger:

```bash
NEW_CONFIG=$(jq '.os_image_version = "next"' system.json)
cuos update - <<< "{\"config\": $NEW_CONFIG }"
```

Observe update flow:

- Image pull & inactive subvolume preparation
- Boot config flip
- Reboot (if required)
- Post-boot state becomes `running`

If no OS change was needed but config changed (e.g. only network):

- Update command returns exit code 0, system may not reboot
- Config applied in-place, app container may restart

Rollback (if you want to test):

```bash
cuos rollback
```

---

## 7. Patch Configuration Without Full Update

Patch hostname:

```bash
echo '"my-host"' | cuos patch-hostname -
```

Patch network adapter 0 to DHCP:

```bash
cat <<EOF | cuos patch-network -
{
  "network_id": 0,
  "config": { "dhcp": true }
}
EOF
```

---

## 8. Replace / Update the Application Container

Touch the trigger file or patch config:

```bash
touch /data/run-update
systemctl restart cuos-app.service
```

Or change `initial_image_version` via update or patch.

Inside the OS your app container can request system info through the socket (see API reference):
`/var/run/cuos.sock`

---

## 9. Factory Reset (Destructive)

```bash
cuos factory-reset
```

This schedules asynchronous reset (logs in `/data/log/factory-reset.log`).

---

## 10. Clean Shutdown / Reboot

```bash
cuos reboot
cuos shutdown
```

---

## What Next?

- Read the **Glossary** (`docs/common/glossary.md`) to align terminology.
- Explore `system/cuos/api.sh` for full command list.
- Dive into BTRFS layout (`docs/common/btrfs-usage.md`).
- Learn more about the App Init Container concept (`docs/common/cuos-app-init.md`).

---

## Troubleshooting Quick Hints

| Symptom | Quick Check |
|---------|-------------|
| App not starting | `journalctl -u cuos-app.service -b` |
| Update stuck | `cuos log` last events; network / DNS? |
| Network dead | Validate config, try DHCP patch |
| Wrong version | `cat /etc/image` vs config intention |

For deeper guidance (planned): `docs/common/troubleshooting.md`.

---

## Security Notes (Short Version)

- Pin versions / use digests for critical images.
- Restrict registry credentials (avoid embedding secrets in immutable images).
- Limit privileged flags in the app container unless strictly needed.

---

## Conceptual Model (Very Short)

```text
Boot → systemd → cuos-init → (config apply) → cuos-api socket → cuos-app-init (pull/run app) → steady state
Update: cuos update → prepare new @os → boot switch → verify → old becomes rollback target
```

---

## Minimal Mental Checklist

- Have system.json? ✔
- Built image? ✔
- Booted & reached running state? ✔
- App container started? ✔
- Update path validated? ✔

You now have a baseline CuOS workflow running.
