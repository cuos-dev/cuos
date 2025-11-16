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
if [[ ! -f "${OUTPUT_DIR}/image.img" ]]; then
  echo "Image file does not exist."
  exit 1
fi

export DOCKER_CONTEXT=default

rm -f "${OUTPUT_DIR}/installer.iso"

# compress image using zstd (multi-threaded, level 9) and copy to the ISO dir
# choose level 9 as a balance between compression ratio and build time; adjust as desired
zstd -T0 -9 -c "${OUTPUT_DIR}/image.img" > "${ISO_DIR}/image.img.zst"

if [[ -f "${OUTPUT_DIR}/system.json" ]]; then
  cp "${OUTPUT_DIR}/system.json" "${ISO_DIR}"

  if jq -e '.installer_auto_overwrite_disk == true' "${OUTPUT_DIR}/system.json" > /dev/null; then
    touch "${ISO_DIR}/installer_auto_overwrite_disk.txt"
  fi

fi

grub-mkrescue \
  -o "${OUTPUT_DIR}/installer.iso" \
  -V "${VOLID}" \
  -iso-level 3 \
  -full-iso9660-filenames \
  "${ISO_DIR}" || exit 1

echo "ISO creation complete."
echo "Installer written to ${OUTPUT_DIR/\//}/installer.iso"
