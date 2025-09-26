#!/bin/bash

set -x

raise() {
  echo "Error: $*" >&2
  exit 1
}

# Check parameters:
PARTITION="A"
# $1 is current partition:
if [[ "$1" = "A" ]]; then
  PARTITION="B"
fi

IMAGE="${2}"
IMAGE_DIGEST="${3:-""}"


if [[ "${INSTALLIMAGE}" != "true" ]]; then
  # Only perform update if available space in TARGET_ROOT is >2GB
  AVAIL_BYTES=$(df -B1 "${TARGET_ROOT}" | awk 'NR==2 {print $4}')
  REQUIRED_BYTES=$((2 * 1024 * 1024 * 1024))
  if [ "$AVAIL_BYTES" -le "$REQUIRED_BYTES" ]; then
    echo "Not enough free space in ${TARGET_ROOT} (required: >2GB, available: $((AVAIL_BYTES/1024/1024)) MB). Aborting update." >&2
    exit 3
  fi
fi

CONTAINER_NAME="dockerboot-container-${PARTITION}"

# Remove old partition:
rm -f "${TARGET_BOOT}/${PARTITION}"_* || true

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>/dev/null && \
  docker image prune -a -f

# Load new image
docker image pull "${IMAGE}" >/dev/null \
  || raise "Faild to fetch system image"
NEW_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}" 2>/dev/null | cut -d '@' -f 2)

if [[ -n "${IMAGE_DIGEST}" && "${IMAGE_DIGEST}" != "${NEW_DIGEST}" ]]; then
  raise "Image digest mismatch: ${IMAGE_DIGEST} != ${NEW_DIGEST}"
fi

IMAGE_VERSION_STRING="${IMAGE}@${NEW_DIGEST}"

if [[ "${IMAGE_VERSION_STRING}" == "$(cat /etc/image 2>/dev/null)" ]]; then
  echo "No new image version available. Exiting."
  exit 2
fi

echo "INFO: Updating OS partition ${PARTITION} to ${IMAGE}"

echo "disc free (root): $(df -h "${DOCKER_DIR}" | tail -n 1)"

DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}" | cut -d '@' -f 2) \
  || raise "Failed to get image digest"

docker run -it -d \
  --pull=never \
  --network=none \
  --restart=always \
  --name "${CONTAINER_NAME}" \
  "${IMAGE}" || raise "Failed to run container"
docker exec "${CONTAINER_NAME}" /usr/local/cuos/first-run.sh "${PARTITION}" "${IMAGE}" "${DIGEST}" \
  || raise "Failed to run first-run script in container"

# Copy latest kernel and initrd to boot partition
kernel=$(docker exec "${CONTAINER_NAME}" bash -c 'ls /boot/vmlinuz-*' 2>/dev/null | sort -V | tail -n1) \
  || raise "Faild to detect kernel file"
initrd=$(docker exec "${CONTAINER_NAME}" bash -c 'ls /boot/initrd.img-*' 2>/dev/null | sort -V | tail -n1) \
  || raise "Faild to detect initrd file"

if [[ -z "${kernel}" ]]; then
  raise "No matching kernel file found."
fi
if [[ -z "${initrd}" ]]; then
  raise "No matching initrd file found."
fi

filename_kernel="${PARTITION}_$(basename "${kernel}")"
filename_initrd="${PARTITION}_$(basename "${initrd}")"

if [[ "${OS_ARCH}" == "rpi"* ]]; then

  docker cp "${CONTAINER_NAME}:/boot/firmware/." "${TARGET_BOOT}" \
    || raise "Failed to copy kernel"

else

  docker cp "${CONTAINER_NAME}":"${kernel}" "${TARGET_BOOT}/${filename_kernel}" \
    || raise "Failed to copy kernel"
  docker cp "${CONTAINER_NAME}":"${initrd}" "${TARGET_BOOT}/${filename_initrd}" \
    || raise "Failed to copy initrd"

fi

echo "disc free (boot): $(df -h "${TARGET_BOOT}" | tail -n 1)"

# Get container information
CONTAINER_ID="$(docker inspect --format '{{ .Id }}' "${CONTAINER_NAME}")" \
  || raise "Failed to get container id"

if [ -z "${CONTAINER_ID}" ]; then
  raise "Container not found: ${CONTAINER_NAME}"
fi

CONTAINER_ROOTFS_FS="$(jq -r '.config.rootfs' \
  "/var/run/docker/runtime-runc/moby/${CONTAINER_ID}/state.json")" \
  || raise "Failed to get container rootfs"

if [ -z "${CONTAINER_ROOTFS_FS}" ]; then
  raise "Rootfs not found: ${CONTAINER_NAME}"
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

docker cp /etc/fstab "${CONTAINER_NAME}:/etc/fstab"

if [[ "${INSTALLIMAGE}" = "true" ]]; then
  if [[ -f "/output/system.json" ]]; then
    cp "/output/system.json" "${TARGET_BOOT}/system.json" \
      || raise "Failed to copy system.json from dir"
  else
    docker cp "${CONTAINER_NAME}:/usr/local/cuos/system-default.json" "${TARGET_BOOT}/system.json" \
      || raise "Failed to copy system.json from container"
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
      || raise "Failed to install grub (UEFI)"
    grub-install \
      --target=i386-pc \
      --boot-directory="${TARGET_BOOT}" \
      --root-directory="${CONTAINER_ROOTFS_FS}" \
      "${TARGET_DEVICE}" \
      || raise "Failed to install grub"

    echo "disc free (boot): $(df -h "${TARGET_BOOT}" | tail -n 1)"

  fi
fi

version="$(basename "${kernel}" | sed 's/vmlinuz-//')"

if [[ "${OS_ARCH}" == "rpi"* ]]; then

  mv "${TARGET_BOOT}"/cmdline.txt "${TARGET_BOOT}"/cmdline-previous.txt

  cat <<EOF > "${TARGET_BOOT}/cmdline.txt"
console=serial0,115200 console=tty1 rootwait root=LABEL=system rootfstype=btrfs rootflags=subvol=${CONTAINER_ROOTFS} fsck.repair=yes ro loglevel=3 noresume apparmor=0
EOF

  echo "PI configuration updated for kernel version $version."

else
  # Generate GRUB entry
  ( cat <<EOF > "${TARGET_BOOT}/${PARTITION}_grub.cfg"
menuentry 'CuOS Partition ${PARTITION} - Linux $version' {
    insmod gzio
    insmod part_gpt
    insmod fat
    insmod btrfs

    search --no-floppy --label boot --set=root

    linux /${filename_kernel} root=LABEL=system rootfstype=btrfs rootflags=subvol=${CONTAINER_ROOTFS} ro loglevel=3 noresume apparmor=0
    initrd /${filename_initrd}
}

EOF
  ) || raise "Failed to configure grub (partition)"


  (
    {
      cat <<EOF
set timeout=1
load_video
set gfxpayload=keep
EOF
      cat "${TARGET_BOOT}"/{A,B}_grub.cfg 2>/dev/null

      echo "set default=\"CuOS Partition ${PARTITION} - Linux $version\""
    } > "${TARGET_BOOT}/grub/grub.cfg"
  ) || raise "Failed to configure grub"

  echo "GRUB configuration updated for kernel version $version."

fi
