# SPDX-License-Identifier: Apache-2.0

# GRUB modules for the x86_64 boot chain. Alpine ships the i386-pc and
# x86_64-efi module directories in x86_64-only packages, so they are unpacked on
# an x86_64 stage and carried into whichever architecture this image is built
# for. Both packages hold nothing but /usr/lib/grub/<target>/ - target data, no
# host binaries - which is what makes the copy sound.
FROM --platform=linux/amd64 alpine:3.24 AS grub-x86_64
RUN apk add --no-cache grub-bios grub-efi

FROM docker:29.8.2-alpine3.24

# WARNING: This Dockerfile is intended to be built from the parent directory.

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

# CuOS's own files; the packages in the image carry their own licences.
LABEL org.opencontainers.image.licenses=Apache-2.0

ENTRYPOINT ["/create_image.sh"]

# tar: GNU tar, needed to restore xattrs when unpacking the exported rootfs.
# Busybox tar has no xattr support and would silently drop file capabilities.
# This factory runs updater/lib/update.sh, so it needs everything that
# script needs - keep this list and updater/Dockerfile's in step.
# mtools fills the boot filesystem without mounting it; kpartx is for
# shell.sh alone, which does mount a finished image.
RUN apk add --no-cache \
    parted dosfstools btrfs-progs mtools \
    gptfdisk qemu-img kpartx util-linux jq btrfs-progs bash tar

# grub: grub-mkimage builds the boot chain for any target whose modules are
# present, so this stage needs no architecture of its own.
RUN apk add --no-cache grub

COPY --from=grub-x86_64 /usr/lib/grub/i386-pc/ /usr/lib/grub/i386-pc/
COPY --from=grub-x86_64 /usr/lib/grub/x86_64-efi/ /usr/lib/grub/x86_64-efi/

COPY LICENSE.txt NOTICE /usr/share/licenses/cuos/
COPY image-factory/create_image.sh /create_image.sh
COPY updater/lib/ /usr/local/updater/lib/
COPY image-factory/shell.sh /shell.sh
COPY image-factory/lib/ /usr/local/image-factory/lib/
# The path cuos-release/tool.sh pins as its entrypoint for 'tool.sh shell'. It
# can go once no pinned tool.sh asks for it any more.
RUN ln -s /shell.sh /mount_image.sh
