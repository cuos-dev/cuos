# SPDX-License-Identifier: Apache-2.0
FROM docker:29.8.0-alpine3.24

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

LABEL dev.cuos.system=updater

ENTRYPOINT ["/usr/local/updater/updater.sh"]

# tar: GNU tar, needed to restore xattrs when unpacking the exported rootfs.
# Busybox tar has no xattr support and would silently drop file capabilities.
# image-factory/Dockerfile runs the same perform_update.sh - keep the two lists
# in step.
RUN apk add --no-cache jq btrfs-progs util-linux bash tar

# Install required packages
#RUN apt-get update && apt-get install -y \
#    docker.io \
#    iptables \
#    uidmap \
#    grub \
#    jq \
#    btrfs-progs \
#    && apt-get clean
#grub-efi-amd64 efibootmgr


## Allow systemd to run inside Docker
#VOLUME [ "/sys/fs/cgroup" ]

COPY updater.sh perform_update.sh docker_environment.sh shell.sh /usr/local/updater/
