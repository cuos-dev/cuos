#!/bin/bash

set -x

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

if [[ ! -f "/system_next.json" ]]; then
  echo "Rollback not possible. No previous system."
  exit 1
fi

VIRT_TYPE="$(systemd-detect-virt)"
if [[ "${VIRT_TYPE}" = "lxc" ]]; then
  "${SCRIPT_DIR}/do-rollback-lxc.sh" "$@"
  exit "$?"
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

OS_ARCH="$(cat /etc/cuos-arch 2>/dev/null || arch)"

TARGET_BOOT_PARTITION="${TARGET_BOOT_PARTITION:-"LABEL=boot"}"
TARGET_BOOT="${TARGET_BOOT:-"/mnt/boot"}"
GRUB_CFG_PATH="${TARGET_BOOT}/grub/grub.cfg"

mkdir -p "${TARGET_BOOT}"
mount -t vfat "${TARGET_BOOT_PARTITION}" "${TARGET_BOOT}" || {
  echo "Failed to mount /boot. Is the boot partition available?"
  exit 1
}

CURRENT_PARTITION="$(cat "/etc/partition_mode" 2>/dev/null || echo "A")"
PARTITION="A"
PARTITION_ID=0
if [[ "${CURRENT_PARTITION}" == "A" ]]; then
  PARTITION="B"
  PARTITION_ID=1
fi

REASON="$1"
"${SCRIPT_DIR}/dialog.sh" "CRITICAL: Perfoming Rollback to partition ${PARTITION}: ${REASON}"

# set update state: Rollback because of ${REASON}"
state '.state' 'rollback'
state jq '.last_update_date = (now | todate)'
state '.update_state' "rollback to partition ${PARTITION} (${REASON})"

if [[ "${OS_ARCH}" == "rpi"* ]]; then

  if [[ -f "${TARGET_BOOT}"/cmdline-previous.txt ]]; then
    mv "${TARGET_BOOT}"/cmdline.txt "${TARGET_BOOT}"/cmdline-tmp.txt
    mv "${TARGET_BOOT}"/cmdline-previous.txt "${TARGET_BOOT}"/cmdline.txt
    mv "${TARGET_BOOT}"/cmdline-tmp.txt "${TARGET_BOOT}"/cmdline-previous.txt
  fi

else
  PARTITION_NAME="$(grep "menuentry " "${TARGET_BOOT}/${PARTITION}_grub.cfg" | head -n 1 | cut -d "'" -f 2)"
  if [[ -z "${PARTITION_NAME}" ]]; then
      PARTITION_NAME="${PARTITION_ID}"
  fi

  {
    cat <<EOF
set timeout=1
load_video
set gfxpayload=keep
EOF
    cat "${TARGET_BOOT}"/{A,B}_grub.cfg 2>/dev/null

    echo "set default=\"${PARTITION_NAME}\""
  } > "$GRUB_CFG_PATH"
fi

sync

umount "${TARGET_BOOT}" || umount -l "${TARGET_BOOT}" || {
    echo "Warning: Failed to unmount ${TARGET_BOOT}. Is it busy?"
}
echo "Boot configuration updated for partition ${PARTITION_NAME}."

echo "Rebooting ..."
reboot
