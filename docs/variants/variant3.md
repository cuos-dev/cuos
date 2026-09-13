# Variant 3: Base on CuOS System Image

This guide explains how to use your CuOS base images. You provide and run your application in a docker container. Be aware, that it is possible, to just use this as packaging, as you can run docker containers priviledged and even with host shared pid and network space.

## Overview

A full CuOS system includes:
1. Base system image with complete CuOS integration
2. Application container management
3. Automated update and maintenance features


## Step 1: System Configuration

Create a comprehensive `system.json` configuration:

```json
{
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
  "init_image_digest": ""
}
```

See [Documentation system.json](../common/system-json.md)

## Step 2: Application Container Setup

### Creating the Application Container

1. Create your application container:

```dockerfile
FROM your-base-image

# Your application setup
COPY app /app

```

2. Build and push the application:

```bash
docker build -t your-registry/your-app:version .
docker push your-registry/your-app:version
```

## Step 3: Using API Services in your service

See [CuOS API](../common/cuos-api.md)

The CuOS API provides endpoints for:
- System status monitoring
- Update management
- Configuration changes
- Network management
- Resource monitoring


## Building and Testing

See [Building CuOS Images](../common/building-images.md)

## Best Practices

**Application Design**
   - Design for container environment
   - Implement proper shutdown handling
   - Use CuOS APIs for system interaction

**Update Strategy**
   - Plan update procedures
   - Test rollback scenarios
   - Validate system state after updates

**Security**
   - Use trusted base images
   - Always specify image digests for production
   - Build a trust chain for images (Signed updates)

## Next Steps

- Learn about [advanced system configuration](../common/system-config.md)
- Explore [application integration patterns](../common/app-integration.md)
- Set up [monitoring and logging](../common/monitoring.md)
- Implement [custom maintenance tasks](../common/maintenance.md)
