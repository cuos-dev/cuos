#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# pipefail: a failing "docker export" must not be masked by a succeeding tar,
# which would install a truncated rootfs into the target slot.
set -o pipefail

export CONFIG_PATH="${CONFIG_PATH:-"/system.json"}"

raise() {
  local code=1
  local message="$*"

  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    code="${1:-}"
    message="${*:2}"
  fi

  echo "Error: $message" >&2
  exit "$code"
}

raise_info() {
  local code=1
  local message="$*"

  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    code="${1:-}"
    message="${*:2}"
  fi

  echo "Info: $message" >&2
  exit "$code"
}

# Fields counted from the end: df puts a device name that does not fit on a
# line of its own.
disk_usage() {
  df -h "${1:-/}" \
    | awk 'END { printf "%s of %s used, %s free\n", $(NF-3), $(NF-4), $(NF-2) }'
}

report_disk_usage() {
  local when="$1"

  echo "disc usage (root, ${when} install): $(disk_usage "${TARGET_ROOT}")"
  # The boot partition is never grown and holds a kernel and an initrd for both
  # slots, so it is the one that can run out.
  echo "disc usage (boot, ${when} install): $(disk_usage "${TARGET_BOOT}")"
}

# $1 is the slot in use; the update goes to the other one.
target_slot() {
  if [[ "${1:-}" = "A" ]]; then
    echo "B"
  else
    echo "A"
  fi
}

product_name() {
  local name="CuOS"

  if [[ ! -f "${CONFIG_PATH}" ]]; then
    echo "${name}"
    return
  fi

  name="$(jq -r '.product_name // empty' "${CONFIG_PATH}")"
  if [[ -z "${name}" ]]; then
    if jq -r '.init_image' "${CONFIG_PATH}" | grep -q 'cuos-iac'; then
      name="CuOS IaC"
    else
      name="CuOS"
    fi
  fi
  echo "${name}"
}

# prepare_slot deletes "${TARGET_BOOT}/${SLOT}"_* and creates a subvolume under
# TARGET_ROOT. Both are destructive at the wrong path if the caller has not
# mounted what it says it has.
check_environment() {
  [[ -n "${IMAGE}" ]] \
    || raise 100 "No image to install given"
  mountpoint -q "${TARGET_ROOT}" \
    || raise 100 "TARGET_ROOT (${TARGET_ROOT}) is not a mounted filesystem"
  mountpoint -q "${TARGET_BOOT}" \
    || raise 100 "TARGET_BOOT (${TARGET_BOOT}) is not a mounted filesystem"
}

check_free_space() {
  local avail_bytes required_bytes

  avail_bytes="$(df -B1 "${TARGET_ROOT}" | awk 'END { print $(NF-2) }')"
  required_bytes="$((2 * 1024 * 1024 * 1024))"

  if [[ "${avail_bytes}" -le "${required_bytes}" ]]; then
    raise 101 "Not enough free space in ${TARGET_ROOT} (required: >2GB, available: $((avail_bytes/1024/1024)) MB). Aborting update."
  fi
}

target_platform() {
  local arch="${1:-}"
  local platform=""

  case "${arch}" in
    x86_64)
      platform="linux/amd64"
      ;;
    aarch64)
      platform="linux/arm64"
      ;;
    armv7l)
      platform="linux/arm/v7"
      ;;
    armv6l)
      platform="linux/arm/v6"
      ;;
    i686)
      platform="linux/386"
      ;;
    rpi-arm64)
      platform="linux/arm64"
      ;;
    rpi-arm32)
      # ARMv6 so the image also runs on Pi 1 and Zero
      platform="linux/arm/v6"
      ;;
    orangepi-zero3)
      platform="linux/arm64"
      ;;
    "")
      ;;
    *)
      echo "Unknown architecture: ${arch}" >&2
      return 1
      ;;
  esac

  platform="${platform:-"$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')"}"
  if [[ "${platform}" = "linux/arm" ]]; then
    platform="linux/arm/v7"
  fi
  echo "${platform}"
}

# $1 is a digest of ${IMAGE}
image_is_installed() {
  local image_file="${T_FILE_IMAGE:-"/etc/image"}"

  [[ "${IMAGE}@${1}" == "$(cat "${image_file}" 2>/dev/null)" ]]
}

# Asks the registry whether there is anything new, before anything is downloaded
# or deleted. image_is_installed below the pull is the same question, but it can
# only be asked once the image has been pulled - and the pull needs the room
# that deleting the standby slot frees, so by then the slot this system would
# roll back to is already gone. On a small ARM board that costs half an hour and
# the rollback target for an update that turns out to be unnecessary.
#
# imagetools reports the digest of the manifest *list*, which is what docker
# records in RepoDigests after a pull and therefore what /etc/image holds.
# "docker manifest inspect -v" is not a substitute: it reports the digests of
# the individual platform manifests, which are different values (measured on a
# board, 2026-09-06).
#
# Advisory only. An empty answer - no buildx, an unreachable or a
# non-conforming registry - falls through to the pull and changes nothing.
remote_digest_is_installed() {
  local remote_digest
  remote_digest="$(docker buildx imagetools inspect \
    --format '{{.Manifest.Digest}}' "${IMAGE}" 2>/dev/null)"

  [[ -n "${remote_digest}" ]] && image_is_installed "${remote_digest}"
}

repo_digest() {
  docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}" 2>/dev/null \
    | cut -d '@' -f 2
}

# $1 is the digest from the registry, empty for a locally built image: that one
# has no RepoDigests, and its id identifies it just as well.
image_digest() {
  echo "${1:-"$(docker inspect --format='{{.Id}}' "${IMAGE}")"}"
}

prepare_slot() {
  local old_image_path
  old_image_path="$(grep -oE '^[^@]+' "${CONTAINER_ROOTFS_FS}/etc/image" 2>/dev/null)"

  if [[ -d "${CONTAINER_ROOTFS_FS}" ]]; then
    if [[ -n "${old_image_path}" ]]; then
      docker image rm --platform "${TARGET_PLATFORM}" "${old_image_path}" || true
    fi

    btrfs subvolume delete -R "${CONTAINER_ROOTFS_FS}" || true
  fi
  rm -f "${TARGET_BOOT}/${SLOT}"_* || true

  btrfs subvolume create "${CONTAINER_ROOTFS_FS}"
}

# The factory tags the image it has just built ':build' and hands it over
# locally, so there is no registry to pull it from.
is_local_build() {
  [[ "${INSTALLIMAGE}" = "true" && "${IMAGE}" = *:build ]]
}

pull_image() {
  if is_local_build; then return; fi

  docker image pull --platform "${TARGET_PLATFORM}" "${IMAGE}" \
    || raise 103 "Faild to fetch system image"
}

export_rootfs() {
  local container
  container="$(docker create --platform "${TARGET_PLATFORM}" "${IMAGE}")" \
    || raise 106 "Failed to create container for export"

  if ! docker export "${container}" \
      | tar -C "${CONTAINER_ROOTFS_FS}" --numeric-owner --xattrs --xattrs-include='*' -xf -; then
    docker rm "${container}" >/dev/null 2>&1 || true
    raise 107 "Failed to export the container"
  fi
  docker rm "${container}" \
    || raise 108 "Failed to remove the container"

  rm -f "${CONTAINER_ROOTFS_FS}/.dockerenv" || true
}

# Straight into the new rootfs: this describes the target's layout, and nothing
# in the updater or the factory reads an fstab of its own - every mount they
# make names its device and options, and the grub backend writes the root
# filesystem into the kernel command line rather than reading it back.
write_fstab() {
  local fstab_file="${T_FILE_FSTAB:-"${CONTAINER_ROOTFS_FS}/etc/fstab"}"

  cat >"${fstab_file}" <<EOF || raise 119 "Failed to write ${fstab_file}"
# <file system> <dir> <type> <options> <dump> <pass>
# /dev/sda3
LABEL=system  /  btrfs  rw,relatime,discard=async,space_cache=v2,subvol=${CONTAINER_ROOTFS}  0 0

LABEL=system  /data  btrfs  rw,relatime,discard=async,space_cache=v2,subvol=@data  0 0

# /dev/sda2
#LABEL=boot  /boot  vfat  rw,relatime,fmask=0022,dmask=0022,shortname=mixed,errors=remount-ro  0 2
EOF
}

run_first_run() {
  ROOT="${CONTAINER_ROOTFS_FS}" "${CONTAINER_ROOTFS_FS}/usr/local/cuos/first-run.sh" \
    "${SLOT}" "${IMAGE}" "${DIGEST}" \
    || raise 109 "Failed to run first-run script in container"
}

install_kernel() {
  ROOT="${CONTAINER_ROOTFS_FS}" "${CONTAINER_ROOTFS_FS}/usr/local/cuos/install-kernel.sh" "${SLOT}" \
    || exit "$?"
}

copy_system_json() {
  if [[ -f "${CONFIG_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${TARGET_BOOT}/system.json" \
      || raise 120 "Failed to copy system.json from dir"
  else
    cp "${CONTAINER_ROOTFS_FS}/usr/local/cuos/system-default.json" "${TARGET_BOOT}/system.json" \
      || raise 121 "Failed to copy system.json from container"
  fi
}

main() {
  set -x

  SLOT="$(target_slot "${1:-}")"
  IMAGE="${2:-}"
  IMAGE_DIGEST="${3:-""}"

  check_environment

  export PRODUCT_NAME
  PRODUCT_NAME="$(product_name)"

  if [[ "${INSTALLIMAGE}" != "true" ]]; then
    check_free_space
  fi

  TARGET_PLATFORM="$(target_platform "${OS_ARCH}")" || exit 1

  CONTAINER_ROOTFS_FS="${TARGET_ROOT}/system-${SLOT}"
  # Consumed by the install-kernel-*.sh scripts inside the new rootfs:
  export CONTAINER_ROOTFS="@os/system-${SLOT}"

  if [[ "${INSTALLIMAGE}" != "true" ]] && remote_digest_is_installed; then
    raise_info 102 "No OS update available"
  fi

  prepare_slot

  pull_image

  NEW_DIGEST="$(repo_digest)"
  if [[ -n "${IMAGE_DIGEST}" && "${IMAGE_DIGEST}" != "${NEW_DIGEST}" ]]; then
    raise 104 "Image digest mismatch: ${IMAGE_DIGEST} != ${NEW_DIGEST}"
  fi

  if image_is_installed "${NEW_DIGEST}"; then
    raise_info 102 "No OS update available"
  fi

  echo "INFO: Updating OS slot ${SLOT} to ${IMAGE}"

  report_disk_usage "before"

  DIGEST="$(image_digest "${NEW_DIGEST}")"
  if [[ -z "${DIGEST}" ]]; then
    raise 105 "Failed to get image digest"
  fi

  export_rootfs

  write_fstab

  run_first_run

  install_kernel

  report_disk_usage "after"

  if [[ "${INSTALLIMAGE}" = "true" ]]; then
    copy_system_json
  fi

  exit 0
}

# Execute main only if script is run, not sourced
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
