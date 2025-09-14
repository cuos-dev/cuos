FROM docker:28.4.0-alpine3.22

# WARNING: This Dockerfile is intended to be built from the parent directory.

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

ENTRYPOINT ["/create_image.sh"]

RUN apk add --no-cache \
    parted dosfstools btrfs-progs grub-efi grub-bios \
    gptfdisk qemu-img kpartx util-linux ovmf jq btrfs-progs bash


COPY image-factory/create_image.sh /create_image.sh
COPY updater/*.sh /usr/local/updater/
COPY image-factory/mount_image.sh /mount_image.sh
