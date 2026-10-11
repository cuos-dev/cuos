#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# A failing "docker export" must not be hidden behind the gzip it feeds.
set -o pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# This factory installs the system with the updater's own steps and shares its
# libraries. In the image the entrypoint sits at / and the libraries do not - /
# already has a lib. In the tree both are beside each other.
CUOS_UPDATER_DIR="${CUOS_UPDATER_DIR:-"/usr/local/updater"}"
[[ -d "${CUOS_UPDATER_DIR}/lib" ]] || CUOS_UPDATER_DIR="${SCRIPT_DIR}/../updater"
CUOS_FACTORY_DIR="${CUOS_FACTORY_DIR:-"/usr/local/image-factory"}"
[[ -d "${CUOS_FACTORY_DIR}/lib" ]] || CUOS_FACTORY_DIR="${SCRIPT_DIR}"

# shellcheck source=../updater/lib/update.sh
source "${CUOS_UPDATER_DIR}/lib/update.sh"
# shellcheck source=lib/config.sh
source "${CUOS_FACTORY_DIR}/lib/config.sh"
# shellcheck source=lib/size.sh
source "${CUOS_FACTORY_DIR}/lib/size.sh"
# shellcheck source=lib/layout.sh
source "${CUOS_FACTORY_DIR}/lib/layout.sh"
# shellcheck source=lib/bootloader.sh
source "${CUOS_FACTORY_DIR}/lib/bootloader.sh"

OUTPUT_DIR="${OUTPUT_DIR:-"/output"}"
IMAGE_NAME="${IMAGE_NAME:-"image"}"
# Not IMAGE: that is the updater's, the system image to install.
IMAGE_FILE="${OUTPUT_DIR}/${IMAGE_NAME}.img"
# The one slot the factory installs; an update writes the other.
FACTORY_SLOT="A"
BUILD_DIR=""
IMAGE_WRITTEN=""
# The lxc build's container runs on the host's daemon and outlives this one.
LXC_CONTAINER=""

# An image that stopped halfway looks just like a finished one.
# shellcheck disable=SC2329 disable=SC2317
cleanup() {
  [[ -z "${BUILD_DIR}" ]] || rm -rf "${BUILD_DIR}"
  [[ -z "${LXC_CONTAINER}" ]] || docker rm -f "${LXC_CONTAINER}" >/dev/null 2>&1
  if [[ -z "${IMAGE_WRITTEN}" &&
    ( "${IMAGE_FILE}" = *.img || "${IMAGE_FILE}" = *.tar.gz ) ]]; then
    rm -f "${IMAGE_FILE}"
  fi
}

# tool.sh hands the host's daemon in under a name of its own,
# /run/cuos-docker.sock - updater/lib/docker.sh explains why. It is the only
# daemon there is: one started in here would need a btrfs to keep its images
# on, and the factory mounts nothing.
use_handed_in_daemon() {
  export DOCKER_CONTEXT=default

  docker_use_handed_in || docker_available || raise "No docker daemon.

       The factory pulls the system image and unpacks it through the host's
       daemon. Hand it in the way tool.sh does it:

         -v /var/run/docker.sock:/run/cuos-docker.sock"
}

check_output_dir() {
  [[ -d "${OUTPUT_DIR}" ]] || raise "Output dir not mounted"

  export CONFIG_PATH="${OUTPUT_DIR}/${IMAGE_NAME}.json"
  [[ -f "${CONFIG_PATH}" ]] || raise "Config file not found: ${CONFIG_PATH}"
}

# Selects the system image the configuration names, as the updater's IMAGE and
# PINNED_DIGEST.
#
# The fallback to os_image is for a platform that has no image of its own
# because it does not need one - the host architecture. For a named board it
# would quietly write a foreign architecture onto the card: an image that builds
# cleanly and never boots.
select_system_image() {
  local image digest

  case "${OS_ARCH}" in
    rpi-arm64|rpi-arm32|orangepi-zero3)
      image_url "${OS_ARCH}" >/dev/null || raise \
        "No \"${OS_ARCH}_image\" in the configuration. Refusing to fall back to
       os_image: that is a different architecture, and it would produce an image
       that builds cleanly and never boots. Pin it in release.json."
      ;;
  esac

  image="$(image_url "${OS_ARCH}" || image_url "os")" \
    || raise "No system image in the configuration"
  digest="$(jq -r --arg arch "${OS_ARCH}" \
    '.[$arch+"_image_digest"] // .os_image_digest // empty' "${CONFIG_PATH}")"

  select_target "${FACTORY_SLOT}" "${image}" "${digest}"
}

# ':build' is a system image built on this host and handed over through its
# daemon (tool.sh BUILD=1). There is no registry to pull it from.
fetch_system_image() {
  if [[ "${IMAGE}" != *:build ]]; then
    step "Fetching ${IMAGE}"
    pull_image
  fi
  check_pinned_digest
}

# $1 is the size of the tree in KiB.
image_size_mb() {
  local computed configured

  computed="$(required_image_size_mb "${1}")" \
    || raise "Could not compute the image size from \"${1}\" KiB"

  configured="$(jq -r '.image_size_mb // empty' "${CONFIG_PATH}")"
  if [[ -n "${configured}" ]]; then
    if (( configured < computed )); then
      raise "image_size_mb is ${configured}, the system from ${IMAGE} needs
       ${computed} MB. Raise it, or drop it and let the factory compute it."
    fi
    echo "${configured}"
    return
  fi

  echo "${computed}"
}

# A container's root filesystem, exported as it stands once first-run.sh has
# set it up - LXC unpacks it, and there is no disk, partition or boot loader.
build_lxc_image() {
  # The extension, not the first "img" in the path: an image whose name carries
  # those three letters would otherwise be renamed instead of its suffix.
  IMAGE_FILE="${IMAGE_FILE%.img}.tar.gz"

  step "Initialising the system"
  LXC_CONTAINER="cuos-lxc-$$"
  docker run -it -d \
    --pull=never \
    --name "${LXC_CONTAINER}" \
    "${IMAGE}" || raise "Failed to run container"
  docker exec "${LXC_CONTAINER}" /usr/local/cuos/first-run.sh \
    "${SLOT}" "${IMAGE}" "$(recorded_digest "${PULLED_DIGEST}")" \
    || raise "Failed to run first-run script in container"

  docker cp "${CONFIG_PATH}" "${LXC_CONTAINER}:/system_init.json" \
    || raise "Failed to copy system.json"

  step "Exporting the root filesystem"
  if ! docker export "${LXC_CONTAINER}" | gzip >"${IMAGE_FILE}"; then
    raise "Failed to export the container"
  fi
  docker rm -f "${LXC_CONTAINER}" \
    || raise "Failed to remove the container"
  LXC_CONTAINER=""

  step "${IMAGE_FILE#/} written"
}

# Sets BOOT_TYPE and LAYOUT from the image's dev.cuos.boot label. An image
# without one writes its boot loader itself, onto a device this factory does
# not have.
#
# TARGET is the layout tool.sh derives from --layout and the platform: "rpi"
# for mbr, empty for gpt. The image knows better, so it only serves as a check:
# a disagreement is a platform or a layout given wrong, and the image would not
# boot. Run without tool.sh, it is unset and nothing is checked.
resolve_boot_type() {
  local requested

  BOOT_TYPE="$(boot_type_of "${IMAGE}" "${TARGET_PLATFORM}")" \
    || raise "${IMAGE} has no dev.cuos.boot label, so it cannot be told
       which boot chain to write. The system Dockerfiles set it; build the
       image from those, or use the image factory the system image was
       released with."

  if [[ "${BOOT_TYPE}" == "lxc" ]]; then
    raise "${IMAGE} is a system image for LXC, which is exported, not written
       to a disk. Build it with --platform lxc."
  fi

  LAYOUT="$(layout_of "${BOOT_TYPE}")"
  if [[ -n "${TARGET+set}" ]]; then
    requested="$([[ "${TARGET}" == "rpi" ]] && echo "mbr" || echo "gpt")"
    [[ "${requested}" == "${LAYOUT}" ]] || raise "${IMAGE} boots with
       ${BOOT_TYPE} from an ${LAYOUT} disk, but the layout asked for is
       ${requested}. Check --platform and --layout."
  fi

  step "Boot chain: ${BOOT_TYPE} (${LAYOUT})"
}

# The configuration the first boot reads from the boot partition.
write_system_json() {
  cp "${CONFIG_PATH}" "${TARGET_BOOT}/system.json" \
    || raise 120 "Failed to copy system.json onto the boot partition"
}

# The slot, the kernel and the boot files, into the two directories main has
# set as TARGET_ROOT and TARGET_BOOT. The slot is a plain directory: mkfs.btrfs
# makes the subvolumes when the filesystem is built from the tree.
install_system() {
  mkdir -p "${CONTAINER_ROOTFS_FS}" "${TARGET_BOOT}" \
    "${BUILD_DIR}/root/@data/docker" \
    "${BUILD_DIR}/root/@data/dhcp" \
    "${BUILD_DIR}/root/@data/log" \
    "${BUILD_DIR}/root/@swap" \
    || raise "Failed to create the build tree"

  step "Installing the system from ${IMAGE}"
  install_slot
  write_system_json
  step "Slot ${SLOT} installed: ${IMAGE}"
}

partition_image() {
  local size_mb="$1"
  local plan
  read -r -a plan <<<"$(partition_plan "${LAYOUT}")"

  step "Partitioning an image of ${size_mb} MB (${LAYOUT})"
  rm -f "${IMAGE_FILE}"
  truncate -s "${size_mb}M" "${IMAGE_FILE}" || raise "Failed to create ${IMAGE_FILE}"
  parted "${IMAGE_FILE}" --script "${plan[@]}" \
    || raise "Failed to partition ${IMAGE_FILE}"
  partition_numbers "${LAYOUT}"
}

write_boot_partition() {
  local volume_id
  volume_id="$(new_fat_volume_id)"
  read_partition_geometry "${IMAGE_FILE}" "${BOOT_PARTITION_NUM}"

  if [[ "${BOOT_TYPE}" == "grub" ]]; then
    step "Writing the GRUB boot files"
    grub_boot_files "${TARGET_BOOT}" "$(fat_uuid "${volume_id}")" "${BUILD_DIR}"
  fi

  check_boot_reserve "${TARGET_BOOT}" "$(( PART_SECTORS / 2 ))"

  step "Writing the boot partition"
  make_boot_filesystem "${BUILD_DIR}/boot.fat" "${PART_SECTORS}" \
    "${PART_START}" "${volume_id}" "${TARGET_BOOT}"
  write_partition "${IMAGE_FILE}" "${BOOT_PARTITION_NUM}" "${BUILD_DIR}/boot.fat"
  rm -f "${BUILD_DIR}/boot.fat"
}

write_root_partition() {
  local free_mb
  read_partition_geometry "${IMAGE_FILE}" "${ROOT_PARTITION_NUM}"

  step "Writing the root partition"
  make_root_filesystem "${BUILD_DIR}/root.btrfs" "$(( PART_SECTORS * 512 ))" \
    "${BUILD_DIR}/root" "${SLOT}"

  free_mb="$(root_free_mb "${BUILD_DIR}/root.btrfs")" \
    || raise "Could not read the free space of the root filesystem"
  echo "disc usage (root, after install): ${free_mb} MB free"
  if (( free_mb < FIRST_BOOT_FREE_MB )); then
    raise "The root filesystem has ${free_mb} MB free, the first boot is given
       ${FIRST_BOOT_FREE_MB}. lib/size.sh underestimates this system; raise
       image_size_mb until it is fixed."
  fi

  rm -rf "${BUILD_DIR}/root"
  write_partition "${IMAGE_FILE}" "${ROOT_PARTITION_NUM}" "${BUILD_DIR}/root.btrfs"
  rm -f "${BUILD_DIR}/root.btrfs"
}

# What lives outside the partitions.
write_boot_loader() {
  case "${BOOT_TYPE}" in
    grub)
      step "Writing GRUB into the MBR and the bios_grub partition"
      read_partition_geometry "${IMAGE_FILE}" "${BIOS_GRUB_PARTITION_NUM}"
      install_grub_bios "${IMAGE_FILE}" "${PART_START}" "${PART_SECTORS}" \
        "${BUILD_DIR}"
      ;;
    uboot)
      step "Writing U-Boot in front of the first partition"
      read_partition_geometry "${IMAGE_FILE}" 1
      # The root tree is gone by now; install-kernel-uboot.sh copied /boot,
      # u-boot.bin with it, to the boot side.
      install_uboot "${IMAGE_FILE}" "${TARGET_BOOT}/u-boot.bin" \
        "${PART_START}"
      ;;
  esac
}

main() {
  trap cleanup EXIT

  use_handed_in_daemon
  check_output_dir

  BUILD_DIR="$(mktemp -d "${BUILD_ROOT:-"/var/tmp"}/cuos-image.XXXXXX")" \
    || raise "Failed to create a build directory"
  # Read by the updater's steps and by install-kernel-*.sh in the new rootfs.
  export TARGET_ROOT="${BUILD_DIR}/root/@os"
  export TARGET_BOOT="${BUILD_DIR}/boot"

  export OS_ARCH="${OS_ARCH:-"$(arch)"}"
  select_system_image
  fetch_system_image

  if [[ "${OS_ARCH}" == "lxc" ]]; then
    build_lxc_image
    IMAGE_WRITTEN=1
    exit 0
  fi

  # Before anything is installed: the label says which layout to build.
  resolve_boot_type

  set -x
  install_system

  # Not inside "$( )" with partition_image: image_size_mb raises.
  local size_mb
  size_mb="$(image_size_mb "$(du -sk "${BUILD_DIR}/root" | awk '{ print $1 }')")" \
    || exit "$?"
  partition_image "${size_mb}"
  write_boot_partition
  write_root_partition
  write_boot_loader
  set +x

  IMAGE_WRITTEN=1
  step "${IMAGE_FILE#/} written"
  exit 0
}

# Execute main only if script is run, not sourced
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
