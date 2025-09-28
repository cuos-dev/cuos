#!/bin/bash

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

IMAGE="/output/image.img"

if [[ ! -d "/output" ]]; then
	echo "Output dir not mounted"
	exit 1
fi

# Setup loop device
LOOPDEV="$(losetup --find --show $IMAGE)"
partprobe "${LOOPDEV}"

# Map partitions
kpartx -av "${LOOPDEV}"
sleep 1

if [[ "${TARGET}" == "rpi" ]]; then
  TARGET_BOOT_PARTITION_NUM=1
  TARGET_ROOT_PARTITION_NUM=2
else
  TARGET_BOOT_PARTITION_NUM=2
  TARGET_ROOT_PARTITION_NUM=3
fi

TARGET_BOOT_PARTITION="/dev/mapper/$(basename "${LOOPDEV}")p${TARGET_BOOT_PARTITION_NUM}"
export TARGET_BOOT_PARTITION
TARGET_ROOT_PARTITION="/dev/mapper/$(basename "${LOOPDEV}")p${TARGET_ROOT_PARTITION_NUM}"
export TARGET_ROOT_PARTITION
TARGET_BOOT="${TARGET_BOOT:-"/mnt/boot"}"
TARGET_ROOT="${TARGET_ROOT:-"/mnt/os"}"

# Mount devices
mkdir -p "${TARGET_ROOT}"
mount -t btrfs -o subvol=@os "${TARGET_ROOT_PARTITION}" "${TARGET_ROOT}"

mkdir -p "${TARGET_BOOT}"
mount -t vfat -o "rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro" "${TARGET_BOOT_PARTITION}" "${TARGET_BOOT}"

/usr/local/updater/docker_environment.sh /bin/bash

umount /mnt/os
umount /mnt/boot

# Unmap partitions
kpartx -dv "${LOOPDEV}"

# Detach loop device
losetup -d "${LOOPDEV}"
