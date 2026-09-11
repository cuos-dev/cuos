#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

docker() {
  [[ -n "${MOCK_IMAGE_BYTES-}" ]] || return 1
  echo "${MOCK_IMAGE_BYTES}"
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../system/cuos/lib-test.sh"

# shellcheck source=size.sh
source "${SCRIPT_DIR}/size.sh"

rc_of() {
  ( "$@" ) >/dev/null 2>&1
}

# The x86_64 build of 2026-09-10, which was written at 1636 MB and used 733.8
# MiB of its 1379 MiB root partition.
MOCK_IMAGE_BYTES="731000000"
expect "required_image_size_mb: the measured build" "1200" \
  required_image_size_mb "ghcr.io/cuos-dev/cuos-system:development"

# The margin has to stay above what that build actually used: 256 MiB in front
# of a root partition, and 733.8 MiB written into it.
room_for_the_measured_rootfs() {
  local size
  size="$(required_image_size_mb x)"
  (( size - 256 > 734 )) && echo "fits"
}
expect "required_image_size_mb: the measured rootfs fits" "fits" \
  room_for_the_measured_rootfs

MOCK_IMAGE_BYTES="1462000000"
expect "required_image_size_mb: twice the image" "2016" \
  required_image_size_mb x

MOCK_IMAGE_BYTES=""
expect_rc "required_image_size_mb: an image docker does not know" 1 \
  rc_of required_image_size_mb "ghcr.io/cuos-dev/nothing:here"

MOCK_IMAGE_BYTES="not a number"
expect_rc "required_image_size_mb: an answer that is not a size" 1 \
  rc_of required_image_size_mb x

summary
