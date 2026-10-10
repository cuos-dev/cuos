#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

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
# Not IMAGE: that is the updater's, the system image perform_update installs.
IMAGE_FILE="${OUTPUT_DIR}/${IMAGE_NAME}.img"
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

# The label has to be read before anything is installed, so the image is pulled
# here. perform_update pulls again, which then costs one question to the
# registry.
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
    || raise "Failed to fetch the system image ${OS_IMAGE}.

       Is the host's daemon handed in, the way tool.sh does it?

         -v /var/run/docker.sock:/run/cuos-docker.sock"
}

# $1 is the size of the tree in KiB.
image_size_mb() {
  local computed configured

  computed="$(required_image_size_mb "${1}")" \
    || raise "Could not compute the image size from \"${1}\" KiB"

  configured="$(jq -r '.image_size_mb // empty' "${CONFIG_PATH}")"
  if [[ -n "${configured}" ]]; then
    if (( configured < computed )); then
      raise "image_size_mb is ${configured}, the system from ${OS_IMAGE} needs
       ${computed} MB. Raise it, or drop it and let the factory compute it."
    fi
    echo "${configured}"
    return
  fi

  echo "${computed}"
}

build_lxc_image() {
  local image_digest

  # The extension, not the first "img" in the path: an image whose name carries
  # those three letters would otherwise be renamed instead of its suffix.
  IMAGE_FILE="${IMAGE_FILE%.img}.tar.gz"

  step "Fetching the system image ${OS_IMAGE}"
  docker image pull "${OS_IMAGE}" || raise "Failed to fetch image"
  image_digest="$(docker inspect --format='{{index .RepoDigests 0}}' \
    "${OS_IMAGE}" 2>/dev/null | cut -d '@' -f 2)"
  if [[ -n "${OS_DIGEST}" && "${OS_DIGEST}" != "${image_digest}" ]]; then
    raise "Image digest mismatch: ${OS_DIGEST} != ${image_digest}"
  fi

  step "Initialising the system"
  LXC_CONTAINER="cuos-lxc-$$"
  docker run -it -d \
    --pull=never \
    --name "${LXC_CONTAINER}" \
    "${OS_IMAGE}" || raise "Failed to run container"
  docker exec "${LXC_CONTAINER}" /usr/local/cuos/first-run.sh \
    "A" "${OS_IMAGE}" "${image_digest}" \
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

  step "${IMAGE_FILE/\//} written"
}

# Sets BOOT_TYPE and LAYOUT from the image's dev.cuos.boot label. An image
# without one writes its boot loader itself, onto a device this factory does
# not have.
#
# TARGET is what tool.sh derives from --layout and the platform. The image knows
# better, so it only serves as a check: a disagreement is a platform or a
# layout given wrong, and the image would not boot.
resolve_boot_type() {
  local platform expected

  platform="$(target_platform "${OS_ARCH}")" || exit 1
  BOOT_TYPE="$(boot_type_of "${OS_IMAGE}" "${platform}")" \
    || raise "${OS_IMAGE} has no dev.cuos.boot label, so it cannot be told
       which boot chain to write. The label is set by the system Dockerfiles
       since this factory came out; build the image from those, or use the
       image factory the system image was released with."

  if [[ "${BOOT_TYPE}" == "lxc" ]]; then
    raise "${OS_IMAGE} is a system image for LXC, which is exported, not written
       to a disk. Build it with --platform lxc."
  fi

  LAYOUT="$(layout_of "${BOOT_TYPE}")"
  if [[ -n "${TARGET+set}" ]]; then
    expected="$([[ "${LAYOUT}" == "mbr" ]] && echo "rpi" || echo "")"
    [[ "${TARGET}" == "${expected}" ]] || raise "${OS_IMAGE} boots with
       ${BOOT_TYPE} from an ${LAYOUT} disk, but the layout asked for is
       '${TARGET:-gpt}'. Check --platform and --layout."
  fi

  step "Boot chain: ${BOOT_TYPE} (${LAYOUT})"
}

# The slot, the kernel and the boot files, into two directories:
# BUILD_DIR/root holds the subvolumes of the root filesystem as directories,
# BUILD_DIR/boot the boot partition.
install_system() {
  export TARGET_ROOT="${BUILD_DIR}/root/@os"
  export TARGET_BOOT="${BUILD_DIR}/boot"
  mkdir -p "${TARGET_ROOT}" "${TARGET_BOOT}" \
    "${BUILD_DIR}/root/@data/docker" \
    "${BUILD_DIR}/root/@data/dhcp" \
    "${BUILD_DIR}/root/@data/log" \
    "${BUILD_DIR}/root/@swap"

  export INSTALLIMAGE=true
  # A file, not a device: the install-kernel-* scripts refuse a block device,
  # which only an older factory hands them.
  export TARGET_DEVICE="${IMAGE_FILE}"

  step "Installing the system from ${OS_IMAGE}"
  perform_update "B" "${OS_IMAGE}" "${OS_DIGEST}"
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
    grub_boot_files "${TARGET_BOOT}" "$(fat_uuid "${volume_id}")"
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
      install_grub_bios "${IMAGE_FILE}" "${PART_START}" "${PART_SECTORS}"
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

  export OS_ARCH="${OS_ARCH:-"$(arch)"}"
  resolve_os_image

  if [[ "${OS_ARCH}" == "lxc" ]]; then
    build_lxc_image
    IMAGE_WRITTEN=1
    exit 0
  fi

  pull_system_image
  resolve_boot_type

  BUILD_DIR="$(mktemp -d "${BUILD_ROOT:-"/var/tmp"}/cuos-image.XXXXXX")" \
    || raise "Failed to create a build directory"

  set -x
  install_system

  # Not partition_image "$(image_size_mb …)": image_size_mb raises when the
  # configured size is too small, and a raise inside "$( )" ends the subshell
  # only - truncate would then be given an empty size.
  local size_mb
  size_mb="$(image_size_mb "$(du -sk "${BUILD_DIR}/root" | awk '{ print $1 }')")" \
    || exit "$?"
  partition_image "${size_mb}"
  write_boot_partition
  write_root_partition
  write_boot_loader
  set +x

  IMAGE_WRITTEN=1
  step "${IMAGE_FILE/\//} written"
  exit 0
}

# Execute main only if script is run, not sourced
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
