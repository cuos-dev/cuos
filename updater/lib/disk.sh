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

# Left free once an update is done, so that the system can still boot - and
# write its logs and its state - with both slots in place.
RESERVE_KB="$((300 * 1024))"

# Sets FREE_KB rather than printing it, because it raises.
#
# df -Pk: on a device this runs inside the updater image, which is Alpine
# without coreutils, so df is busybox's. -k is POSIX and needs nothing else;
# busybox 1.37 (Alpine 3.23 and 3.24) also takes -B1, but no promise of POSIX
# covers that. -P keeps the columns on one line.
read_free_kb() {
  FREE_KB="$(df -Pk "${TARGET_ROOT}" | awk 'NR == 2 { print $4 }')"
  [[ "${FREE_KB}" =~ ^[0-9]+$ ]] \
    || raise 100 "Could not read the free space of ${TARGET_ROOT}: df -Pk gave \"${FREE_KB}\""
}

# $1 is what the update needs in KiB, $2 says where that number comes from.
# With $3 "standby" the standby slot counts as freed: that is the state once it
# has been deleted, and only true of a step that runs after the deletion.
# Docker's data root (/data/docker) and the slots (@os) are subvolumes of one
# filesystem, so the free space of TARGET_ROOT is the room for both.
require_space() {
  local needed_kb="$1"
  local basis="$2"
  local standby_kb=0
  local left_kb

  read_free_kb
  if [[ "${3:-}" == "standby" ]]; then
    standby_kb="$(standby_slot_kb)"
  fi
  left_kb="$(( FREE_KB + standby_kb - needed_kb ))"

  echo "space: ${FREE_KB} KiB free, ${standby_kb} KiB freed from slot ${SLOT}, ${needed_kb} KiB needed (${basis}), ${left_kb} KiB left"
  if (( left_kb < RESERVE_KB )); then
    raise 101 "Not enough free space in ${TARGET_ROOT}: the update would leave $(( left_kb / 1024 )) MB, it has to leave $(( RESERVE_KB / 1024 )) MB. Aborting update."
  fi
}

# Before the pull nothing about the new image is known, so it is taken to be as
# large as the one running now. The pull puts it into docker's storage while
# the standby slot is still there, so the download has to fit beside it. An
# update then unpacks it a second time, into the slot it has deleted by then;
# $1 "pull" stops before that.
#
# An active image the daemon does not know - an updater that had to bring its
# own daemon, or an image removed by hand - leaves nothing to estimate from. The
# flat rule of earlier releases stands in for it: more than 2 GB free.
check_space_before_pull() {
  local action="${1:-update}"
  local active active_kb

  if target_is_local; then
    echo "space: ${IMAGE} is here already, checked once it is unpacked"
    return 0
  fi

  active="$(digest_ref "$(cat "${T_FILE_IMAGE:-"/etc/image"}" 2>/dev/null)")"
  if ! active_kb="$(image_size_kb "${active}")"; then
    read_free_kb
    if (( FREE_KB <= 2 * 1024 * 1024 )); then
      raise 101 "Not enough free space in ${TARGET_ROOT} (required: >2GB, the size of the running image is unknown; available: $(( FREE_KB / 1024 )) MB). Aborting update."
    fi
    return 0
  fi

  require_space "${active_kb}" "the download, estimated from the running image"
  if [[ "${action}" == "update" ]]; then
    require_space "$(( 2 * active_kb ))" "estimated from the running image" standby
  fi
}

# After the pull the image is in docker's storage already, and its size is
# known: what is left to find is the slot it is unpacked into, which an update
# deletes first. A pull ($1 "pull") deletes nothing: it has to leave the reserve
# as it is, and it keeps the image only if a later update can install it.
# Nothing has been deleted yet, so aborting here costs the download and nothing
# else - the image goes again, or the next update would start out with even
# less room.
check_space_after_pull() {
  local action="${1:-update}"
  local new_kb

  new_kb="$(image_size_kb "${IMAGE}")" \
    || raise 100 "Could not read the size of ${IMAGE}"

  local rc
  (
    if [[ "${action}" == "pull" ]]; then
      require_space 0 "the image, fetched"
    fi
    require_space "${new_kb}" "the new image, unpacked" standby
  )
  rc="$?"
  if [[ "${rc}" == "0" ]]; then
    return 0
  fi

  remove_pulled_image
  exit "${rc}"
}
