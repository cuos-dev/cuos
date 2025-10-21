# CuOS Development Guide: Creating Custom Operating Systems

This guide will help you create your own operating system using CuOS as a foundation. Whether you need a minimal OS or a full-featured system with CuOS services, this guide covers all development paths.

## Prerequisites

- Docker installed and running
- jq installed (for JSON processing)
- Access to a container registry (for pushing/pulling images)
- Basic understanding of Docker and containerization
- Git (for version control)
- Basic understanding of Linux systems

## System layers

CuOS consistens of multiple services and containers.

![System layers](./diagrams/layer_architecture_diagram.png)

| Container | Description |
|---|---|
| `cuos-init` | Initialize the system. Setup hostname, network, file system,  |
| `cuos-api` | API for interaction with the system |
| `cuos-app` | Ensure to start App Init Container container |
| `cuos-updater` | Helper container to replace/rollback the system, kernel, initrd and boot config. Started by `cuos-api` or your application. |

## Development Variants

CuOS offers three development paths to suit different needs:

### Variant 1: Minimal Custom OS

Build your own operating system using CuOS's build tools without including the CuOS services:

- Create custom OS images using Docker
- Use CuOS's update mechanism
- Support for various platforms (x86_64, ARM64, LXC)
- Efficient A/B updates using BTRFS

[Learn more about Variant 1](variants/variant1.md)

### Variant 2: OS with CuOS Services

Use CuOS base images with API services for system management:

- Full system management API
- Built-in update mechanisms
- Network and resource monitoring
- Configuration management

[Learn more about Variant 2](variants/variant2.md)

### Variant 3: Base on CuOS System Image

Run your application in a Docker container with full CuOS integration:

- Complete application container support
- Automated updates and maintenance
- System monitoring and management
- Privileged container support with host access options

[Learn more about Variant 3](variants/variant3.md)

## Image Building and Installation

CuOS provides comprehensive tools and guides for building and deploying your system across different platforms.

### System Configuration

The system is configured through a `system.json` file. Here's a minimal example:

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

See [System JSON Configuration](common/system-json.md) for all available options.

### Building Image Files (x86_64, ARM64)

The [Building CuOS Images Guide](common/building-images.md) covers:

- Creating system images
- Platform-specific builds (x86_64, ARM64)
- Image format conversion
- Best practices for image creation

### Installation (x86_64)

The [Installation Guide](common/installation.md) provides instructions for:

- Creating installation media
- Installing on physical hardware
- Setting up virtual machines
- First boot configuration

### LXC Container Deployment

The [LXC Deployment Guide](common/lxc-deployment.md) specifically covers:

- Creating LXC container images
- Proxmox VE deployment
- General LXC usage
- Container configuration and security

## Common Development Resources

### Configuration

- [BTRFS Usage Guide](common/btrfs-usage.md)
- [CuOS API Reference](common/cuos-api.md)

## Infrastructure as Code

For deploying services on CuOS, check out our separate [cuos-iac repository](https://github.com/cuos-dev/cuos-iac/). This repository provides tools and templates for:

- Service deployment and management
- Container orchestration
- Infrastructure automation
- Configuration management

## Next Steps

1. Choose your development variant based on your needs:
   - Variant 1: For custom OS without CuOS services
   - Variant 2: For using CuOS API services
   - Variant 3: For full application container integration

2. Follow the corresponding guide and explore the common resources
3. Test your system using the provided tools
4. Deploy to your target platform (x86_64, ARM64, or LXC)
