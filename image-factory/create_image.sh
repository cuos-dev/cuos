#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

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
# dont use update_registry_proxy here, because we are not yet in the
# target infrastructure. Thus the proxy might not be reachable.
image_url() {
  local image
  image="$(jq -r \
    --arg prefix "${1:-}" '
    (
      if (.[$prefix + "_image"] | (type == "string" and . != "" and
          ((startswith("/")) or (contains(".") | not)))) then
        (.update_registry) + "/" + .[$prefix + "_image"]
      else
        .[$prefix + "_image"]
      end
    ) + (
      if .[$prefix + "_image_version"] and .[$prefix + "_image_version"] != ""then
        ":" + .[$prefix + "_image_version"]
      else
        ""
      end
    ) | gsub("/+"; "/")
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
OUTPUT_DIR="/output"

IMAGE_NAME="${IMAGE_NAME:-"image"}"
IMAGE="${OUTPUT_DIR}/${IMAGE_NAME}.img"

if [[ ! -d "${OUTPUT_DIR}" ]]; then
	echo "Output dir not mounted"
	exit 1
fi

export CONFIG_PATH="${OUTPUT_DIR}/${IMAGE_NAME}.json"
if [[ ! -f "${CONFIG_PATH}" ]]; then
	echo "Config file not found: ${CONFIG_PATH}"
	exit 1
fi
export OS_ARCH="${OS_ARCH:-"$(arch)"}"

# The fallback to os_image is for a platform that has no image of its own
# because it does not need one - the host architecture. For a named board it
# would quietly write a foreign architecture onto the card: an image that builds
# cleanly and never boots.
case "${OS_ARCH}" in
  rpi-arm64|rpi-arm32|orangepi-zero3)
    image_url "${OS_ARCH}" >/dev/null || raise \
      "No \"${OS_ARCH}_image\" in the configuration. Refusing to fall back to
       os_image: that is a different architecture, and it would produce an image
       that builds cleanly and never boots. Pin it in release.json."
    ;;
esac

OS_IMAGE="$(image_url "${OS_ARCH}" || image_url "os")" || \
  action_on_failure "cuos:updater:os_image_not_defined" "OS image not defined"
OS_DIGEST="$(jq -r --arg arch "${OS_ARCH}" '.[$arch+"_image_digest"] // .os_image_digest // empty' "${CONFIG_PATH}")"

if [[ "${OS_ARCH}" == "lxc" ]]; then
  IMAGE="${IMAGE/img/tar.gz}"
  SLOT="A"

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
  docker exec "${CONTAINER_NAME}" /usr/local/cuos/first-run.sh "${SLOT}" "${OS_IMAGE}" "${IMAGE_DIGEST}" \
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

SLOT="B"

SIZE_MB=1636
if [[ "${TARGET}" == "rpi" ]]; then
  SIZE_MB=2048
fi

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
#
# This container's /dev is a snapshot of the host's, taken when the container
# started - 'docker run --privileged' enumerates the host's devices once and
# creates them in here. A device the kernel makes afterwards therefore exists on
# the host and not in this container, and asking for a free loop device is
# exactly that: /dev/loop-control hands out a number, and the node for it never
# appears. losetup then fails with ENOENT and calls the node "lost".
#
# It bites on the first build of a machine, where no loop device existed when
# the container started, and stops biting on the second, where one did.
# Creating the node ourselves is enough wherever we are allowed to.
attach_loop_device() {
  local dev
  dev="$(losetup --find --show "${IMAGE}" 2>/dev/null)" || dev=""
  if [[ -n "${dev}" ]]; then
    printf '%s' "${dev}"
    return 0
  fi

  local free num
  free="$(losetup --find 2>/dev/null)" || free=""
  num="${free##*/loop}"
  if [[ -n "${num}" && "${num}" =~ ^[0-9]+$ && ! -e "${free}" ]]; then
    echo "Creating the missing device node ${free} ..." >&2
    mknod "${free}" b 7 "${num}" 2>/dev/null || true
    chmod 0660 "${free}" 2>/dev/null || true
  fi

  losetup --find --show "${IMAGE}" 2>/dev/null
}

LOOPDEV=""
for _attempt in 1 2 3; do
  LOOPDEV="$(attach_loop_device)" && [[ -n "${LOOPDEV}" ]] && break
  sleep 2
done

if [[ -z "${LOOPDEV}" ]]; then
  if [[ ! -e /dev/loop-control ]]; then
    raise "There is no /dev/loop-control, so no loop device can be asked for.

       The loop module is not loaded on the build host, or it was not loaded
       when this container started. On the host:

         sudo modprobe loop

       then build again. Loading it inside the container does not help: this
       container's /dev was taken from the host at start and does not follow it."
  fi

  raise "Could not attach ${IMAGE} to a loop device.

       The kernel did hand out a loop device - 'device node /dev/loopN is lost'
       above says so - but this container has no node for it, and creating one
       was not permitted either.

       On a normal host or VM this only happens on the very first build, before
       any loop device exists. Load the module on the host and build again:

         sudo modprobe loop dm_mod

       Inside an LXC container it happens every time, because loop devices,
       device-mapper and mounting all belong to the host kernel. Build on a host
       or in a VM instead; if it has to be that container, it must be privileged
       and unconfined, with at least:

         lxc.apparmor.profile: unconfined
         lxc.cgroup2.devices.allow: b 7:* rwm
         lxc.cgroup2.devices.allow: c 10:237 rwm
         lxc.mount.entry: /dev/loop-control dev/loop-control none bind,create=file
         lxc.mount.entry: /dev/loop0 dev/loop0 none bind,create=file

       plus one bind entry per loop device wanted.

       Building for '--platform lxc' needs none of this: it exports a container
       rather than partitioning a disk."
fi

# Device-mapper is the next thing needed, and it is the same story: kpartx maps
# the image's partitions through it, and /dev/mapper/control has to be here.
if [[ ! -e /dev/mapper/control ]]; then
  raise "There is no /dev/mapper/control, so the partitions of ${IMAGE} cannot
       be mapped.

       Same cause as a missing loop device: this container's /dev was taken from
       the host when it started. On the host:

         sudo modprobe dm_mod

       then build again."
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
    || raise "Failed to format root partition: ${TARGET_ROOT_PARTITION}"

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
	"${SLOT}" \
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
