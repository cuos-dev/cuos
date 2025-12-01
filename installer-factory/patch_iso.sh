#!/bin/bash

# Call with:
# IMAGE_NAME="" #name of iso file without iso
# docker run -it --rm \
#  --entrypoint /bin/bash \
#  -v ./output:/output \
#  -e "IMAGE_NAME=${IMAGE_NAME}" \
#  ghcr.io/cuos-dev/cuos-installer-factory:development \
#  /update_iso.sh

set -ex

OUTPUT_DIR="/output"

if [[ ! -d "${OUTPUT_DIR}" ]]; then
  echo "Build dir does not exist."
  exit 1
fi

BASE_INSTALLER="${OUTPUT_DIR}/$(basename "$1")"
if [[ -z "${BASE_INSTALLER}" || ! -f "${BASE_INSTALLER}" ]]; then
  echo "Error: Installer ISO not found." >&2
  exit 1
fi

IMAGE_NAME="${IMAGE_NAME:-"installer"}"
INSTALLER="${OUTPUT_DIR}/${IMAGE_NAME}.iso"
CONFIG_PATH="${OUTPUT_DIR}/${IMAGE_NAME}.json"

#xorriso -indev /output/CuOS-IaC-cuos-test.iso -ls /

xorriso \
  -indev "${BASE_INSTALLER}" \
  -outdev "${INSTALLER}" \
  -update "${CONFIG_PATH}" "/system.json" \
  -boot_image any replay \
  -compliance no_emul_toc \
  -padding included
