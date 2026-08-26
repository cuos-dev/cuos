#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

set -x

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

# Check parameters:
SLOT="A"
# $1 is current slot:
if [[ "$1" = "A" ]]; then
  SLOT="B"
fi

IMAGE="${2}"
IMAGE_DIGEST="${3:-""}"

export PRODUCT_NAME="CuOS"
if [[ -f "${CONFIG_PATH}" ]]; then
  PRODUCT_NAME="$(jq -r '.product_name // empty' "${CONFIG_PATH}")"
  if [[ -z "${PRODUCT_NAME}" ]]; then
    if jq -r '.init_image' "${CONFIG_PATH}" | grep -q 'cuos-iac'; then
      PRODUCT_NAME="CuOS IaC"
    else
      PRODUCT_NAME="CuOS"
    fi
  fi
fi


if [[ "${INSTALLIMAGE}" != "true" ]]; then
  # Only perform update if available space in TARGET_ROOT is >2GB
  AVAIL_BYTES=$(df -B1 "${TARGET_ROOT}" | awk 'NR==2 {print $4}')
  REQUIRED_BYTES=$((2 * 1024 * 1024 * 1024))
  if [ "$AVAIL_BYTES" -le "$REQUIRED_BYTES" ]; then
    echo "Not enough free space in ${TARGET_ROOT} (required: >2GB, available: $((AVAIL_BYTES/1024/1024)) MB). Aborting update." >&2
    raise 101 "Not enough free space in ${TARGET_ROOT} (required: >2GB, available: $((AVAIL_BYTES/1024/1024)) MB). Aborting update."
  fi
fi

if [[ -n "${OS_ARCH}" ]]; then
  case "${OS_ARCH}" in
    x86_64)
      TARGET_PLATFORM="linux/amd64"
      ;;
    aarch64)
      TARGET_PLATFORM="linux/arm64"
      ;;
    armv7l)
      TARGET_PLATFORM="linux/arm/v7"
      ;;
    armv6l)
      TARGET_PLATFORM="linux/arm/v6"
      ;;
    i686)
      TARGET_PLATFORM="linux/386"
      ;;
    rpi-arm64)
      TARGET_PLATFORM="linux/arm64"
      ;;
    *)
      echo "Unknown architecture: ${OS_ARCH}"
      exit 1
      ;;
  esac
fi

TARGET_PLATFORM="${TARGET_PLATFORM:-"$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')"}"
if [[ "${TARGET_PLATFORM}" = "linux/arm" ]]; then
  TARGET_PLATFORM="linux/arm/v7"
fi

CONTAINER_ROOTFS_FS="${TARGET_ROOT}/system-${SLOT}"
# Consumed by the install-kernel-*.sh scripts inside the new rootfs:
export CONTAINER_ROOTFS="@os/system-${SLOT}"

# Remove old slot:
OLD_IMAGE_PATH="$(grep -oE '^[^@]+' "${CONTAINER_ROOTFS_FS}/etc/image" 2>/dev/null)"
if [[ -d "${CONTAINER_ROOTFS_FS}" ]]; then
  # Delete old Image if existing
  docker image rm --platform "${TARGET_PLATFORM}" "${OLD_IMAGE_PATH}" || true

  btrfs subvolume delete -R "${CONTAINER_ROOTFS_FS}" || true
fi
rm -f "${TARGET_BOOT}/${SLOT}"_* || true

btrfs subvolume create "${CONTAINER_ROOTFS_FS}"


# Load new image
if [[ "${INSTALLIMAGE}" != "true" || "${IMAGE}" != *:build ]]; then
  docker image pull --platform "${TARGET_PLATFORM}" "${IMAGE}" \
    || raise 103 "Faild to fetch system image"
fi
NEW_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}" 2>/dev/null | cut -d '@' -f 2)

if [[ -n "${IMAGE_DIGEST}" && "${IMAGE_DIGEST}" != "${NEW_DIGEST}" ]]; then
  raise 104 "Image digest mismatch: ${IMAGE_DIGEST} != ${NEW_DIGEST}"
fi

IMAGE_VERSION_STRING="${IMAGE}@${NEW_DIGEST}"

if [[ "${IMAGE_VERSION_STRING}" == "$(cat /etc/image 2>/dev/null)" ]]; then
  raise_info 102 "No OS update available"
fi

echo "INFO: Updating OS slot ${SLOT} to ${IMAGE}"

echo "disc free (root): $(df -h "${DOCKER_DIR}" | tail -n 1)"

DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}" 2>/dev/null | cut -d '@' -f 2)
DIGEST="${DIGEST:-"$(docker inspect --format='{{.Id}}' "${IMAGE}")"}"
if [[ -z "${DIGEST}" ]]; then
  raise 105 "Failed to get image digest"
fi



CONTAINER="$(docker create --platform "${TARGET_PLATFORM}" "${IMAGE}")" \
  || raise 106 "Failed to create container for export"
if ! docker export "${CONTAINER}" | (cd "${CONTAINER_ROOTFS_FS}" && tar xf -); then
  raise 107 "Failed to export the container"
fi
docker rm "${CONTAINER}" \
  || raise 108 "Failed to remove the container"

rm -f "${CONTAINER_ROOTFS_FS}/.dockerenv" || true



cat <<EOF >/etc/fstab
# <file system> <dir> <type> <options> <dump> <pass>
# /dev/sda3
LABEL=system  /  btrfs  rw,relatime,discard=async,space_cache=v2,subvol=${CONTAINER_ROOTFS}  0 0

LABEL=system  /data  btrfs  rw,relatime,discard=async,space_cache=v2,subvol=@data  0 0

# /dev/sda2
#LABEL=boot  /boot  vfat  rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro  0 2
EOF

cp /etc/fstab "${CONTAINER_ROOTFS_FS}/etc/fstab" \
  || raise 119 "Failed to copy fstab"



ROOT="${CONTAINER_ROOTFS_FS}" "${CONTAINER_ROOTFS_FS}/usr/local/cuos/first-run.sh" \
  "${SLOT}" "${IMAGE}" "${DIGEST}" \
  || raise 107 "Failed to run first-run script in container"


ROOT="${CONTAINER_ROOTFS_FS}" "${CONTAINER_ROOTFS_FS}/usr/local/cuos/install-kernel.sh" "${SLOT}" \
  || exit "$?"


echo "disc free (boot): $(df -h "${TARGET_BOOT}" | tail -n 1)"


if [[ "${INSTALLIMAGE}" = "true" ]]; then
  if [[ -f "${CONFIG_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${TARGET_BOOT}/system.json" \
      || raise 120 "Failed to copy system.json from dir"
  else
    cp "${CONTAINER_ROOTFS_FS}/usr/local/cuos/system-default.json" "${TARGET_BOOT}/system.json" \
      || raise 121 "Failed to copy system.json from container"
  fi
fi

