# System JSON Configuration Reference

The `system.json` file is the central configuration file for CuOS. It defines system images, update sources, network configuration, system settings, and application configuration. This file is typically stored at `/system.json` and can be provided via boot partition or cloud-init.

## Basic Structure

```json
{
  "os_image": "your-registry/your-os-image",
  "os_image_version": "1.0.0",
  "os_image_digest": "",
  "updater_image": "ghcr.io/cuos-dev/cuos-updater",
  "updater_image_version": "latest",
  "updater_image_digest": ""
}
```

## Core Configuration Options

### System Settings

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `hostname` | string | No | System hostname (auto-generated if not set) |
| `swap_size` | number | No | Swap size in GB (default: 8) |
| `custom_ca_certs` | string/array | No | Custom CA certificates in PEM format |

### Network Configuration

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `network` | array | No | Network interface configurations |
| `network[].dhcp` | boolean | No | Use DHCP for this interface |
| `network[].ip-address` | string | No | Static IP address |
| `network[].network-mask` | string | No | Network mask |
| `network[].gateway` | string | No | Gateway address |
| `network[].dns-server` | string/array | No | DNS server(s) |
| `network[].ntp-server` | string/array | No | NTP server(s) |

### Docker Configuration

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `docker_bridge_net` | string | No | Docker bridge network (default: "10.235.255.1/24") |
| `docker_net_space` | string | No | Docker network space (default: "10.235.128.0/17") |
| `docker_net_space_size` | number | No | Network size (default: 26) |

### Operating System Images

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `os_image` | string | Yes | Base OS image for x86_64 systems |
| `os_image_version` | string | Yes | Version tag of the OS image |
| `os_image_digest` | string | No | SHA256 digest for image verification |

### Platform-Specific Images

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `rpi-arm64_image` | string | No | OS image for Raspberry Pi (ARM64) |
| `rpi-arm64_image_version` | string | No | Version of the RPi image |
| `rpi-arm64_image_digest` | string | No | SHA256 digest for RPi image |
| `lxc_image` | string | No | OS image for LXC containers |
| `lxc_image_version` | string | No | Version of the LXC image |
| `lxc_image_digest` | string | No | SHA256 digest for LXC image |

### Update Configuration

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `updater_image` | string | Yes | Image for the update system |
| `updater_image_version` | string | Yes | Version of the updater |
| `updater_image_digest` | string | No | SHA256 digest for updater |

### Application Configuration

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `initial_image` | string | No | Initial application container |
| `initial_image_version` | string | No | Version of initial application |
| `initial_image_digest` | string | No | SHA256 digest for application |

## Example Configurations

### Minimal Configuration (Variant 1)
```json
{
  "os_image": "your-registry/your-os-image",
  "os_image_version": "1.0.0",
  "os_image_digest": "",
  "updater_image": "ghcr.io/cuos-dev/cuos-updater",
  "updater_image_version": "latest",
  "updater_image_digest": ""
}
```

### Full Configuration Example
```json
{
  "hostname": "cuos-system",
  "swap_size": 8,
  "network": [
    {
      "dhcp": true
    },
    {
      "dhcp": false,
      "ip-address": "192.168.1.100",
      "network-mask": "255.255.255.0",
      "gateway": "192.168.1.1",
      "dns-server": ["8.8.8.8", "8.8.4.4"],
      "ntp-server": ["pool.ntp.org"]
    }
  ],
  "docker_bridge_net": "10.235.255.1/24",
  "docker_net_space": "10.235.128.0/17",
  "docker_net_space_size": 26,
  "custom_ca_certs": [
    "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----"
  ],
  "os_image": "ghcr.io/cuos-dev/cuos-system",
  "os_image_version": "latest",
  "os_image_digest": "",
  "rpi-arm64_image": "ghcr.io/cuos-dev/cuos-system-rpi-arm64",
  "rpi-arm64_image_version": "latest",
  "rpi-arm64_image_digest": "",
  "lxc_image": "ghcr.io/cuos-dev/cuos-system-lxc",
  "lxc_image_version": "latest",
  "lxc_image_digest": "",
  "updater_image": "ghcr.io/cuos-dev/cuos-updater",
  "updater_image_version": "latest",
  "updater_image_digest": "",
  "initial_image": "your-app",
  "initial_image_version": "latest",
  "initial_image_digest": "",
  "update_registry": "ghcr.io/your-org",
  "update_registry_user": "username",
  "update_registry_password": "password"
}
```

## Image Digests

Image digests are SHA256 hashes that provide verification of image integrity. To obtain a digest:

```bash
# Using docker
docker inspect --format='{{index .RepoDigests 0}}' image:tag

# Using crane
crane digest image:tag
```

## Best Practices

1. **Version Pinning**
   - Pin specific versions instead of using "latest"
   - Use digests for critical components
   - Update versions systematically

2. **Registry Access**
   - Use secure registries
   - Implement proper authentication
   - Consider using private registries

3. **Update Strategy**
   - Test updates in development first
   - Keep previous versions available
   - Document version changes

4. **Security**
   - Remove sensitive data (passwords, tokens)
   - Use environment variables or secrets
   - Validate configuration before deployment