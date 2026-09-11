#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

export OUTPUT_DIR="${WORK_DIR}/output"
export IMAGE_NAME="test-image"
mkdir -p "${OUTPUT_DIR}"

docker() {
  case "$*" in
    *"image inspect"*) echo "${MOCK_IMAGE_BYTES-731000000}" ;;
    *"image pull"*) echo "pull $*" >>"${WORK_DIR}/docker.log" ;;
    version*) echo "linux/amd64" ;;
  esac
  return 0
}

# shellcheck source=../system/cuos/lib-test.sh
source "${SCRIPT_DIR}/../system/cuos/lib-test.sh"

# shellcheck source=create_image.sh
source "${SCRIPT_DIR}/create_image.sh"

rc_of() {
  ( "$@" ) >/dev/null 2>&1
}

expect "partition_plan: gpt" \
  "mklabel gpt mkpart bios_boot 1MiB 3MiB set 1 bios_grub on mkpart ESP fat32 3MiB 256MiB set 2 boot on mkpart primary btrfs 256MiB 100%" \
  partition_plan ""

expect "partition_plan: mbr for the rpi" \
  "mklabel msdos mkpart primary fat32 1MiB 256MiB mkpart primary btrfs 256MiB 100% set 1 boot on" \
  partition_plan "rpi"

# Both layouts have to leave the root partition at 256MiB, because that is what
# lib/size.sh adds in front of it.
root_starts_at() {
  partition_plan "${1}" | grep -oE "btrfs [0-9]+MiB" | head -n 1
}
expect "partition_plan: gpt puts the root partition at 256MiB" "btrfs 256MiB" \
  root_starts_at ""
expect "partition_plan: mbr puts it there too" "btrfs 256MiB" \
  root_starts_at "rpi"

export CONFIG_PATH="${OUTPUT_DIR}/${IMAGE_NAME}.json"
export OS_IMAGE="ghcr.io/cuos-dev/cuos-system:development"

echo '{}' >"${CONFIG_PATH}"
expect "image_size_mb: computed when the config says nothing" "1200" image_size_mb

echo '{"image_size_mb": 4096}' >"${CONFIG_PATH}"
expect "image_size_mb: a larger image_size_mb wins" "4096" image_size_mb

# The failure this computation exists to prevent: an image too small for the
# rootfs that is about to be written into it.
echo '{"image_size_mb": 800}' >"${CONFIG_PATH}"
expect_rc "image_size_mb: a smaller one is refused" 1 rc_of image_size_mb

pulls_of() {
  : >"${WORK_DIR}/docker.log"
  # shellcheck disable=SC2034
  ( OS_IMAGE="${1}"; OS_ARCH="x86_64"; pull_system_image >/dev/null 2>&1 )
  grep -c "^pull " "${WORK_DIR}/docker.log" || true
}
expect "pull_system_image: an image from a registry is pulled" "1" \
  pulls_of "ghcr.io/cuos-dev/cuos-system:development"
expect "pull_system_image: a locally built one is not" "0" \
  pulls_of "cuos-system:build"

echo '{}' >"${CONFIG_PATH}"
expect_rc "check_output_dir: an output dir that is there" 0 rc_of check_output_dir
rm -f "${CONFIG_PATH}"
expect_rc "check_output_dir: no config beside the image" 1 rc_of check_output_dir

summary
