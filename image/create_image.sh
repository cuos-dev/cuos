#!/bin/bash

raise() {
	echo "Error: $*" >&2
	exit 1
}

cleanup() {
	# Versuche, gemountete Partitionen zu unmounten
	umount -R /mnt/os 2>/dev/null || true
	umount -R /mnt/boot 2>/dev/null || true
	umount -R /mnt/root 2>/dev/null || true

	# Versuche, kpartx-Mappings zu entfernen
	if [[ -n "${LOOPDEV}" ]]; then
		kpartx -dv "${LOOPDEV}" 2>/dev/null || true
		losetup -d "${LOOPDEV}" 2>/dev/null || true
	fi
}
trap cleanup EXIT

IMAGE="/output/image.img"
IMAGE_QCOW="/output/image.qcow2"
#SIZE_MB=2048
SIZE_MB=4096

PARTITION="B"

if [[ ! -d "/output" ]]; then
	echo "Output dir not mounted"
	exit 1
fi

CONFIG_PATH="/output/system.json"
if [[ ! -f "${CONFIG_PATH}" ]]; then
	echo "Config file not found: ${CONFIG_PATH}"
	exit 1
fi
UPDATE_REGISTRY="$(jq -r '.update_registry' "${CONFIG_PATH}")"
OS_IMAGE="$(jq -r '.os_image' "${CONFIG_PATH}")"
OS_VERSION="$(jq -r '.os_image_version' "${CONFIG_PATH}")"
OS_DIGEST="$(jq -r '.os_image_digest' "${CONFIG_PATH}")"

# Create empty image
echo "Create empty image:"
dd if=/dev/zero of="${IMAGE}" bs=1M count="${SIZE_MB}"

# Partition the image
parted "${IMAGE}" --script mklabel gpt \
	mkpart bios_boot 1MiB 3MiB \
	set 1 bios_grub on \
	mkpart ESP fat32 3MiB 256MiB \
	set 2 boot on \
	mkpart primary btrfs 256MiB 100%

# Setup loop device
LOOPDEV="$(losetup --find --show $IMAGE)"
partprobe "${LOOPDEV}"

# Map partitions
kpartx -av "${LOOPDEV}"
sleep 1

export TARGET_DEVICE="${LOOPDEV}"
TARGET_BOOT_PARTITION="/dev/mapper/$(basename "${LOOPDEV}")p2"
export TARGET_BOOT_PARTITION
TARGET_ROOT_PARTITION="/dev/mapper/$(basename "${LOOPDEV}")p3"
export TARGET_ROOT_PARTITION

# Format partitions
mkfs.vfat -n boot "${TARGET_BOOT_PARTITION}" \
    || raise "Failed to format boot partition: ${TARGET_BOOT_PARTITION}"
mkfs.btrfs -L system "${TARGET_ROOT_PARTITION}" \
    || raise "Failed to format root partition: ${TARGET_BOOT_PARTITION}"

# Mount and populate
mkdir -p /mnt/boot /mnt/system /mnt/root
mount -t btrfs "${TARGET_ROOT_PARTITION}" /mnt/root
btrfs subvolume create /mnt/root/@os
btrfs subvolume create /mnt/root/@data
btrfs subvolume create /mnt/root/@swap
mkdir -p /mnt/root/@data/docker
mkdir -p /mnt/root/@data/dhcp
mkdir -p /mnt/root/@data/log
umount /mnt/root


INSTALLGRUB=true INSTALLIMAGE=true \
	/usr/local/updater/updater.sh \
	"${PARTITION}" \
	"${UPDATE_REGISTRY}${OS_IMAGE}:${OS_VERSION}" \
	"${OS_DIGEST}"

EXITCODE="$?"

# Unmap partitions
kpartx -dv "${LOOPDEV}"

# Detach loop device
losetup -d "${LOOPDEV}"

if [[ "${EXITCODE}" != "0" ]]; then
	raise "Failed to run updater script"
fi

echo "Image created at ${IMAGE}"


# File formats:
# Format	Use Case / Platform Support	Notes
# QCOW2	Proxmox, QEMU/KVM, OpenStack	Supports snapshots, compression, sparse files
# VMDK	VMware Workstation, ESXi, Fusion	Native VMware format
# VHD/VHDX	Microsoft Hyper-V, Azure	Use VHDX for modern systems
# RAW	Universal (can be converted to others)	Simple, uncompressed, large file size
# OVA/OVF	VMware, VirtualBox, Proxmox (via import)	Bundle of disk + metadata, easy to distribute

qemu-img convert -f raw -O qcow2 "${IMAGE}" "${IMAGE_QCOW}"

#qemu-img convert -f raw -O vmdk image.img linux.vmdk
#qemu-img convert -f raw -O vhdx image.img linux.vhdx
#ovftool linux.vmdk linux.ova


# zip it!
# Create sha256sum
