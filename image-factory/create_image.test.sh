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
    *"image inspect"*"dev.cuos.boot"*)
      [[ -n "${MOCK_BOOT_LABEL-}" ]] || return 1
      echo "${MOCK_BOOT_LABEL}"
      ;;
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
  partition_plan "gpt"

expect "partition_plan: mbr" \
  "mklabel msdos mkpart primary fat32 1MiB 256MiB mkpart primary btrfs 256MiB 100% set 1 boot on" \
  partition_plan "mbr"

# Both layouts have to leave the root partition at 256MiB, because that is what
# lib/size.sh adds in front of it.
root_starts_at() {
  partition_plan "${1}" | grep -oE "btrfs [0-9]+MiB" | head -n 1
}
expect "partition_plan: gpt puts the root partition at 256MiB" "btrfs 256MiB" \
  root_starts_at "gpt"
expect "partition_plan: mbr puts it there too" "btrfs 256MiB" \
  root_starts_at "mbr"

export CONFIG_PATH="${OUTPUT_DIR}/${IMAGE_NAME}.json"
export IMAGE="ghcr.io/cuos-dev/cuos-system:development"

# The tree of the v0.6.2 x86_64 system, as du counted it on 2026-10-10.
TREE_KB=722000

echo '{}' >"${CONFIG_PATH}"
expect "image_size_mb: computed when the config says nothing" "1680" \
  image_size_mb "${TREE_KB}"

echo '{"image_size_mb": 4096}' >"${CONFIG_PATH}"
expect "image_size_mb: a larger image_size_mb wins" "4096" \
  image_size_mb "${TREE_KB}"

# The failure this computation exists to prevent: an image too small for the
# system that is about to be written into it.
echo '{"image_size_mb": 800}' >"${CONFIG_PATH}"
expect_rc "image_size_mb: a smaller one is refused" 1 \
  rc_of image_size_mb "${TREE_KB}"

boot_type() {
  # shellcheck disable=SC2034
  ( TARGET_PLATFORM="$(target_platform "${1}")"; MOCK_BOOT_LABEL="${2}"
    if [[ "${3-unset}" != "unset" ]]; then export TARGET="${3}"; else unset TARGET; fi
    resolve_boot_type >/dev/null 2>&1 && echo "${BOOT_TYPE} ${LAYOUT}" )
}
expect "resolve_boot_type: grub boots from gpt" "grub gpt" \
  boot_type x86_64 grub
expect "resolve_boot_type: rpi from mbr" "rpi mbr" boot_type rpi-arm64 rpi
expect "resolve_boot_type: uboot from mbr" "uboot mbr" \
  boot_type orangepi-zero3 uboot
expect "resolve_boot_type: tool.sh's layout agrees" "rpi mbr" \
  boot_type rpi-arm64 rpi rpi
expect "resolve_boot_type: tool.sh's gpt is TARGET=\"\"" "grub gpt" \
  boot_type x86_64 grub ""
expect_rc "resolve_boot_type: an image without the label is refused" 1 \
  rc_of boot_type x86_64 ""
expect_rc "resolve_boot_type: a label nobody knows is refused" 1 \
  rc_of boot_type x86_64 lilo
expect_rc "resolve_boot_type: an LXC image is not written to a disk" 1 \
  rc_of boot_type x86_64 lxc
expect_rc "resolve_boot_type: an mbr layout for a grub image" 1 \
  rc_of boot_type x86_64 grub rpi
expect_rc "resolve_boot_type: a gpt layout for an rpi image" 1 \
  rc_of boot_type rpi-arm64 rpi ""

pulls_of() {
  : >"${WORK_DIR}/docker.log"
  # shellcheck disable=SC2034
  ( IMAGE="${1}"; TARGET_PLATFORM="linux/amd64"; fetch_system_image >/dev/null 2>&1 )
  grep -c "^pull " "${WORK_DIR}/docker.log" || true
}
expect "fetch_system_image: an image from a registry is pulled" "1" \
  pulls_of "ghcr.io/cuos-dev/cuos-system:development"
expect "fetch_system_image: a locally built one is not" "0" \
  pulls_of "cuos-system:build"

selected() {
  # shellcheck disable=SC2034
  ( OS_ARCH="${1}"; TARGET_ROOT="/build/root/@os"
    select_system_image >/dev/null 2>&1 \
      && echo "${SLOT} ${IMAGE} ${PINNED_DIGEST:-unpinned} ${CONTAINER_ROOTFS_FS}" )
}
echo '{"update_registry": "ghcr.io/cuos-dev", "os_image": "cuos-system",
  "os_image_version": "v1", "os_image_digest": "sha256:abc"}' >"${CONFIG_PATH}"
expect "select_system_image: slot A, the image and its pin" \
  "A ghcr.io/cuos-dev/cuos-system:v1 sha256:abc /build/root/@os/system-A" \
  selected x86_64
expect_rc "select_system_image: a board without an image of its own is refused" 1 \
  rc_of selected orangepi-zero3

echo '{}' >"${CONFIG_PATH}"
expect_rc "check_output_dir: an output dir that is there" 0 rc_of check_output_dir
rm -f "${CONFIG_PATH}"
expect_rc "check_output_dir: no config beside the image" 1 rc_of check_output_dir

summary
