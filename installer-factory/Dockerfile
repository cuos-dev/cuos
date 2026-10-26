# SPDX-License-Identifier: Apache-2.0
FROM debian:13.7-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

# CuOS's own files; the packages in the image carry their own licences.
LABEL org.opencontainers.image.licenses=Apache-2.0

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
    syslinux \
    xorriso \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY installer-factory/prepare_iso.sh /
COPY installer-factory/initramfs-tools/ /etc/initramfs-tools/

RUN /prepare_iso.sh

COPY LICENSE.txt NOTICE /usr/share/licenses/cuos/
COPY installer-factory/create_iso.sh installer-factory/patch_iso.sh /
