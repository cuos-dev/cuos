#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../system/cuos/lib-test.sh"

# shellcheck source=layout.sh
source "${SCRIPT_DIR}/layout.sh"
# shellcheck source=size.sh
source "${SCRIPT_DIR}/size.sh"

rc_of() {
  ( "$@" ) >/dev/null 2>&1
}

# The tree of the v0.6.2 x86_64 system, as du counted it on 2026-10-10.
expect "required_image_size_mb: the measured tree" "1680" \
  required_image_size_mb 722000

# What is left once the filesystem is built has to cover the first boot: the
# tree, its metadata twice and the fixed btrfs cost come first.
room_for_the_first_boot() {
  local size root_mb
  size="$(required_image_size_mb 722000)"
  root_mb="$(( size - ROOT_PARTITION_START_MIB ))"
  (( root_mb - 706 * 110 / 100 - 128 >= FIRST_BOOT_FREE_MB )) && echo "fits"
}
expect "required_image_size_mb: the first boot's room is on top" "fits" \
  room_for_the_first_boot

expect "required_image_size_mb: the first boot's room is a parameter" "1168" \
  eval 'FIRST_BOOT_FREE_MB=0 required_image_size_mb 722000'

expect_rc "required_image_size_mb: an empty tree" 1 \
  rc_of required_image_size_mb 0
expect_rc "required_image_size_mb: an answer that is not a size" 1 \
  rc_of required_image_size_mb "not a number"

summary
