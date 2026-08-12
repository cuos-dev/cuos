#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

set -x

SLOT="$1"
# from exports:
# TARGET_BOOT
# TARGET_DEVICE


if [[ -d "${TARGET_BOOT}"/firmware_prev ]]; then
  mkdir -p "${TARGET_BOOT}/firmware_next"
  mv "${TARGET_BOOT}"/{bcm27*.dtb,bootcode.bin,fixup*.dat,LICENCE.broadcom,config.txt,initramfs*,kernel*.img,overlays,start*.elf} "${TARGET_BOOT}/firmware_next/"
  mv "${TARGET_BOOT}"/firmware_prev/* "${TARGET_BOOT}/"
  rm -Rf "${TARGET_BOOT}/firmware_prev"
  mv "${TARGET_BOOT}/firmware_next" "${TARGET_BOOT}/firmware_prev"
fi

