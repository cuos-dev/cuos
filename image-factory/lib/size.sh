#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# How large a disk image has to be for the system image it is built from.
# Sourced, never run.

# $1 is the system image, and it has to be local already.
#
# Measured on the x86_64 build of 2026-09-10: .Size 731000000 B = 697.1 MiB, and
# 733.8 MiB used on the filesystem once the slot was installed - factor 1.053.
# .Size is the sum of the uncompressed layers and counts whatever later layers
# replace twice, which offsets 4 KiB block rounding and btrfs DUP metadata
# almost exactly.
#
# Of that build's 1379 MiB root partition, 123 MiB never appeared as available
# at all: btrfs chunk granularity and global reserve. That is a fixed cost, not
# a percentage.
#
# The margin only has to cover the spread between .Size and reality, because
# this is computed on every build.
required_image_size_mb() {
  local bytes mb

  bytes="$(docker image inspect --format '{{.Size}}' "${1}" 2>/dev/null)" \
    || return 1
  [[ "${bytes}" =~ ^[0-9]+$ && "${bytes}" -gt 0 ]] || return 1

  mb="$(( bytes / 1024 / 1024 ))"
  mb="$(( mb * 106 / 100 ))"   # the rootfs as it lands on btrfs
  mb="$(( mb * 110 / 100 ))"   # margin
  mb="$(( mb + 128 ))"         # btrfs chunks and global reserve

  # 256 MiB: the partition table gap plus the boot partition, which both
  # layouts put in front of the root partition. Rounded up to 16 MiB, so the
  # number stays readable in the build log.
  echo "$(( 256 + (mb + 15) / 16 * 16 ))"
}
