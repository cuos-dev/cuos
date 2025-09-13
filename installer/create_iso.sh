#!/bin/bash
set -e
set -x

# Define paths
WORKDIR="/build"
OUTPUT_DIR="/output"
ISO_DIR="${WORKDIR}/iso"
INITRD_IMAGE="${WORKDIR}/initrd.img"

if [[ ! -d "${OUTPUT_DIR}" ]]; then
	echo "Build dir does not exist."
	exit 2
fi


rm -f "${OUTPUT_DIR}/installer.iso"

# Prepare initramfs-tools config
mkdir -p "/etc/initramfs-tools/conf.d"

# Add required modules
cat <<EOF >"/etc/initramfs-tools/modules"
btrfs
ahci
nvme
sd_mod
sdhci
sdhci_pci
usb_storage
mmc_block
mmc_core
sr_mod
microcode
EOF

# Disable resume
echo "RESUME=none" > "/etc/initramfs-tools/conf.d/resume"

mkdir -p "${WORKDIR}" "${ISO_DIR}"

# Build initrd.img
KVER="$(basename /lib/modules/* | head -n1)"
mkinitramfs -o "${INITRD_IMAGE}" "${KVER}"

# Prepare ISO directory
mkdir -p "${ISO_DIR}/boot/grub"
cp "/boot/vmlinuz"-* "${ISO_DIR}/boot/vmlinuz"
cp "${INITRD_IMAGE}" "${ISO_DIR}/boot/initrd.img"
cp "/output/image.img" "${ISO_DIR}"

# Create grub config
cat <<EOF >"${ISO_DIR}/boot/grub/grub.cfg"
set timeout=0
set default=0

menuentry "CuOS Installer" {
    linux /boot/vmlinuz
    initrd /boot/initrd.img
}
EOF


VOLID="CUOS"
grub-mkrescue \
  -o "${OUTPUT_DIR}/installer.iso" \
  -V "${VOLID}" \
  -iso-level 3 \
  -full-iso9660-filenames \
  "${ISO_DIR}"


