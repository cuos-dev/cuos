#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# Call with:
# IMAGE_NAME="new_installer" #name of iso file without iso
# echo $NEW_CONFIG >output/new_installer.json
# docker run -it --rm \
#  --entrypoint /bin/bash \
#  -v ./output:/output \
#  -e "IMAGE_NAME=${IMAGE_NAME}" \
#  ghcr.io/cuos-dev/cuos-installer-factory:development \
#  /update_iso.sh "existing_installer.iso"

set -ex

OUTPUT_DIR="/output"

if [[ ! -d "${OUTPUT_DIR}" ]]; then
  echo "Build dir does not exist."
  exit 1
fi

# The base ISO is mounted into the container at a path of its own - tool.sh
# mounts it read-only at /base.iso - so the given path is used as-is.
BASE_INSTALLER="$1"
if [[ -z "${BASE_INSTALLER}" ]]; then
  echo "Error: No base installer ISO given." >&2
  exit 1
fi
if [[ ! -f "${BASE_INSTALLER}" ]]; then
  echo "Error: Installer ISO not found: ${BASE_INSTALLER}" >&2
  exit 1
fi

IMAGE_NAME="${IMAGE_NAME:-"installer"}"
INSTALLER="${OUTPUT_DIR}/${IMAGE_NAME}.iso"
CONFIG_PATH="${OUTPUT_DIR}/${IMAGE_NAME}.json"

# xorriso reads -indev and writes -outdev. If they resolve to the same file the
# result is undefined. The output name is derived from the configuration, so
# deriving from an ISO built with that same configuration lands on its own path.
if [[ "$(realpath "${BASE_INSTALLER}")" == "$(realpath -m "${INSTALLER}")" ]]; then
  echo "Error: base installer and output are the same file: ${INSTALLER}" >&2
  echo "       This writes a new ISO; it does not modify the base one." >&2
  exit 1
fi

#xorriso -indev /output/CuOS-IaC-cuos-test.iso -ls /

xorriso \
  -indev "${BASE_INSTALLER}" \
  -outdev "${INSTALLER}" \
  -update "${CONFIG_PATH}" "/system.json" \
  -boot_image any replay \
  -compliance no_emul_toc \
  -padding included

echo "ISO patching complete."
echo "Installer written to ${INSTALLER/\//}"
