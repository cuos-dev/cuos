# SPDX-License-Identifier: Apache-2.0
FROM debian:13.6-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

ENTRYPOINT ["/create_iso.sh"]

RUN apt-get update && apt-get install --no-install-recommends -y \
    initramfs-tools \
    zstd \
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
    isolinux \
    jq \
    kmod \
    linux-image-amd64 \
    mtools \
    pv \
    selinux-policy-default \
    syslinux \
    xorriso \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY prepare_iso.sh /
COPY initramfs-tools/ /etc/initramfs-tools/

RUN /prepare_iso.sh

COPY create_iso.sh patch_iso.sh /
