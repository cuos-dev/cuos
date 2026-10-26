# SPDX-License-Identifier: Apache-2.0
FROM docker:29.9.2-alpine3.24

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

LABEL dev.cuos.system=updater
# CuOS's own files; the packages in the image carry their own licences.
LABEL org.opencontainers.image.licenses=Apache-2.0

# One entrypoint per action, under /api/ like the CuOS Init App's hooks. The
# host starts an update without --entrypoint - the updater of an older release,
# which a downgrade runs, knows only its default - and every other action with
# --entrypoint /api/<action>, which an updater lacking it answers with 127.
ENTRYPOINT ["/api/update"]

# tar: GNU tar, needed to restore xattrs when unpacking the exported rootfs.
# Busybox tar has no xattr support and would silently drop file capabilities.
# image-factory/Dockerfile runs the same lib/update.sh - keep the two lists
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

# repo: the repository root, a named build context (--build-context repo=..)
COPY --from=repo LICENSE.txt NOTICE /usr/share/licenses/cuos/
COPY updater.sh pull.sh shell.sh /usr/local/updater/
COPY lib/ /usr/local/updater/lib/

RUN mkdir /api \
  && ln -s /usr/local/updater/updater.sh /api/update \
  && ln -s /usr/local/updater/pull.sh /api/pull
