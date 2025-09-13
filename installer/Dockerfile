FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

# Set entrypoint to the ISO creation script
ENTRYPOINT ["/create_iso.sh"]

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


# Install required packages
RUN apt-get update && apt-get install --no-install-recommends -y \
    btrfs-progs \
    busybox \
    cpio \
    dialog \
    dosfstools \
    grub-common \
    grub-efi-amd64-bin \
    grub-pc-bin \
    kmod \
    mtools \
    isolinux \
    linux-image-amd64 \
    selinux-policy-default \
    syslinux \
    xorriso \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY create_iso.sh /
COPY cuos-installer /etc/initramfs-tools/scripts/init-premount/cuos-installer
COPY hooks-cuos-installer /etc/initramfs-tools/hooks/cuos-installer
