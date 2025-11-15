#!/bin/bash

set -ex

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

cp "${OUTPUT_DIR}/image.img" "${ISO_DIR}"

VOLID="CUOS"
grub-mkrescue \
  -o "${OUTPUT_DIR}/installer.iso" \
  -V "${VOLID}" \
  -iso-level 3 \
  -full-iso9660-filenames \
  "${ISO_DIR}"

echo "Installer written to ${OUTPUT_DIR/\//}/installer.iso"
