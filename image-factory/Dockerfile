# SPDX-License-Identifier: Apache-2.0
FROM docker:29.5.3-alpine3.23

# WARNING: This Dockerfile is intended to be built from the parent directory.

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

ENTRYPOINT ["/create_image.sh"]

# tar: GNU tar, needed to restore xattrs when unpacking the exported rootfs.
# Busybox tar has no xattr support and would silently drop file capabilities.
# This factory runs updater/perform_update.sh, so it needs everything that
# script needs - keep this list and updater/Dockerfile's in step.
RUN apk add --no-cache \
    parted dosfstools btrfs-progs \
    gptfdisk qemu-img kpartx util-linux jq btrfs-progs bash tar

RUN apk add --no-cache \
    grub-efi grub-bios ovmf || true

COPY image-factory/create_image.sh /create_image.sh
COPY updater/*.sh /usr/local/updater/
COPY image-factory/mount_image.sh /mount_image.sh
