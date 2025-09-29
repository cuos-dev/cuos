# CuOS LXC Container Guide

This guide explains how to create and deploy CuOS in LXC containers, with specific instructions for Proxmox VE and general LXC usage.

## Creating LXC Image

### Prerequisites
- Docker installed and running
- Access to your container registry
- `jq` installed
- Configuration file (`system.json`)

### Configuration

Create a `system.json` with LXC-specific settings:

```json
{
  "lxc_image": "your-registry/your-lxc-image",
  "lxc_image_version": "latest",
  "lxc_image_digest": "",
  "update_registry": "your-registry/",
  "update_registry_user": "username",
  "update_registry_password": "password"
}
```

### Creating the Image

Use the provided script to create an LXC container image:

```bash
./create-lxc-image.sh system.json
```

This will:
1. Pull the base LXC image
2. Configure the container
3. Create a compressed tarball (`image.tar.gz`)

## Proxmox VE Deployment

### Uploading the Image

1. Upload to Proxmox storage:
```bash
# On your build machine
scp image.tar.gz root@proxmox:/var/lib/vz/template/cache/cuos-template_1.0-1_amd64.tar.gz
```

### Creating Container

1. Via Web Interface:
   - Go to: Datacenter → Your Node → Create CT
   - Template: Select your uploaded CuOS template
   - Configure:
     - General: Set hostname and password (The password will be replaced after the first update)
     - Resources: Set memory, CPU, etc.
     - Network: Configure network settings
     - Advanced: Enable features (nesting for Docker)
     - Privileged: Both modes supported

2. Via Command Line:
```bash
pct create 100 /var/lib/vz/template/cache/cuos-template_1.0-1_amd64.tar.gz \
  --hostname cuos-container \
  --memory 2048 \
  --cores 2 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --features nesting=1 \
  --unprivileged 0
```

### Network Configuration

Example network configuration in `system.json`:
```json
{
  "network": [
    {
      "dhcp": true
    }
  ]
}
```

You can use the network configuration of proxmox, by setting no network config in system.json.

## General LXC Usage

(untested, for advanced users)

### Direct LXC Deployment

1. Import the image:
```bash
lxc image import image.tar.gz --alias cuos-base
```

2. Create and start container:
```bash
lxc launch cuos-base my-cuos
```

### Configuration Options

LXC configuration settings:
```yaml
config:
  security.nesting: "true"
  security.privileged: "true"
  linux.kernel_modules: overlay,nf_nat,ip_tables
```

### Storage Configuration

Mount points for persistent storage:
```bash
lxc config device add my-cuos data disk \
  source=/host/path \
  path=/data
```

## Update Process

The update process in LXC containers:
1. Container pulls new image version
2. Updates are applied to folder `/next`
3. Container reboots
4. Init process is replaced. It will move `/next` to `/`
4. Automatic rollback on failure

See lxc scripts in `/usr/local/cuos/` for details.

## Troubleshooting

### Common Issues

1. Docker in LXC
   - Verify nesting is enabled
   - Check kernel modules
   - Ensure privileged mode

2. Network Issues
   - Verify container has network access
   - Check DNS resolution
   - Verify proxy settings if used

3. Storage Issues
   - Check mount points

### Logs and Debugging

Access container logs:
```bash
# Proxmox
pct enter <container-id>
journalctl -f

# Direct LXC
lxc exec my-cuos -- journalctl -f
```
