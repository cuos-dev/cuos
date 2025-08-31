#!/bin/bash
set -e

# Define paths
WORKDIR="/build"
OUTPUT_DIR="/output"
ISO_DIR="${WORKDIR}/iso"
INITRD_IMAGE="${WORKDIR}/initrd.img"

if [[ ! -d "${OUTPUT_DIR}" ]]; then
	echo "Build dir does not exist."
	exit 2
fi


# Prepare initramfs-tools config
mkdir -p "/etc/initramfs-tools/conf.d"
mkdir -p "/usr/share/initramfs-tools/scripts/init-bottom"

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

# Add custom installer script
cat <<'EOF' > "/etc/initramfs-tools/scripts/init-premount/cuos-installer"
#!/bin/sh
echo "Running custom installer..."
# Your install logic here
sleep 5
reboot

EOF
chmod +x "/etc/initramfs-tools/scripts/init-premount/cuos-installer"

# Build initrd.img
mkinitramfs -o "${INITRD_IMAGE}"

# Prepare ISO directory
mkdir -p "${ISO_DIR}/boot/grub"
cp "/boot/vmlinuz"-* "${ISO_DIR}/boot/vmlinuz"
cp "${INITRD_IMAGE}" "${ISO_DIR}/boot/initrd.img"

# Create grub config
cat <<EOF >"${ISO_DIR}/boot/grub/grub.cfg"
set timeout=0
set default=0

menuentry "CuOS Installer" {
    linux /boot/vmlinuz
    initrd /boot/initrd.img
}
EOF

# Build hybrid ISO
xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "CuOSInstaller" \
  -output "${OUTPUT_DIR}/installer.iso" \
  -eltorito-boot boot/grub/i386-pc/eltorito.img \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-catalog boot/grub/boot.cat \
  -eltorito-alt-boot \
  -e --interval:appended_partition_2:all:: \
  -no-emul-boot \
  -append_partition 2 0xef "${ISO_DIR}/boot/grub/efi.img" \
  -isohybrid-gpt-basdat \
  -isohybrid-apm-hfsplus \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  "${ISO_DIR}"
