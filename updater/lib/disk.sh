#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# How full a filesystem is, and what that forbids. Sourced, never run.

# -P: POSIX output, one line per filesystem. Without it df puts a device name
# that does not fit on a line of its own and the columns move.
disk_usage() {
  df -Ph "${1:-/}" \
    | awk 'NR == 2 { printf "%s of %s used, %s free\n", $3, $2, $4 }'
}

report_disk_usage() {
  local when="$1"

  echo "disc usage (root, ${when} install): $(disk_usage "${TARGET_ROOT}")"
  # The boot partition is never grown and holds a kernel and an initrd for both
  # slots, so it is the one that can run out.
  echo "disc usage (boot, ${when} install): $(disk_usage "${TARGET_BOOT}")"
}

check_free_space() {
  local avail_bytes required_bytes

  avail_bytes="$(df -P -B1 "${TARGET_ROOT}" | awk 'NR == 2 { print $4 }')"
  [[ "${avail_bytes}" =~ ^[0-9]+$ ]] \
    || raise 100 "Could not read the free space of ${TARGET_ROOT}: df -P -B1 gave \"${avail_bytes}\""
  required_bytes="$((2 * 1024 * 1024 * 1024))"

  if [[ "${avail_bytes}" -le "${required_bytes}" ]]; then
    raise 101 "Not enough free space in ${TARGET_ROOT} (required: >2GB, available: $((avail_bytes/1024/1024)) MB). Aborting update."
  fi
}

# The factory installs one slot, and the first update puts a second one beside
# it on a boot partition that never grows: it is sized once, in
# image-factory/create_image.sh, and no update can repartition the disk it
# runs from. So the moment to find out that two slots do not fit is here, in
# the factory, where the layout can still be changed - on a device it is a
# kernel that cannot be installed any more.
#
# 40 and not 50 percent: the second slot's kernel and initrd are a future
# build, and they will not be smaller than today's.
#
# df -Pk, not -B1: in the factory this is busybox's df, which has no GNU
# block-size options. -P keeps the columns on one line.
check_boot_reserve() {
  local size used percent

  read -r size used <<<"$(df -Pk "${TARGET_BOOT}" | awk 'NR == 2 { print $2, $3 }')"
  [[ "${size}" =~ ^[0-9]+$ && "${used}" =~ ^[0-9]+$ && "${size}" -gt 0 ]] \
    || raise 100 "Could not read the usage of ${TARGET_BOOT}: df -Pk gave \"${size} ${used}\""
  percent="$(( used * 100 / size ))"

  if (( percent > 40 )); then
    raise 115 "${TARGET_BOOT} is ${percent}% full with one slot installed, so
       the second slot will not fit. Give the boot partition more room in
       image-factory/create_image.sh."
  fi
}

