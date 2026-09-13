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

## Configuration Options

Every key, with its type, default and constraints, is listed in
**[the system.json reference](system-json-reference.md)**.

### Platform-specific image keys

Besides `os_image`, a configuration may carry an image per platform, named after
the platform:

| Key | Used when building for |
|---|---|
| `os_image` | any platform with no more specific key — the fallback |
| `rpi-arm64_image` | 64-bit Raspberry Pi |
| `rpi-arm32_image` | 32-bit Raspberry Pi |
| `lxc_image` | LXC container |
| `<platform>_image` | any other platform, named exactly as `platform` |

Each has the same `_version` and `_digest` companions as `os_image`. The build
tool selects `<platform>_image` and falls back to `os_image` when that key is
absent, so a single configuration can describe several targets.

These keys are not in the schema: their names depend on the platform, which a
JSON Schema property list cannot express.

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
  "init_image": "your-app",
  "init_image_version": "latest",
  "init_image_digest": "",
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
