#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

set -x

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

if [[ ! -f "/system_next.json" ]]; then
  echo "Rollback not possible. No previous system."
  exit 1
fi

VIRT_TYPE="$(systemd-detect-virt)"
if [[ "${VIRT_TYPE}" == "lxc" || "${VIRT_TYPE}" == "docker" ]]; then
  "${SCRIPT_DIR}/do-rollback-lxc.sh" "$@"
  exit "$?"
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

TARGET_BOOT_PARTITION="${TARGET_BOOT_PARTITION:-"LABEL=boot"}"
export TARGET_BOOT="${TARGET_BOOT:-"/mnt/boot"}"

mkdir -p "${TARGET_BOOT}"
mount -t vfat "${TARGET_BOOT_PARTITION}" "${TARGET_BOOT}" || {
  echo "Failed to mount /boot. Is the boot partition available?"
  exit 1
}

CURRENT_SLOT="$(cat "/etc/active_slot" 2>/dev/null || echo "A")"
SLOT="A"
if [[ "${CURRENT_SLOT}" == "A" ]]; then
  SLOT="B"
fi

REASON="$1"
"${SCRIPT_DIR}/dialog.sh" "CRITICAL: Perfoming Rollback to slot ${SLOT}: ${REASON}"

# set update state: Rollback because of ${REASON}"
state '.state' 'rollback'
state jq '.last_update_date = (now | todate)'
state '.update_state' "rollback to slot ${SLOT} (${REASON})"


# The rollback is the last resort: if the boot files cannot be restored, say so
# instead of rebooting into the slot that just failed.
if ! "${SCRIPT_DIR}/install-kernel-rollback.sh" "${SLOT}"; then
  state '.update_state' "rollback to slot ${SLOT} failed (${REASON})"
  sync
  umount "${TARGET_BOOT}" || umount -l "${TARGET_BOOT}" || true
  raise 130 "Failed to restore the boot files for slot ${SLOT}"
fi


sync

umount "${TARGET_BOOT}" || umount -l "${TARGET_BOOT}" || {
    echo "Warning: Failed to unmount ${TARGET_BOOT}. Is it busy?"
}
echo "Boot configuration updated for rollback."

echo "Rebooting ..."
reboot
