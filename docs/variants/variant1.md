# Variant 1: Minimal Custom OS

This guide explains how to create a minimal custom operating system using CuOS's build tools without including the CuOS services.

## Overview

A minimal CuOS-based system consists of:
1. A base system image (Docker container) with required system components
2. An update mechanism for safe system updates
3. Installation media (optional)

Key Features:
- Minimal OS based on Debian
- A/B partition scheme for safe updates
- BTRFS filesystem for snapshots
- Full systemd integration
- Network configuration support
- Docker runtime environment

## Step 1: Creating the Base System Image

Create a Docker image with your existing toolchain and push it to a registry. Both public and private registries are supported.

The Dockerfile must contain these essential components:
- **systemd**: As the init system and service manager
- **kernel**: Linux kernel package for your target architecture
- **initrd**: Initial ramdisk with required modules
- **btrfs**: For the root filesystem
- **network tools**: For basic network connectivity
- **docker runtime**: For container management

### Required Components Explained

1. **Init System**
   - systemd as the main init system
   - dbus for inter-process communication
   - Basic system utilities

2. **Storage and Boot**
   - BTRFS tools for filesystem management
   - Boot loader components
   - Storage device modules in initramfs

3. **Network Stack**
   - Basic network configuration tools
   - DHCP client for network setup
   - DNS resolution capabilities

4. **Container Runtime**
   - Docker CLI and daemon
   - Container security profiles
   - Basic runtime dependencies

Sample:

```dockerfile
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

ENTRYPOINT ["sh", "-c", "rm -f /.dockerenv; trap 'echo Received SIGTERM; exit 0' TERM; sleep infinity & wait"]

COPY seccomp-default.json /etc/docker/

# Pre-install initramfs-tools
RUN apt-get update && apt-get install --no-install-recommends -y \
  initramfs-tools \
  zstd \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && echo "RESUME=none" >>/etc/initramfs-tools/conf.d/resume \
  && cat >> "/etc/initramfs-tools/modules" <<'EOF'
btrfs
ahci
nvme
sd_mod
sdhci
sdhci_pci
usb_storage
mmc_block
mmc_core
sr_mod
microcode
EOF

# Install required packages
RUN apt-get update && apt-get install --no-install-recommends -y \
  ## cuos system dependencies (kernel) \
  linux-image-amd64 \
  ## cuos os dependencies \
  btrfs-progs \
  dbus \
  dbus-broker \
  docker-cli \
  docker.io \
  kbd \
  kmod \
  lsb-release \
  selinux-policy-default \
  systemd \
  systemd-sysv \
  systemd-timesyncd \
  ## network dependencies \
  hostname \
  ifupdown \
  iproute2 \
  iptables \
  isc-dhcp-client \
  isc-dhcp-common \
  openresolv \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && echo "net.ipv4.ip_forward=1" >>/etc/sysctl.conf

# Add your custom configuration and scripts here
```

See `system/Dockerfile` for working files. Be aware, that these including more cuos services (see variant 2/3).

### Building the Image

```bash
docker build -t your-registry/your-os-image:version .
```

## Step 2: Configuring the Update Mechanism

Your system does not need a `system.json` configuration, but the image-factory needs such a file, to build the image:

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

See [Documentation system.json](../common/system-json.md)


## Step 3: Building and Installing

See [Building CuOS Images](../common/building-images.md)

## Customization Points

### Adding Custom Services

Add your own systemd services in the Dockerfile:

```dockerfile
COPY your-service.service /etc/systemd/system/
RUN systemctl enable your-service.service
```

### Custom Init Scripts

Add initialization scripts that run at boot:

```dockerfile
COPY init-script.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-script.sh
```

### Package Selection

Choose the minimal set of packages required for your use case:

```dockerfile
RUN apt-get update && apt-get install --no-install-recommends -y \
  package1 \
  package2 \
  # Add more packages as needed
  && apt-get clean && rm -rf /var/lib/apt/lists/*
```

### Update Mechanism

The update system uses an A/B partition scheme for safe system updates. This allows for:
- Low-downtime updates
- Automatic rollback on failure
- Verified boot process

#### Update Process

1. System determines current active partition (A or B)
2. Downloads new image to inactive partition
3. Updates boot configuration
4. Reboots into new system
5. Verifies boot success or rolls back

Note: Instead of traditional partitions, CuOS uses BTRFS subvolumes for the A/B system layout. This provides space efficiency through copy-on-write operations and allows Docker to create new system versions directly as subvolumes. See [Advanced BTRFS Usage](../common/btrfs-usage.md) for details.

#### Update Command

```shell
docker run \
  --rm \
  --privileged \
  --device "${TARGET_DEVICE}" \
  -v /root/.docker/config.json:/root/.docker/config.json:ro \
  -v /etc/image:/etc/image:ro \
  -e "TARGET_DEVICE=${TARGET_DEVICE}" \
  ghcr.io/cuos-dev/cuos-updater:latest "${PARTITION}" "${IMAGE_VERSION}" "${IMAGE_DIGEST}"
```

Parameters:
- **TARGET_DEVICE**: Block device to update (e.g., `/dev/sda`)
- **PARTITION**: Current active partition ("A" or "B")
- **IMAGE_VERSION**: Full image reference to install
- **IMAGE_DIGEST**: SHA256 digest for verification (optional)


## Testing

1. Build the image
2. Create a test VM using the generated image
3. Verify basic functionality
4. Test the update mechanism

## Best Practices

**Security**
   - Use trusted base images
   - Always specify image digests for production
   - Build a trust chain for images (Signed updates)

## Next Steps

- Learn about [creating custom update policies](../common/update-system.md)
- Explore [advanced boot configurations](../common/boot-config.md)
- See how to [customize the installation process](../common/installation-media.md)