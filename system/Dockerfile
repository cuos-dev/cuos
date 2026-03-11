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
  ## hypervisor guest tools \
  qemu-guest-agent \
  open-vm-tools \
  hyperv-daemons \
  ## cuos os dependencies \
  btrfs-progs \
  console-setup \
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
  && systemctl disable qemu-guest-agent.service \
  && systemctl disable open-vm-tools.service \
  && systemctl disable hv-kvp-daemon.service \
  && systemctl disable hv-vss-daemon.service \
  && systemctl enable systemd-timesyncd.service \
  && systemctl mask ssh.socket \
  && systemctl mask sshd-keygen.service \
  && echo "Port 4222\nPermitRootLogin yes" >/etc/ssh/sshd_config.d/cuos.conf \
  && rm -f /etc/ssh/ssh_host_* \
  && echo "net.ipv4.ip_forward=1" >>/etc/sysctl.conf \
  ## Ensure persistence in /data \
  && mkdir -p /data \
  && rm -f /etc/machine-id && ln -sf /data/machine-id /etc/machine-id \
  && rm -Rf /var/log && ln -sf /data/log /var/log \
  && rm -Rf /var/lib/dhcp && ln -sf /data/dhcp /var/lib/dhcp \
  && rm -Rf /var/lib/docker && ln -sf /data/docker /var/lib/docker \
  && rm -Rf /var/lib/containerd && ln -sf /data/containerd /var/lib/containerd \
  && rm -Rf /root && ln -sf /data/root /root \
  && echo "[Journal]\nStorage=persistent\nSystemMaxUse=1G\nRuntimeMaxUse=50M\nCompress=yes\nSeal=yes\nSplitMode=uid\nSyncIntervalSec=5m\nRateLimitInterval=30s\nRateLimitBurst=1000" >/etc/systemd/journald.conf \
  && rm /etc/network/interfaces

# Install CuOS scripts (systemd required)
COPY cuos/ /usr/local/cuos/
RUN /usr/local/cuos/install.sh
