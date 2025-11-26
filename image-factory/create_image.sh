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

# functions from system/cuos/utils.sh
image_url() {
  local image
  image="$(jq -r \
    --arg prefix "${1:-}" '
    (
      if (.[$prefix + "_image"] | (type == "string" and . != "" and
          ((startswith("/")) or (contains(".") | not)))) then
        .update_registry + .[$prefix + "_image"]
      else
        .[$prefix + "_image"]
      end
    ) + (
      if .[$prefix + "_image_version"] and .[$prefix + "_image_version"] != ""then
        ":" + .[$prefix + "_image_version"]
      else
        ""
      end
    )
    ' "${CONFIG_PATH}")"
  if [[ -z "${image}" ]]; then return 1; fi
  echo "${image}"
}

image_version() {
  local image="${1:-""}"
  #remove registry name including :[port]
  image="${image##*/}"
  if [[ "${image}" != *:* ]]; then
    echo "latest"
    return
  fi
  local version="${image##*:}"
  echo "${version:-"latest"}"
}

export DOCKER_CONTEXT=default

IMAGE="/output/image.img"
#IMAGE_QCOW="/output/image.qcow2"

if [[ ! -d "/output" ]]; then
	echo "Output dir not mounted"
	exit 1
fi

export CONFIG_PATH="/output/system.json"
if [[ ! -f "${CONFIG_PATH}" ]]; then
	echo "Config file not found: ${CONFIG_PATH}"
	exit 1
fi
export OS_ARCH="${OS_ARCH:-"$(arch)"}"

OS_IMAGE="$(image_url "${OS_ARCH}" || image_url "os")" || \
  action_on_failure "cuos:updater:os_image_not_defined" "OS image not defined"
OS_DIGEST="$(jq -r --arg arch "${OS_ARCH}" '.[$arch+"_image_digest"] // .os_image_digest // empty' "${CONFIG_PATH}")"

if [[ "${OS_ARCH}" == "lxc" ]]; then
  IMAGE="${IMAGE/img/tar.gz}"
  PARTITION="A"

  docker image pull "${OS_IMAGE}" || raise "Faild to fetch image"
  IMAGE_DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "${OS_IMAGE}" 2>/dev/null | cut -d '@' -f 2)"
  if [[ -n "${OS_DIGEST}" && "${OS_DIGEST}" != "${IMAGE_DIGEST}" ]]; then
    echo "Image digest mismatch: ${OS_DIGEST} != ${IMAGE_DIGEST}"
    exit 1
  fi

  CONTAINER_NAME="cuos-lxc-$$"
  docker run -it -d \
    --pull=never \
    --name "${CONTAINER_NAME}" \
    "${OS_IMAGE}" || raise "Failed to run container"
  docker exec "${CONTAINER_NAME}" /usr/local/cuos/first-run.sh "${PARTITION}" "${OS_IMAGE}" "${IMAGE_DIGEST}" \
    || raise "Failed to run first-run script in container"

  docker cp "${CONFIG_PATH}" "${CONTAINER_NAME}:/system_init.json" \
    || raise "Failed to copy system.json"

  if ! docker export "${CONTAINER_NAME}" | gzip >"${IMAGE}"; then
    raise "Failed to export the container"
  fi
  docker rm -f "${CONTAINER_NAME}" \
    || raise "Failed to remove the container"

  echo "Image created at ${IMAGE/\//}"
  exit 0
fi

PARTITION="B"

#SIZE_MB=2048
SIZE_MB=4096
SIZE_MB=1636

SIZE_MB="$(jq --arg size_mb "${SIZE_MB}" -r '.image_size_mb // $size_mb' "${CONFIG_PATH}")"

# Create empty image
echo "Create empty image:"
dd if=/dev/zero of="${IMAGE}" bs=1M count="${SIZE_MB}"
sync

if [[ "${TARGET}" == "rpi" ]]; then
  parted "${IMAGE}" --script \
    mklabel msdos \
    mkpart primary fat32 1MiB 256MiB \
    mkpart primary btrfs 256MiB 100% \
    set 1 boot on

  TARGET_BOOT_PARTITION_NUM=1
  TARGET_ROOT_PARTITION_NUM=2
else
  # Partition the image
  parted "${IMAGE}" --script \
    mklabel gpt \
    mkpart bios_boot 1MiB 3MiB \
    set 1 bios_grub on \
    mkpart ESP fat32 3MiB 256MiB \
    set 2 boot on \
    mkpart primary btrfs 256MiB 100%

  TARGET_BOOT_PARTITION_NUM=2
  TARGET_ROOT_PARTITION_NUM=3
fi
sync

# Setup loop device
if ! LOOPDEV="$(losetup --find --show "${IMAGE}")"; then
  raise "Failed to setup loop device. Please try again. Ensure loop module is loaded."
fi

partprobe "${LOOPDEV}"

# Map partitions
kpartx -av "${LOOPDEV}"
sleep 1

export TARGET_DEVICE="${LOOPDEV}"
TARGET_BOOT_PARTITION="/dev/mapper/$(basename "${LOOPDEV}")p${TARGET_BOOT_PARTITION_NUM}"
export TARGET_BOOT_PARTITION
TARGET_ROOT_PARTITION="/dev/mapper/$(basename "${LOOPDEV}")p${TARGET_ROOT_PARTITION_NUM}"
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


export INSTALLIMAGE=true
/usr/local/updater/updater.sh \
	"${PARTITION}" \
	"${OS_IMAGE}" \
	"${OS_DIGEST}"

EXITCODE="$?"

# Unmap partitions
kpartx -dv "${LOOPDEV}"

# Detach loop device
losetup -d "${LOOPDEV}"

if [[ "${EXITCODE}" != "0" ]]; then
	raise "Failed to run updater script"
fi

echo "Image created at ${IMAGE/\//}"


# File formats:
# Format	Use Case / Platform Support	Notes
# QCOW2	Proxmox, QEMU/KVM, OpenStack	Supports snapshots, compression, sparse files
# VMDK	VMware Workstation, ESXi, Fusion	Native VMware format
# VHD/VHDX	Microsoft Hyper-V, Azure	Use VHDX for modern systems
# RAW	Universal (can be converted to others)	Simple, uncompressed, large file size
# OVA/OVF	VMware, VirtualBox, Proxmox (via import)	Bundle of disk + metadata, easy to distribute

#qemu-img convert -f raw -O qcow2 "${IMAGE}" "${IMAGE/.img/.qcow2}"

#qemu-img convert -f raw -O vmdk image.img linux.vmdk
#qemu-img convert -f raw -O vhdx image.img linux.vhdx
#ovftool linux.vmdk linux.ova


# zip it!
# Create sha256sum
