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

# What deleting the standby slot gives back. Measured, not assumed: a slot an
# earlier update left half-written holds less than an image. du -x stays inside
# the subvolume, which is a filesystem of its own to it.
standby_slot_kb() {
  local size

  if [[ ! -d "${CONTAINER_ROOTFS_FS}" ]]; then
    echo 0
    return
  fi
  size="$(du -skx "${CONTAINER_ROOTFS_FS}" 2>/dev/null | awk '{ print $1 }')"
  echo "${size:-0}"
}

# The image the standby slot was unpacked from. The slot does not need it - it
# is a copy - so it goes before the pull, to make room, and the slot itself stays
# until the new image is there.
#
# Found by digest, not by name: with an unchanged tag the name has moved on to
# a newer image - the running one, or one fetched by "cuos pull" - and the
# standby's own would be left dangling for good.
#
# Removed by id, not by the digest reference: while a tag still points at the
# image as well (the standby of an update to a new tag), "docker image rm
# name@digest" takes the digest reference away and leaves the image under its
# tag (moby, daemon/images/image_delete.go, read 2026-10-10). By id, every
# reference within its repository goes, and the image with them.
#
# Never the image the active slot runs or the one the update is about to
# install - pinned, or what the registry gave for the tag: after a rollback the
# standby slot holds the newer system, and an update back to it would download
# it again. No "docker image prune": the daemon is the app's as well.
remove_standby_image() {
  local standby active ref id

  standby="$(cat "${CONTAINER_ROOTFS_FS}/etc/image" 2>/dev/null)"
  ref="$(digest_ref "${standby}")" || return 0
  active="$(cat "${T_FILE_IMAGE:-"/etc/image"}" 2>/dev/null)"

  if [[ "${standby##*@}" == "${active##*@}" || "${standby##*@}" == "${IMAGE_DIGEST}" \
      || "${standby##*@}" == "${REMOTE_DIGEST:-}" ]]; then
    return 0
  fi

  id="$(image_id "${ref}")" || return 0
  if [[ -n "${active}" && "${id}" == "$(image_id "$(digest_ref "${active}")")" ]]; then
    return 0
  fi

  docker image rm "${id}" || true
}

# Only once the new image is there: from here on the standby slot is gone, and
# with it the system this one could roll back to.
#
# btrfs gives the space of a deleted subvolume back in the background; the sync
# waits for it, so the export below finds the room the space check counted on.
prepare_slot() {
  if [[ -d "${CONTAINER_ROOTFS_FS}" ]]; then
    btrfs subvolume delete -R "${CONTAINER_ROOTFS_FS}" || true
    btrfs subvolume sync "${TARGET_ROOT}" || true
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

