FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

ENTRYPOINT ["sh", "-c", "rm -f /.dockerenv; trap 'echo Received SIGTERM; exit 0' TERM; sleep infinity & wait"]

COPY seccomp-default.json /etc/docker/

# Pre-install initramfs-tools
RUN apt-get update && apt-get install --no-install-recommends -y \
  initramfs-tools \
  zstd \
  && echo "btrfs" >>/etc/initramfs-tools/modules \
  && echo "ahci" >>/etc/initramfs-tools/modules \
  && echo "nvme" >>/etc/initramfs-tools/modules \
  && echo "sd_mod" >>/etc/initramfs-tools/modules \
  && echo "sdhci" >>/etc/initramfs-tools/modules \
  && echo "sdhci_pci" >>/etc/initramfs-tools/modules \
  && echo "usb_storage" >>/etc/initramfs-tools/modules \
  && echo "mmc_block" >>/etc/initramfs-tools/modules \
  && echo "mmc_core" >>/etc/initramfs-tools/modules \
  && echo "sr_mod" >>/etc/initramfs-tools/modules \
  && echo "microcode" >>/etc/initramfs-tools/modules \
  && echo "RESUME=none" >>/etc/initramfs-tools/conf.d/resume \
  && apt-get clean && rm -rf /var/lib/apt/lists/*


# Optional: force initramfs to include busybox and essential tools
#RUN echo "BUSYBOX=y" >>/etc/initramfs-tools/initramfs.conf

# Install required packages
RUN apt-get update && apt-get install --no-install-recommends -y \
  btrfs-progs \
  busybox \
  ca-certificates \
  cloud-guest-utils \
  curl \
  dbus \
  dbus-broker \
  dialog \
  docker-cli \
  docker.io \
  gnupg2 \
  inetutils-ping \
  jq \
  jsonschema-jv \
  kbd \
  kmod \
  less \
  linux-image-amd64 \
  openssh-server \
  pass \
  selinux-policy-default \
  sudo \
  systemd \
  systemd-sysv \
  systemd-timesyncd \
  vim \
  yq \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && systemctl enable systemd-timesyncd.service

# Install network services
RUN apt-get update && apt-get install --no-install-recommends -y \
  hostname \
  ifupdown \
  iproute2 \
  iptables \
  isc-dhcp-client \
  isc-dhcp-common \
  openresolv \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
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

# Set up SSH
RUN echo 'root:root' | chpasswd && \
  sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

