#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

set -ex

# Define paths
WORKDIR="/build"
ISO_DIR="${WORKDIR}/iso"
INITRD_IMAGE="${WORKDIR}/initrd.img"

mkdir -p "${WORKDIR}" "${ISO_DIR}"

# Build initrd.img
KVER="$(basename /lib/modules/* | head -n1)"
mkinitramfs -o "${INITRD_IMAGE}" "${KVER}"

# Prepare ISO directory
mkdir -p "${ISO_DIR}/boot/grub"
mv "/boot/vmlinuz"-* "${ISO_DIR}/boot/vmlinuz"
mv "${INITRD_IMAGE}" "${ISO_DIR}/boot/initrd.img"

# Create grub config
#
# The installer keeps apparmor=0 while the system image boots with apparmor=1.
# This image is not the system image: it carries no apparmor package, so there
# is no profile to load and no apparmor.service to load one. Switching the LSM
# on here would confine nothing and could only cost an installation.
cat <<EOF >"${ISO_DIR}/boot/grub/grub.cfg"
set timeout=0
set default=0

load_video
set gfxpayload=keep

menuentry "Installer" {
    linux /boot/vmlinuz ro quiet loglevel=3 noresume apparmor=0
    initrd /boot/initrd.img
}
EOF

