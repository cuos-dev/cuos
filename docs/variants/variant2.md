# Variant 2: OS with CuOS Services

This guide explains how to create an operating system that includes CuOS API services, enabling advanced system management capabilities while maintaining control over your application layer.

## Overview

A minimal CuOS-based system consists of:
1. A base system image (Docker container) with required system components
2. An update mechanism for safe system updates
3. API to trigger OS actions
4. Optional service to start initial application
4. Installation media (optional)

Key Features:
- Minimal OS based on Debian
- A/B partition scheme for safe updates
- BTRFS filesystem for snapshots
- Full systemd integration
- Network configuration support
- Docker runtime environment

## Step 1: Creating the System Image

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
FROM ghcr.io/cuos-dev/cuos-system:pinned_version

# Your custom configurations here
```

or

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
  ## cuos service dependencies \
  ca-certificates \
  cloud-guest-utils \
  curl \
  dialog \
  gnupg2 \
  inetutils-ping \
  jq \
  jsonschema-jv \
  less \
  pass \
  sudo \
  yq \
  ## debugging tools \
  openssh-server \
  vim \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && systemctl enable systemd-timesyncd.service \
  && echo "net.ipv4.ip_forward=1" >>/etc/sysctl.conf

# Ensure persistence
RUN  mkdir -p /data && \
  rm -f /etc/machine-id && ln -sf /data/machine-id /etc/machine-id && \
  rm -Rf /var/log && ln -sf /data/log /var/log && \
  rm -Rf /var/lib/dhcp && ln -sf /data/dhcp /var/lib/dhcp && \
  rm -Rf /var/lib/docker && mkdir -p /data/docker && ln -sf /data/docker /var/lib/docker && \
  rm -Rf /var/lib/containerd && mkdir -p /data/containerd && ln -sf /data/containerd /var/lib/containerd && \
  rm -Rf /root/.docker && mkdir -p /data/.docker && ln -sf /data/.docker /root/.docker && \
  echo "[Journal]\nStorage=persistent\nSystemMaxUse=1G\nRuntimeMaxUse=50M\nCompress=yes\nSeal=yes\nSplitMode=uid\nSyncIntervalSec=5m\nRateLimitInterval=30s\nRateLimitBurst=1000" >/etc/systemd/journald.conf && \
  rm /etc/network/interfaces && \
  mkdir -p /data/shieldor && \
  ln -sf /data/shieldor /usr/local/shieldor && \
  rm -f /etc/ssh/ssh_host_*

# Install CuOS scripts (systemd required)
COPY cuos/ /usr/local/cuos/
RUN /usr/local/cuos/install.sh

# Your custom configurations here
```

See `system/Dockerfile*` for working files.

You may add:
  * Host configuration
  * Drivers and kernel modules
  * System services, that can not run in a docker container
  * your service (consider like in [variant 3](./variant3.md) to package your service as docker image)

### Building the Image

```bash
docker build -t your-registry/your-os-image:version .
```


## Step 2: System Configuration

Create a `system.json` configuration:

```json
{
  "os_image": "your-registry/your-os-image",
  "os_image_version": "1.0.0",
  "os_image_digest": "",
  "updater_image": "ghcr.io/cuos-dev/cuos-updater/cuos-updater",
  "updater_image_version": "latest",
  "updater_image_digest": ""
}
```

See [Documentation system.json](../common/system-json.md)


## Step 3: API Services (for integration into your service)

See [CuOS API](../common/cuos-api.md)

The CuOS API provides endpoints for:
- System status monitoring
- Update management
- Configuration changes
- Network management
- Resource monitoring

In the system container, use the API with `/usr/local/cuos/api.sh ACTION`.


## Image/Installer Building and Testing

See [Building CuOS Images](../common/building-images.md)

## Best Practices

**Update Strategy**
   - Plan update procedures
   - Test rollback scenarios
   - Validate system state after updates

**Security**
   - Use trusted base images
   - Always specify image digests for production
   - Build a trust chain for images (Signed updates)

## Next Steps

- Learn about [advanced API usage](../common/api-reference.md)
- Explore [system monitoring](../common/monitoring.md)
- Set up [custom update policies](../common/update-system.md)