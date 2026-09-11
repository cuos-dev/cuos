#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# The two partitions an update writes to. Sourced, never run.

target_mount() {
  mkdir -p "${TARGET_ROOT}"
  mount -t btrfs -o subvol=@os "${TARGET_ROOT_PARTITION}" "${TARGET_ROOT}" \
    || raise 91 "Could not mount @os subvolume"

  mkdir -p "${TARGET_BOOT}"
  # The charset is the kernel's own. A vfat mount that names one the running
  # kernel has no NLS table for is refused outright ("IO charset ... not found"),
  # and which tables a kernel carries is not something this script can know: the
  # Armbian sunxi64 kernel of the Orange Pi Zero 3 has no nls_ascii. The boot
  # partition holds ASCII names only, so nothing here depends on the choice.
  mount -t vfat -o "rw,relatime,fmask=0022,dmask=0022,shortname=mixed,errors=remount-ro" \
    "${TARGET_BOOT_PARTITION}" "${TARGET_BOOT}" \
    || raise 92 "Could not mount boot partition"
}

target_umount() {
  sync
  umount -R "${TARGET_ROOT}" 2>/dev/null || true
  umount -R "${TARGET_BOOT}" 2>/dev/null || true
}

# prepare_slot deletes "${TARGET_BOOT}/${SLOT}"_* and creates a subvolume under
# TARGET_ROOT. Both are destructive at the wrong path if the caller has not
# mounted what it says it has.
check_environment() {
  [[ -n "${IMAGE}" ]] \
    || raise 100 "No image to install given"
  mountpoint -q "${TARGET_ROOT}" \
    || raise 100 "TARGET_ROOT (${TARGET_ROOT}) is not a mounted filesystem"
  mountpoint -q "${TARGET_BOOT}" \
    || raise 100 "TARGET_BOOT (${TARGET_BOOT}) is not a mounted filesystem"
}
