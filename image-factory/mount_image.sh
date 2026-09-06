#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

raise() {
	echo "Error: $*" >&2
	exit 1
}

cleanup() {
	# Versuche, gemountete Partitionen zu unmounten
	umount /mnt/os 2>/dev/null || true
	umount /mnt/boot 2>/dev/null || true
	umount /mnt/root 2>/dev/null || true

	# Versuche, kpartx-Mappings zu entfernen
	if [[ -n "${LOOPDEV}" ]]; then
		kpartx -dv "${LOOPDEV}" 2>/dev/null || true
		losetup -d "${LOOPDEV}" 2>/dev/null || true
	fi
}
trap cleanup EXIT

OUTPUT_DIR="/output"

IMAGE_NAME="${IMAGE_NAME:-"image"}"
IMAGE="${OUTPUT_DIR}/${IMAGE_NAME}.img"

if [[ ! -d "${OUTPUT_DIR}" ]]; then
	echo "Output dir not mounted"
	exit 1
fi

# Setup loop device
if ! LOOPDEV="$(losetup --find --show "${IMAGE}")" || [[ -z "${LOOPDEV}" ]]; then
	raise "Could not attach ${IMAGE} to a loop device.

       This needs the host's /dev, not the copy of it a privileged container
       gets at start: the node for a loop device the kernel hands out now does
       not exist in that copy. tool.sh mounts it; a factory started by hand
       needs '-v /dev:/dev' too.

       If /dev is mounted and this still fails, the loop module is not loaded on
       the host: 'sudo modprobe loop dm_mod'."
fi
partprobe "${LOOPDEV}"

# Map partitions
kpartx -av "${LOOPDEV}"
sleep 1

# Find the boot and root partitions by filesystem type. The partition numbers
# differ per layout: MBR + FAT boot (1/2), GPT + bios_grub + ESP (2/3).
LOOP_NAME="$(basename "${LOOPDEV}")"
TARGET_BOOT_PARTITION=""
TARGET_ROOT_PARTITION=""

for part in "/dev/mapper/${LOOP_NAME}p"*; do
	[[ -b "${part}" ]] || continue
	case "$(blkid -s TYPE -o value "${part}" 2>/dev/null)" in
		vfat)
			[[ -n "${TARGET_BOOT_PARTITION}" ]] || TARGET_BOOT_PARTITION="${part}"
			;;
		btrfs)
			[[ -n "${TARGET_ROOT_PARTITION}" ]] || TARGET_ROOT_PARTITION="${part}"
			;;
	esac
done

[[ -n "${TARGET_BOOT_PARTITION}" ]] \
	|| raise "No FAT boot partition found in ${IMAGE}. Was the image built?"
[[ -n "${TARGET_ROOT_PARTITION}" ]] \
	|| raise "No BTRFS root partition found in ${IMAGE}. Was the image built?"

echo "Boot partition: ${TARGET_BOOT_PARTITION} (vfat)"
echo "Root partition: ${TARGET_ROOT_PARTITION} (btrfs)"

export TARGET_BOOT_PARTITION
export TARGET_ROOT_PARTITION
TARGET_BOOT="${TARGET_BOOT:-"/mnt/boot"}"
TARGET_ROOT="${TARGET_ROOT:-"/mnt/os"}"

# Mount devices
mkdir -p "${TARGET_ROOT}"
mount -t btrfs -o subvol=@os "${TARGET_ROOT_PARTITION}" "${TARGET_ROOT}"

mkdir -p "${TARGET_BOOT}"
# Same charset reasoning as updater/docker_environment.sh: name none, so the
# mount works on whatever kernel this runs against.
mount -t vfat -o "rw,relatime,fmask=0022,dmask=0022,shortname=mixed,errors=remount-ro" "${TARGET_BOOT_PARTITION}" "${TARGET_BOOT}"

/bin/bash

umount /mnt/os
umount /mnt/boot

# Unmap partitions
kpartx -dv "${LOOPDEV}"

# Detach loop device
losetup -d "${LOOPDEV}"
