# SPDX-License-Identifier: Apache-2.0
FROM docker:29.5.3-alpine3.23

# WARNING: This Dockerfile is intended to be built from the parent directory.

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

ENTRYPOINT ["/create_image.sh"]

RUN apk add --no-cache \
    parted dosfstools btrfs-progs \
    gptfdisk qemu-img kpartx util-linux jq btrfs-progs bash

RUN apk add --no-cache \
    grub-efi grub-bios ovmf || true

COPY image-factory/create_image.sh /create_image.sh
COPY updater/*.sh /usr/local/updater/
COPY image-factory/mount_image.sh /mount_image.sh
