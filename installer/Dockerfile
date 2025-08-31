FROM debian:trixie-slim

# Set entrypoint to the ISO creation script
ENTRYPOINT ["/create_iso.sh"]

# Install required packages
RUN apt-get update && apt-get install -y \
    initramfs-tools \
    linux-image-amd64 \
    xorriso \
    syslinux \
    isolinux \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools \
    dosfstools \
    cpio \
    busybox \
    && rm -rf /var/lib/apt/lists/*

COPY create_iso.sh /
