#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

set -x

SLOT="$1"
# from exports:
# TARGET_BOOT
# TARGET_DEVICE

#
# Three steps:
# 1) Partioning (grub, u-boot/rpi)
# 2) Fill /boot (grub, u-boot/rpi)
# 3) Install bootloader (grub, u-boot)

GRUB_CFG_PATH="${TARGET_BOOT}/grub/grub.cfg"

SLOT_NAME="$(grep "menuentry " "${TARGET_BOOT}/${SLOT}_grub.cfg" | head -n 1 | cut -d "'" -f 2)"
if [[ -z "${SLOT_NAME}" ]]; then
  SLOT_NAME=1
  if [[ "${SLOT}" == "A" ]]; then
    SLOT_NAME=0
  fi
fi

{
  cat <<EOF
set timeout=1
load_video
set gfxpayload=keep

set superusers="root"
# No user set, so no authentication possible                                    #password root password

EOF
  cat "${TARGET_BOOT}"/{A,B}_grub.cfg 2>/dev/null

  echo "set default=\"${SLOT_NAME}\""
} > "$GRUB_CFG_PATH"

