#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# This factory runs the updater's scripts and shares its libraries. In the image
# the entrypoints sit at / and their libraries do not - / already has a lib. In
# the tree both are beside each other.
CUOS_UPDATER_DIR="${CUOS_UPDATER_DIR:-"/usr/local/updater"}"
[[ -d "${CUOS_UPDATER_DIR}/lib" ]] || CUOS_UPDATER_DIR="${SCRIPT_DIR}/../updater"
CUOS_FACTORY_DIR="${CUOS_FACTORY_DIR:-"/usr/local/image-factory"}"
[[ -d "${CUOS_FACTORY_DIR}/lib" ]] || CUOS_FACTORY_DIR="${SCRIPT_DIR}"

# shellcheck source=../updater/lib/log.sh
source "${CUOS_UPDATER_DIR}/lib/log.sh"
# shellcheck source=lib/config.sh
source "${CUOS_FACTORY_DIR}/lib/config.sh"
# shellcheck source=lib/loopdev.sh
source "${CUOS_FACTORY_DIR}/lib/loopdev.sh"

LOOPDEV=""

# shellcheck disable=SC2329 disable=SC2317
cleanup() {
	umount -R /mnt/os 2>/dev/null || true
	umount -R /mnt/boot 2>/dev/null || true
	umount -R /mnt/root 2>/dev/null || true

	loopdev_detach "${LOOPDEV}"
}
trap cleanup EXIT


export DOCKER_CONTEXT=default

# tool.sh hands the host's daemon in under a name of its own, so that
# /var/run/docker.sock stays free for a dockerd started inside this container -
# updater/docker_environment.sh explains why, and picks the same socket up for
# the disk-image path. The lxc branch below never gets that far: it pulls, runs
# and exports on the host's daemon and returns, so it has to find the socket
# itself. Keep the path in step with docker_environment.sh.
if [[ -S "/run/cuos-docker.sock" ]]; then
  export DOCKER_HOST="unix:///run/cuos-docker.sock"
fi

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

  step "Fetching the system image ${OS_IMAGE}"
  docker image pull "${OS_IMAGE}" || raise "Faild to fetch image"
  IMAGE_DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "${OS_IMAGE}" 2>/dev/null | cut -d '@' -f 2)"
  if [[ -n "${OS_DIGEST}" && "${OS_DIGEST}" != "${IMAGE_DIGEST}" ]]; then
    echo "Image digest mismatch: ${OS_DIGEST} != ${IMAGE_DIGEST}"
    exit 1
  fi

  step "Initialising the system"
  CONTAINER_NAME="cuos-lxc-$$"
  docker run -it -d \
    --pull=never \
    --name "${CONTAINER_NAME}" \
    "${OS_IMAGE}" || raise "Failed to run container"
  docker exec "${CONTAINER_NAME}" /usr/local/cuos/first-run.sh "${SLOT}" "${OS_IMAGE}" "${IMAGE_DIGEST}" \
    || raise "Failed to run first-run script in container"

  docker cp "${CONFIG_PATH}" "${CONTAINER_NAME}:/system_init.json" \
    || raise "Failed to copy system.json"

  step "Exporting the root filesystem"
  if ! docker export "${CONTAINER_NAME}" | gzip >"${IMAGE}"; then
    raise "Failed to export the container"
  fi
  docker rm -f "${CONTAINER_NAME}" \
    || raise "Failed to remove the container"

  step "${IMAGE/\//} written"
  exit 0
fi

SLOT="B"

SIZE_MB=1636
if [[ "${TARGET}" == "rpi" ]]; then
  SIZE_MB=2048
fi

SIZE_MB="$(jq --arg size_mb "${SIZE_MB}" -r '.image_size_mb // $size_mb' "${CONFIG_PATH}")"

# Create empty image
step "Creating an empty image of ${SIZE_MB} MB"
dd if=/dev/zero of="${IMAGE}" bs=1M count="${SIZE_MB}"
sync

# The step lines name the layout as 'mbr' and 'gpt', the names tool.sh's
# --layout uses. TARGET is the factory's own spelling of the same choice, and
# for GPT it is empty.
if [[ "${TARGET}" == "rpi" ]]; then
  step "Partitioning the image (mbr)"
  parted "${IMAGE}" --script \
    mklabel msdos \
    mkpart primary fat32 1MiB 256MiB \
    mkpart primary btrfs 256MiB 100% \
    set 1 boot on

  TARGET_BOOT_PARTITION_NUM=1
  TARGET_ROOT_PARTITION_NUM=2
else
  step "Partitioning the image (gpt)"
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

LOOPDEV="$(loopdev_attach "${IMAGE}")"

loopdev_map_partitions "${LOOPDEV}"

export TARGET_DEVICE="${LOOPDEV}"
TARGET_BOOT_PARTITION="/dev/mapper/$(basename "${LOOPDEV}")p${TARGET_BOOT_PARTITION_NUM}"
export TARGET_BOOT_PARTITION
TARGET_ROOT_PARTITION="/dev/mapper/$(basename "${LOOPDEV}")p${TARGET_ROOT_PARTITION_NUM}"
export TARGET_ROOT_PARTITION

# Format partitions
step "Creating the filesystems"
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


step "Installing the system from ${OS_IMAGE}"
export INSTALLIMAGE=true
/usr/local/updater/updater.sh \
	"${SLOT}" \
	"${OS_IMAGE}" \
	"${OS_DIGEST}"

EXITCODE="$?"

loopdev_detach "${LOOPDEV}"
LOOPDEV=""

if [[ "${EXITCODE}" != "0" ]]; then
	raise "Failed to run updater script"
fi

step "${IMAGE/\//} written"


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
