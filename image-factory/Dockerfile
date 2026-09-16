# SPDX-License-Identifier: Apache-2.0

# GRUB modules for the x86_64 boot chain. Alpine ships the i386-pc and
# x86_64-efi module directories in x86_64-only packages, so they are unpacked on
# an x86_64 stage and carried into whichever architecture this image is built
# for. Both packages hold nothing but /usr/lib/grub/<target>/ - target data, no
# host binaries - which is what makes the copy sound.
FROM --platform=linux/amd64 alpine:3.24 AS grub-x86_64
RUN apk add --no-cache grub-bios grub-efi

FROM docker:29.8.1-alpine3.24

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

# grub: grub-install, grub-mkimage, grub-bios-setup and grub-probe. These build
# and write a boot chain for any target whose modules are present, so this stage
# needs no architecture of its own - system/cuos/install-kernel-grub.sh runs
# them here in the factory, not inside the target rootfs.
RUN apk add --no-cache grub

COPY --from=grub-x86_64 /usr/lib/grub/i386-pc/ /usr/lib/grub/i386-pc/
COPY --from=grub-x86_64 /usr/lib/grub/x86_64-efi/ /usr/lib/grub/x86_64-efi/

COPY image-factory/create_image.sh /create_image.sh
# Named, not updater/*.sh: that glob also picks up perform_update.test.sh.
COPY updater/updater.sh updater/perform_update.sh updater/docker_environment.sh \
     updater/shell.sh /usr/local/updater/
COPY image-factory/mount_image.sh /mount_image.sh
