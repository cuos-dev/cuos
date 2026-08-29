#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

set -x

# shellcheck disable=SC2034  # unused here, but every install-kernel-* takes the
# slot as its first argument and the callers pass it uniformly.
SLOT="$1"
# from exports:
# TARGET_BOOT
# TARGET_DEVICE


rm -Rf "${TARGET_BOOT}/firmware_prev" || true
mkdir -p "${TARGET_BOOT}/firmware_prev" || true
mv "${TARGET_BOOT}"/{bcm27*.dtb,bootcode.bin,fixup*.dat,LICENCE.broadcom,config.txt,initramfs*,kernel*.img,overlays,start*.elf} "${TARGET_BOOT}/firmware_prev/" 2>/dev/null || true
cp -r "${ROOT}/boot/firmware/." "${TARGET_BOOT}" \
  || raise 112 "Failed to copy kernel"

echo "disc free (boot): $(df -h "${TARGET_BOOT}" | tail -n 1)"


if [[ "${INSTALLIMAGE:-}" = "true" ]]; then
  if [[ -f "${CONFIG_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${TARGET_BOOT}/system.json" \
      || raise 120 "Failed to copy system.json from dir"
  else
    cp "${ROOT}/usr/local/cuos/system-default.json" "${TARGET_BOOT}/system.json" \
      || raise 121 "Failed to copy system.json from container"
  fi
fi

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

echo "PI configuration updated."

