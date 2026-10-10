#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# How large a disk image has to be for the tree that goes into it. Sourced,
# never run.

# Free in the root filesystem of a freshly written image. The first boot writes
# before it grows the partition - /data, the state, the logs - and on a disk no
# larger than the image it never grows at all.
FIRST_BOOT_FREE_MB="${FIRST_BOOT_FREE_MB:-512}"

# $1 is the tree the root filesystem is built from, in KiB as du counts it.
#
# The content is what --rootdir copies, measured; the factor covers btrfs
# metadata, kept twice (DUP), and the 128 MiB its chunk granularity and global
# reserve never give back - a fixed cost, measured on the x86_64 build of
# 2026-09-10.
#
# 256 MiB: the partition table gap plus the boot partition, which both layouts
# put in front of the root partition. Rounded up to 16 MiB, so the number stays
# readable in the build log.
required_image_size_mb() {
  local kb="$1" mb

  [[ "${kb}" =~ ^[0-9]+$ && "${kb}" -gt 0 ]] || return 1

  mb="$(( (kb + 1023) / 1024 ))"
  mb="$(( mb * 110 / 100 ))"           # metadata
  mb="$(( mb + 128 ))"                 # btrfs chunks and global reserve
  mb="$(( mb + FIRST_BOOT_FREE_MB ))"

  echo "$(( 256 + (mb + 15) / 16 * 16 ))"
}
