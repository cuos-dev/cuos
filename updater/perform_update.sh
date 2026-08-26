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
OLD_SLOT="B"
# $1 is current slot:
if [[ "$1" = "A" ]]; then
  SLOT="B"
  OLD_SLOT="A"
fi

IMAGE="${2}"
IMAGE_DIGEST="${3:-""}"

PRODUCT_NAME="CuOS"
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

CONTAINER_NAME_OLD="dockerboot-container-${SLOT}"
CONTAINER_NAME="cuos-system-${SLOT}"

# Remove old slot:
rm -f "${TARGET_BOOT}/${SLOT}"_* || true

docker rm -f "${CONTAINER_NAME_OLD}" >/dev/null 2>/dev/null || true

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>/dev/null || true

OLD_CONTAINER_NAME="cuos-system-${OLD_SLOT}"
if OLD_IMAGE_PATH="$(docker inspect --format='{{.Image}}' "${OLD_CONTAINER_NAME}")"; then
  docker image rm "${OLD_IMAGE_PATH}" || true
fi

# Load new image
docker image pull "${IMAGE}" >/dev/null \
  || raise 103 "Faild to fetch system image"
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

DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}" | cut -d '@' -f 2) \
  || raise 105 "Failed to get image digest"

docker run -it -d \
  --pull=never \
  --network=none \
  --restart=always \
  --name "${CONTAINER_NAME}" \
  "${IMAGE}" || raise 106 "Failed to run container"
docker exec "${CONTAINER_NAME}" /usr/local/cuos/first-run.sh "${SLOT}" "${IMAGE}" "${DIGEST}" \
  || raise 107 "Failed to run first-run script in container"

# Copy latest kernel and initrd to boot slot
kernel=$(docker exec "${CONTAINER_NAME}" bash -c 'ls /boot/vmlinuz-*' 2>/dev/null | sort -V | tail -n1) \
  || raise 108 "Faild to detect kernel file"
initrd=$(docker exec "${CONTAINER_NAME}" bash -c 'ls /boot/initrd.img-*' 2>/dev/null | sort -V | tail -n1) \
  || raise 109 "Faild to detect initrd file"

if [[ -z "${kernel}" ]]; then
  raise 110 "No matching kernel file found."
fi
if [[ -z "${initrd}" ]]; then
  raise 111 "No matching initrd file found."
fi

filename_kernel="${SLOT}_$(basename "${kernel}")"
filename_initrd="${SLOT}_$(basename "${initrd}")"

if [[ "${OS_ARCH}" == "rpi"* ]]; then
  rm -Rf "${TARGET_BOOT}/firmware_prev" || true
  mkdir -p "${TARGET_BOOT}/firmware_prev" || true
  mv "${TARGET_BOOT}"/{bcm27*.dtb,bootcode.bin,fixup*.dat,LICENCE.broadcom,config.txt,initramfs*,kernel*.img,overlays,start*.elf} "${TARGET_BOOT}/firmware_prev/" 2>/dev/null || true
  docker cp "${CONTAINER_NAME}:/boot/firmware/." "${TARGET_BOOT}" \
    || raise 112 "Failed to copy kernel"

else

  docker cp "${CONTAINER_NAME}":"${kernel}" "${TARGET_BOOT}/${filename_kernel}" \
    || raise 113 "Failed to copy kernel"
  docker cp "${CONTAINER_NAME}":"${initrd}" "${TARGET_BOOT}/${filename_initrd}" \
    || raise 114 "Failed to copy initrd"

fi

echo "disc free (boot): $(df -h "${TARGET_BOOT}" | tail -n 1)"

# Get container information
CONTAINER_ID="$(docker inspect --format '{{ .Id }}' "${CONTAINER_NAME}")" \
  || raise 115 "Failed to get container id"

if [ -z "${CONTAINER_ID}" ]; then
  raise 116 "Container not found: ${CONTAINER_NAME}"
fi

CONTAINER_ROOTFS_FS="$(jq -r '.config.rootfs' \
  "/var/run/docker/runtime-runc/moby/${CONTAINER_ID}/state.json")" \
  || raise 117 "Failed to get container rootfs"

if [ -z "${CONTAINER_ROOTFS_FS}" ]; then
  raise 118 "Rootfs not found: ${CONTAINER_NAME}"
fi

CONTAINER_ROOTFS="@os/docker/${CONTAINER_ROOTFS_FS#"${DOCKER_DIR}/"}"

cat <<EOF >/etc/fstab
# <file system> <dir> <type> <options> <dump> <pass>
# /dev/sda3
LABEL=system  /  btrfs  rw,relatime,discard=async,space_cache=v2,subvol=${CONTAINER_ROOTFS}  0 0

LABEL=system  /data  btrfs  rw,relatime,discard=async,space_cache=v2,subvol=@data  0 0

# /dev/sda2
#LABEL=boot  /boot  vfat  rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro  0 2
EOF

docker cp /etc/fstab "${CONTAINER_NAME}:/etc/fstab" \
  || raise 119 "Failed to copy fstab"


if [[ "${INSTALLIMAGE}" = "true" ]]; then
  if [[ -f "${CONFIG_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${TARGET_BOOT}/system.json" \
      || raise 120 "Failed to copy system.json from dir"
  else
    docker cp "${CONTAINER_NAME}:/usr/local/cuos/system-default.json" "${TARGET_BOOT}/system.json" \
      || raise 121 "Failed to copy system.json from container"
  fi


  if [[ "${OS_ARCH}" != "rpi"* ]]; then
    # Install GRUB
    mkdir -p "${TARGET_BOOT}/EFI/BOOT"
    grub-install \
      --target=x86_64-efi \
      --efi-directory="${TARGET_BOOT}" \
      --boot-directory="${TARGET_BOOT}" \
      --removable \
      --no-nvram \
      --root-directory="${CONTAINER_ROOTFS_FS}" \
      "${TARGET_DEVICE}" \
      || raise 122 "Failed to install grub (UEFI)"
    grub-install \
      --target=i386-pc \
      --boot-directory="${TARGET_BOOT}" \
      --root-directory="${CONTAINER_ROOTFS_FS}" \
      "${TARGET_DEVICE}" \
      || raise 123 "Failed to install grub"

    echo "disc free (boot): $(df -h "${TARGET_BOOT}" | tail -n 1)"

  fi
fi

version="$(basename "${kernel}" | sed 's/vmlinuz-//')"

if [[ "${OS_ARCH}" == "rpi"* ]]; then

  mv "${TARGET_BOOT}"/cmdline.txt "${TARGET_BOOT}"/cmdline-previous.txt 2>/dev/null || true

  cat <<EOF > "${TARGET_BOOT}/cmdline.txt"
console=serial0,115200 console=tty1 rootwait root=LABEL=system rootfstype=btrfs rootflags=subvol=${CONTAINER_ROOTFS} fsck.repair=yes ro loglevel=3 noresume apparmor=0
EOF

  # Attach options from system.json
  if [[ -f "${CONFIG_PATH}" ]]; then
    jq -r '
      .rpi_firmware_config
      | if . == null then ""
        elif type=="array" then join("\n")
        else . end
    ' "${CONFIG_PATH}" >>"${TARGET_BOOT}/config.txt"
  fi

  echo "PI configuration updated for kernel version $version."

else
  # Generate GRUB entry
  SLOT_NAME="${PRODUCT_NAME} Slot ${SLOT} - Linux $version"
  ( cat <<EOF > "${TARGET_BOOT}/${SLOT}_grub.cfg"
menuentry '${SLOT_NAME}' --unrestricted {
    insmod gzio
    insmod part_gpt
    insmod fat
    insmod btrfs

    search --no-floppy --label boot --set=root

    linux /${filename_kernel} root=LABEL=system rootfstype=btrfs rootflags=subvol=${CONTAINER_ROOTFS} ro loglevel=3 noresume apparmor=0
    initrd /${filename_initrd}
}

EOF
  ) || raise 124 "Failed to configure grub (slot)"


  (
    {
      cat <<EOF
set timeout=1
load_video
set gfxpayload=keep

set superusers="root"
# No user set, so no authentication possible
#password root password

EOF
      cat "${TARGET_BOOT}"/{A,B}_grub.cfg 2>/dev/null

      echo "set default='${SLOT_NAME}'"
    } > "${TARGET_BOOT}/grub/grub.cfg"
  ) || raise 125 "Failed to configure grub"

  echo "GRUB configuration updated for kernel version $version."

fi
