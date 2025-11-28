#!/bin/bash

set -ex

VOLID="CUOS"
WORKDIR="/build"
ISO_DIR="${WORKDIR}/iso"
OUTPUT_DIR="/output"

if [[ ! -d "${OUTPUT_DIR}" ]]; then
  echo "Build dir does not exist."
  exit 1
fi

export DOCKER_CONTEXT=default
IMAGE_NAME="${IMAGE_NAME:-"installer"}"
INSTALLER="${OUTPUT_DIR}/${IMAGE_NAME}.iso"
IMAGE="${OUTPUT_DIR}/${IMAGE_NAME}.img"

if [[ ! -f "${IMAGE}" ]]; then
  echo "Image file does not exist."
  exit 1
fi

rm -f "${INSTALLER}"

export CONFIG_PATH="${OUTPUT_DIR}/${IMAGE_NAME}.json"

# compress image using zstd (multi-threaded, level 9) and copy to the ISO dir
# choose level 9 as a balance between compression ratio and build time; adjust as desired
zstd -T0 -9 -c "${IMAGE}" > "${ISO_DIR}/image.img.zst"

if [[ -f "${CONFIG_PATH}" ]]; then
  cp "${CONFIG_PATH}" "${ISO_DIR}/system.json"

  if jq -e '.installer_auto_overwrite_disk == true' "${CONFIG_PATH}" > /dev/null; then
    touch "${ISO_DIR}/installer_auto_overwrite_disk.txt"
  fi

fi

grub-mkrescue \
  -o "${INSTALLER}" \
  -V "${VOLID}" \
  -iso-level 3 \
  -full-iso9660-filenames \
  "${ISO_DIR}" || exit 1

echo "ISO creation complete."
echo "Installer written to ${INSTALLER/\//}"
