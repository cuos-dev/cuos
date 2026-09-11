#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# The slot an update is written into. Sourced, never run.

# $1 is the slot in use; the update goes to the other one.
target_slot() {
  if [[ "${1:-}" = "A" ]]; then
    echo "B"
  else
    echo "A"
  fi
}

prepare_slot() {
  local old_image_path
  old_image_path="$(grep -oE '^[^@]+' "${CONTAINER_ROOTFS_FS}/etc/image" 2>/dev/null)"

  if [[ -d "${CONTAINER_ROOTFS_FS}" ]]; then
    if [[ -n "${old_image_path}" ]]; then
      docker image rm --platform "${TARGET_PLATFORM}" "${old_image_path}" || true
    fi

    btrfs subvolume delete -R "${CONTAINER_ROOTFS_FS}" || true
  fi
  rm -f "${TARGET_BOOT}/${SLOT}"_* || true

  btrfs subvolume create "${CONTAINER_ROOTFS_FS}"
}

# Straight into the new rootfs: this describes the target's layout, and nothing
# in the updater or the factory reads an fstab of its own - every mount they
# make names its device and options, and the grub backend writes the root
# filesystem into the kernel command line rather than reading it back.
write_fstab() {
  local fstab_file="${T_FILE_FSTAB:-"${CONTAINER_ROOTFS_FS}/etc/fstab"}"

  cat >"${fstab_file}" <<EOF || raise 119 "Failed to write ${fstab_file}"
# <file system> <dir> <type> <options> <dump> <pass>
# /dev/sda3
LABEL=system  /  btrfs  rw,relatime,discard=async,space_cache=v2,subvol=${CONTAINER_ROOTFS}  0 0

LABEL=system  /data  btrfs  rw,relatime,discard=async,space_cache=v2,subvol=@data  0 0

# /dev/sda2
#LABEL=boot  /boot  vfat  rw,relatime,fmask=0022,dmask=0022,shortname=mixed,errors=remount-ro  0 2
EOF
}

run_first_run() {
  ROOT="${CONTAINER_ROOTFS_FS}" "${CONTAINER_ROOTFS_FS}/usr/local/cuos/first-run.sh" \
    "${SLOT}" "${IMAGE}" "${DIGEST}" \
    || raise 109 "Failed to run first-run script in container"
}

install_kernel() {
  ROOT="${CONTAINER_ROOTFS_FS}" "${CONTAINER_ROOTFS_FS}/usr/local/cuos/install-kernel.sh" "${SLOT}" \
    || exit "$?"
}

copy_system_json() {
  if [[ -f "${CONFIG_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${TARGET_BOOT}/system.json" \
      || raise 120 "Failed to copy system.json from dir"
  else
    cp "${CONTAINER_ROOTFS_FS}/usr/local/cuos/system-default.json" "${TARGET_BOOT}/system.json" \
      || raise 121 "Failed to copy system.json from container"
  fi
}

