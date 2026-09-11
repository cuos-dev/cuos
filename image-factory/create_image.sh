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
# shellcheck source=../updater/lib/platform.sh
source "${CUOS_UPDATER_DIR}/lib/platform.sh"
# shellcheck source=lib/config.sh
source "${CUOS_FACTORY_DIR}/lib/config.sh"
# shellcheck source=lib/loopdev.sh
source "${CUOS_FACTORY_DIR}/lib/loopdev.sh"
# shellcheck source=lib/size.sh
source "${CUOS_FACTORY_DIR}/lib/size.sh"

OUTPUT_DIR="${OUTPUT_DIR:-"/output"}"
IMAGE_NAME="${IMAGE_NAME:-"image"}"
IMAGE="${OUTPUT_DIR}/${IMAGE_NAME}.img"
LOOPDEV=""

# shellcheck disable=SC2329 disable=SC2317
cleanup() {
  umount -R /mnt/os 2>/dev/null || true
  umount -R /mnt/boot 2>/dev/null || true
  umount -R /mnt/root 2>/dev/null || true

  loopdev_detach "${LOOPDEV}"
}

# tool.sh hands the host's daemon in under a name of its own, so that
# /var/run/docker.sock stays free for a dockerd started inside this container -
# updater/lib/docker.sh explains why and picks the same socket up for the
# disk-image path. This entrypoint never gets that far for '--platform lxc': it
# pulls, runs and exports on the host's daemon and returns, so it has to find
# the socket itself.
use_handed_in_daemon() {
  export DOCKER_CONTEXT=default

  if [[ -S "${CUOS_DOCKER_SOCKET:-"/run/cuos-docker.sock"}" ]]; then
    export DOCKER_HOST="unix://${CUOS_DOCKER_SOCKET:-"/run/cuos-docker.sock"}"
  fi
}

check_output_dir() {
  [[ -d "${OUTPUT_DIR}" ]] || raise "Output dir not mounted"

  export CONFIG_PATH="${OUTPUT_DIR}/${IMAGE_NAME}.json"
  [[ -f "${CONFIG_PATH}" ]] || raise "Config file not found: ${CONFIG_PATH}"
}

# The fallback to os_image is for a platform that has no image of its own
# because it does not need one - the host architecture. For a named board it
# would quietly write a foreign architecture onto the card: an image that builds
# cleanly and never boots.
resolve_os_image() {
  case "${OS_ARCH}" in
    rpi-arm64|rpi-arm32|orangepi-zero3)
      image_url "${OS_ARCH}" >/dev/null || raise \
        "No \"${OS_ARCH}_image\" in the configuration. Refusing to fall back to
       os_image: that is a different architecture, and it would produce an image
       that builds cleanly and never boots. Pin it in release.json."
      ;;
  esac

  OS_IMAGE="$(image_url "${OS_ARCH}" || image_url "os")" \
    || raise "No system image in the configuration"
  OS_DIGEST="$(jq -r --arg arch "${OS_ARCH}" \
    '.[$arch+"_image_digest"] // .os_image_digest // empty' "${CONFIG_PATH}")"
}

# The size of the image is computed from the size of the system image, so it has
# to be here before anything is written. The updater pulls again later, which
# then costs one question to the registry.
pull_system_image() {
  # ':build' is a system image built here and handed over locally, the same tag
  # updater/lib/image.sh knows as is_local_build. There is no registry for it.
  if [[ "${OS_IMAGE}" = *:build ]]; then
    return
  fi

  local platform
  platform="$(target_platform "${OS_ARCH}")" || exit 1

  step "Fetching ${OS_IMAGE}"
  docker image pull --platform "${platform}" "${OS_IMAGE}" \
    || raise "Faild to fetch the system image ${OS_IMAGE}"
}

image_size_mb() {
  local computed configured

  computed="$(required_image_size_mb "${OS_IMAGE}")" \
    || raise "Could not read the size of ${OS_IMAGE}"

  configured="$(jq -r '.image_size_mb // empty' "${CONFIG_PATH}")"
  if [[ -n "${configured}" ]]; then
    if (( configured < computed )); then
      raise "image_size_mb is ${configured}, the rootfs of ${OS_IMAGE} needs
       ${computed} MB. Raise it, or drop it and let the factory compute it."
    fi
    echo "${configured}"
    return
  fi

  echo "${computed}"
}

build_lxc_image() {
  local image_digest container_name

  # The extension, not the first "img" in the path: an image whose name carries
  # those three letters would otherwise be renamed instead of its suffix.
  IMAGE="${IMAGE%.img}.tar.gz"

  step "Fetching the system image ${OS_IMAGE}"
  docker image pull "${OS_IMAGE}" || raise "Faild to fetch image"
  image_digest="$(docker inspect --format='{{index .RepoDigests 0}}' \
    "${OS_IMAGE}" 2>/dev/null | cut -d '@' -f 2)"
  if [[ -n "${OS_DIGEST}" && "${OS_DIGEST}" != "${image_digest}" ]]; then
    raise "Image digest mismatch: ${OS_DIGEST} != ${image_digest}"
  fi

  step "Initialising the system"
  container_name="cuos-lxc-$$"
  docker run -it -d \
    --pull=never \
    --name "${container_name}" \
    "${OS_IMAGE}" || raise "Failed to run container"
  docker exec "${container_name}" /usr/local/cuos/first-run.sh \
    "A" "${OS_IMAGE}" "${image_digest}" \
    || raise "Failed to run first-run script in container"

  docker cp "${CONFIG_PATH}" "${container_name}:/system_init.json" \
    || raise "Failed to copy system.json"

  step "Exporting the root filesystem"
  if ! docker export "${container_name}" | gzip >"${IMAGE}"; then
    raise "Failed to export the container"
  fi
  docker rm -f "${container_name}" \
    || raise "Failed to remove the container"

  step "${IMAGE/\//} written"
}

create_empty_image() {
  step "Creating an empty image of ${1} MB"
  dd if=/dev/zero of="${IMAGE}" bs=1M count="${1}"
  sync
}

# The arguments parted is given, so that the layout can be read - and asserted -
# without writing an image. The boot partition ends at 256MiB in both layouts,
# which is what lib/size.sh adds in front of the root partition.
partition_plan() {
  if [[ "${1}" == "rpi" ]]; then
    echo "mklabel msdos" \
      "mkpart primary fat32 1MiB 256MiB" \
      "mkpart primary btrfs 256MiB 100%" \
      "set 1 boot on"
    return
  fi

  echo "mklabel gpt" \
    "mkpart bios_boot 1MiB 3MiB" \
    "set 1 bios_grub on" \
    "mkpart ESP fat32 3MiB 256MiB" \
    "set 2 boot on" \
    "mkpart primary btrfs 256MiB 100%"
}

# The step lines name the layout as 'mbr' and 'gpt', the names tool.sh's
# --layout uses. TARGET is the factory's own spelling of the same choice, and
# for GPT it is empty.
partition_image() {
  local plan
  read -r -a plan <<<"$(partition_plan "${TARGET}")"

  if [[ "${TARGET}" == "rpi" ]]; then
    step "Partitioning the image (mbr)"
    TARGET_BOOT_PARTITION_NUM=1
    TARGET_ROOT_PARTITION_NUM=2
  else
    step "Partitioning the image (gpt)"
    TARGET_BOOT_PARTITION_NUM=2
    TARGET_ROOT_PARTITION_NUM=3
  fi

  parted "${IMAGE}" --script "${plan[@]}" \
    || raise "Failed to partition ${IMAGE}"
  sync
}

map_partitions() {
  loopdev_attach "${IMAGE}"
  loopdev_map_partitions "${LOOPDEV}"

  export TARGET_DEVICE="${LOOPDEV}"
  TARGET_BOOT_PARTITION="/dev/mapper/$(basename "${LOOPDEV}")p${TARGET_BOOT_PARTITION_NUM}"
  export TARGET_BOOT_PARTITION
  TARGET_ROOT_PARTITION="/dev/mapper/$(basename "${LOOPDEV}")p${TARGET_ROOT_PARTITION_NUM}"
  export TARGET_ROOT_PARTITION
}

create_filesystems() {
  step "Creating the filesystems"
  mkfs.vfat -n boot "${TARGET_BOOT_PARTITION}" \
    || raise "Failed to format boot partition: ${TARGET_BOOT_PARTITION}"
  mkfs.btrfs -L system "${TARGET_ROOT_PARTITION}" \
    || raise "Failed to format root partition: ${TARGET_ROOT_PARTITION}"
}

create_subvolumes() {
  mkdir -p /mnt/boot /mnt/system /mnt/root
  mount -t btrfs "${TARGET_ROOT_PARTITION}" /mnt/root \
    || raise "Failed to mount ${TARGET_ROOT_PARTITION}"

  btrfs subvolume create /mnt/root/@os
  btrfs subvolume create /mnt/root/@data
  btrfs subvolume create /mnt/root/@swap
  mkdir -p /mnt/root/@data/docker
  mkdir -p /mnt/root/@data/dhcp
  mkdir -p /mnt/root/@data/log

  umount /mnt/root
}

install_system() {
  local exit_code

  step "Installing the system from ${OS_IMAGE}"
  export INSTALLIMAGE=true
  "${CUOS_UPDATER_DIR}/updater.sh" "B" "${OS_IMAGE}" "${OS_DIGEST}"
  exit_code="$?"

  loopdev_detach "${LOOPDEV}"
  LOOPDEV=""

  [[ "${exit_code}" = "0" ]] || raise "Failed to run updater script"
}

main() {
  trap cleanup EXIT

  use_handed_in_daemon
  check_output_dir

  export OS_ARCH="${OS_ARCH:-"$(arch)"}"
  resolve_os_image

  if [[ "${OS_ARCH}" == "lxc" ]]; then
    build_lxc_image
    exit 0
  fi

  pull_system_image

  # Not create_empty_image "$(image_size_mb)": image_size_mb raises when the
  # configured size is too small, and a raise inside "$( )" ends the subshell
  # only - dd would then be given an empty count.
  local size_mb
  size_mb="$(image_size_mb)" || exit "$?"
  create_empty_image "${size_mb}"
  partition_image
  map_partitions
  create_filesystems
  create_subvolumes
  install_system

  step "${IMAGE/\//} written"
  exit 0
}

# Execute main only if script is run, not sourced
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
