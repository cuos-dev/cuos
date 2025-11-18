FROM docker:29.0.2-alpine3.22

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

ENTRYPOINT ["/usr/local/updater/updater.sh"]

RUN apk add --no-cache jq btrfs-progs util-linux bash

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
