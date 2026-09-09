#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

set -ex

# One line per step of the build, marked for whoever is running this factory.
# cuos-release/tool.sh passes lines carrying this marker through to the terminal
# and puts everything else in output/NAME.build.log; run directly, the marker is
# just a prefix. Keep it in step with log_is_step_line() over there.
step() {
  echo "==> $*"
}

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
step "Compressing the system image"
zstd -T0 -9 -c "${IMAGE}" > "${ISO_DIR}/image.img.zst"

PRODUCT_NAME="CuOS"
if [[ -f "${CONFIG_PATH}" ]]; then
  cp "${CONFIG_PATH}" "${ISO_DIR}/system.json"

  if jq -e '.installer_auto_overwrite_disk == true' "${CONFIG_PATH}" > /dev/null; then
    touch "${ISO_DIR}/installer_auto_overwrite_disk.txt"
  fi

  PRODUCT_NAME="$(jq -r '.product_name // empty' "${CONFIG_PATH}")"
  if [[ -z "${PRODUCT_NAME}" ]]; then
    if jq -r '.init_image' "${CONFIG_PATH}" | grep -q 'cuos-iac'; then
      PRODUCT_NAME="CuOS IaC"
    else
      PRODUCT_NAME="CuOS"
    fi
  fi
fi

# The ISO is written into /output, which is the caller's disk. When that disk is
# full, xorriso reports it as "Image size ... exceeds free space on media",
# which reads like a property of the ISO rather than of the machine it is being
# written on. Say what it is, before the ISO is built and not after.
needed_kb="$(du -sk "${ISO_DIR}" | cut -f1)"
read -r _ _ _ free_kb _ < <(df -Pk "${OUTPUT_DIR}" | tail -n 1)
if ((free_kb < needed_kb + needed_kb / 10)); then
  echo "Not enough free space for ${INSTALLER}:" \
    "the ISO needs about $((needed_kb / 1024)) MB," \
    "$((free_kb / 1024)) MB are free." >&2
  exit 1
fi

step "Building the bootable ISO"
grub-mkrescue \
  -o "${INSTALLER}" \
  -V "${VOLID}" \
  -iso-level 3 \
  -full-iso9660-filenames \
  "${ISO_DIR}" || exit 1

step "${INSTALLER/\//} written"
