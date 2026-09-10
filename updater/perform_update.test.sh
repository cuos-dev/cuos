#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

export TARGET_ROOT="${WORK_DIR}/os"
export TARGET_BOOT="${WORK_DIR}/boot"
mkdir -p "${TARGET_ROOT}" "${TARGET_BOOT}"

# mocks:
docker() {
  case "${1}" in
    version)
      echo "${MOCK_SERVER_PLATFORM-linux/amd64}"
      ;;
    buildx)
      [[ -n "${MOCK_REMOTE_DIGEST-}" ]] || return 1
      echo "${MOCK_REMOTE_DIGEST}"
      ;;
    inspect)
      case "$*" in
        *RepoDigests*)
          [[ -n "${MOCK_REPO_DIGEST-}" ]] || return 1
          echo "ghcr.io/cuos-dev/cuos-system@${MOCK_REPO_DIGEST}"
          ;;
        *.Id*)
          echo "${MOCK_IMAGE_ID-}"
          ;;
      esac
      ;;
    create)
      echo "${MOCK_CONTAINER-container123}"
      ;;
    export)
      return "${MOCK_EXPORT_RC-0}"
      ;;
    rm)
      echo "rm ${2}" >>"${WORK_DIR}/docker.log"
      ;;
    image)
      echo "${1} ${2}" >>"${WORK_DIR}/docker.log"
      ;;
  esac
  return 0
}

mountpoint() {
  # "mountpoint -q <path>", so the path is $2.
  [[ "${2}" != "${MOCK_UNMOUNTED-}" ]]
}

tar() {
  cat >/dev/null
  return "${MOCK_TAR_RC-0}"
}

btrfs() {
  case "${2}" in
    delete) rm -rf "${4}" ;;
    create) mkdir -p "${3}" ;;
  esac
}

# POSIX output (df -P): one line per filesystem, however long the device name.
# MOCK_DF_UNSUPPORTED stands for a df that does not know -P: usage to stderr,
# nothing on stdout.
df() {
  local path="${*: -1}"

  if [[ -n "${MOCK_DF_UNSUPPORTED-}" ]]; then
    echo "df: unrecognized option: P" >&2
    return 1
  fi

  case "$*" in
    *-Ph*)
      echo "Filesystem      Size  Used Avail Capacity Mounted on"
      echo "/dev/disk/by-uuid/1a2b3c4d-0000-1111-2222-334455667788 1.3G 733.8M 522.3M 58% ${path}"
      ;;
    *-Pk*)
      # The default is the boot partition of the x86_64 build of 2026-09-10:
      # 68.4 MiB of 252.7 MiB with one slot installed.
      echo "Filesystem     1024-blocks      Used Available Capacity Mounted on"
      echo "/dev/disk/by-uuid/1a2b3c4d-0000-1111-2222-334455667788 ${MOCK_SIZE_KB-258812} ${MOCK_USED_KB-70041} 188771 27% ${path}"
      ;;
    *-P*)
      echo "Filesystem     1B-blocks       Used  Available Capacity Mounted on"
      echo "/dev/disk/by-uuid/1a2b3c4d-0000-1111-2222-334455667788 1446256640 769654784 ${MOCK_AVAIL_BYTES-5368709120} 53% ${path}"
      ;;
    *)
      # Without -P the device name gets a line of its own and the columns move.
      echo "Filesystem     1B-blocks       Used  Available Use% Mounted on"
      echo "/dev/disk/by-uuid/1a2b3c4d-0000-1111-2222-334455667788"
      echo "               1446256640  769654784 ${MOCK_AVAIL_BYTES-5368709120}  53% ${path}"
      ;;
  esac
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../system/cuos/lib-test.sh"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/perform_update.sh"

# raise() exits, so anything asserted to fail runs in a subshell.
rc_of() {
  ( "$@" ) 2>/dev/null
}

expect "target_slot: A runs, B is written" "B" target_slot "A"
expect "target_slot: B runs, A is written" "A" target_slot "B"
expect "target_slot: no slot yet" "A" target_slot ""

expect "target_platform: x86_64" "linux/amd64" target_platform "x86_64"
expect "target_platform: aarch64" "linux/arm64" target_platform "aarch64"
expect "target_platform: armv7l" "linux/arm/v7" target_platform "armv7l"
expect "target_platform: armv6l" "linux/arm/v6" target_platform "armv6l"
expect "target_platform: i686" "linux/386" target_platform "i686"
expect "target_platform: rpi-arm64" "linux/arm64" target_platform "rpi-arm64"
expect "target_platform: rpi-arm32 is armv6" "linux/arm/v6" target_platform "rpi-arm32"
expect "target_platform: orangepi-zero3" "linux/arm64" target_platform "orangepi-zero3"
expect "target_platform: unset asks the daemon" "linux/amd64" target_platform ""
MOCK_SERVER_PLATFORM="linux/arm"
expect "target_platform: the daemon's linux/arm is armv7" "linux/arm/v7" target_platform ""
MOCK_SERVER_PLATFORM="linux/amd64"
expect_rc "target_platform: unknown architecture" 1 rc_of target_platform "sparc64"

export CONFIG_PATH="${SCRIPT_DIR}/perform_update.test.system.json"
expect "product_name: from the config" "My OS" product_name
export CONFIG_PATH="${SCRIPT_DIR}/perform_update.test.system-iac.json"
expect "product_name: guessed from init_image" "CuOS IaC" product_name
export CONFIG_PATH="${SCRIPT_DIR}/perform_update.test.system-plain.json"
expect "product_name: neither" "CuOS" product_name
export CONFIG_PATH="${WORK_DIR}/absent.json"
expect "product_name: no config at all" "CuOS" product_name

# The mock's device name is longer than the column, which is what -P is for.
expect_rc "check_free_space: 5 GB is enough" 0 rc_of check_free_space
MOCK_AVAIL_BYTES="1073741824"
expect_rc "check_free_space: 1 GB is not" 101 rc_of check_free_space
MOCK_AVAIL_BYTES="5368709120"
MOCK_DF_UNSUPPORTED=1
expect_rc "check_free_space: a df without -P is not guessed at" 100 \
  rc_of check_free_space
MOCK_DF_UNSUPPORTED=""

export IMAGE="ghcr.io/cuos-dev/cuos-system:development"
export T_FILE_IMAGE="${WORK_DIR}/image"
echo "${IMAGE}@sha256:aaaa" >"${T_FILE_IMAGE}"

without_image_file() {
  ( T_FILE_IMAGE="${WORK_DIR}/absent"; image_is_installed "$1" )
}

expect_rc "image_is_installed: same digest" 0 rc_of image_is_installed "sha256:aaaa"
expect_rc "image_is_installed: other digest" 1 rc_of image_is_installed "sha256:bbbb"
expect_rc "image_is_installed: no /etc/image" 1 rc_of without_image_file "sha256:aaaa"

MOCK_REMOTE_DIGEST="sha256:aaaa"
expect_rc "remote_digest_is_installed: registry agrees" 0 rc_of remote_digest_is_installed
MOCK_REMOTE_DIGEST="sha256:bbbb"
expect_rc "remote_digest_is_installed: registry has something new" 1 \
  rc_of remote_digest_is_installed
MOCK_REMOTE_DIGEST=""
expect_rc "remote_digest_is_installed: no answer falls through" 1 \
  rc_of remote_digest_is_installed

MOCK_REPO_DIGEST="sha256:cccc"
expect "repo_digest: from RepoDigests" "sha256:cccc" repo_digest
expect "image_digest: from the registry" "sha256:cccc" image_digest "sha256:cccc"
MOCK_IMAGE_ID="sha256:dddd"
expect "image_digest: a local build falls back to the id" "sha256:dddd" image_digest ""

export INSTALLIMAGE="true"
export IMAGE="cuos-system:build"
expect_rc "is_local_build: the factory's own build" 0 rc_of is_local_build
export IMAGE="ghcr.io/cuos-dev/cuos-system:development"
expect_rc "is_local_build: a pulled image" 1 rc_of is_local_build
export INSTALLIMAGE=""
export IMAGE="cuos-system:build"
expect_rc "is_local_build: not the factory, so :build is pulled too" 1 \
  rc_of is_local_build
export IMAGE="ghcr.io/cuos-dev/cuos-system:development"

pulls_of() {
  : >"${WORK_DIR}/docker.log"
  pull_image
  grep -c "^image pull$" "${WORK_DIR}/docker.log" || true
}
expect "pull_image: an image from a registry is pulled" "1" pulls_of
export INSTALLIMAGE="true"
export IMAGE="cuos-system:build"
expect "pull_image: a local build is not" "0" pulls_of
export INSTALLIMAGE=""
export IMAGE="ghcr.io/cuos-dev/cuos-system:development"

expect_rc "check_boot_reserve: one slot at 27%" 0 rc_of check_boot_reserve
MOCK_SIZE_KB=100000
MOCK_USED_KB=40000
expect_rc "check_boot_reserve: 40% is still fine" 0 rc_of check_boot_reserve
MOCK_USED_KB=41000
expect_rc "check_boot_reserve: 41% leaves the second slot too little" 115 \
  rc_of check_boot_reserve
unset MOCK_SIZE_KB MOCK_USED_KB
MOCK_DF_UNSUPPORTED=1
expect_rc "check_boot_reserve: a df without -P is not guessed at" 100 \
  rc_of check_boot_reserve
MOCK_DF_UNSUPPORTED=""

expect_rc "check_environment: everything mounted" 0 rc_of check_environment
MOCK_UNMOUNTED="${TARGET_ROOT}"
expect_rc "check_environment: no root filesystem" 100 rc_of check_environment
MOCK_UNMOUNTED="${TARGET_BOOT}"
expect_rc "check_environment: no boot partition" 100 rc_of check_environment
MOCK_UNMOUNTED=""
without_image() {
  ( IMAGE=""; check_environment )
}
expect_rc "check_environment: no image given" 100 rc_of without_image

export SLOT="B"
export CONTAINER_ROOTFS="@os/system-B"
export CONTAINER_ROOTFS_FS="${TARGET_ROOT}/system-B"
export T_FILE_FSTAB="/dev/stdout"

fstab_in_the_rootfs() {
  ( unset T_FILE_FSTAB
    mkdir -p "${CONTAINER_ROOTFS_FS}/etc"
    write_fstab
    grep -c "subvol=@os/system-B" "${CONTAINER_ROOTFS_FS}/etc/fstab" )
}
expect "write_fstab: it lands in the new rootfs, not in ours" "1" \
  fstab_in_the_rootfs

expect "write_fstab: the root entry carries the slot's subvolume" \
'# <file system> <dir> <type> <options> <dump> <pass>
# /dev/sda3
LABEL=system  /  btrfs  rw,relatime,discard=async,space_cache=v2,subvol=@os/system-B  0 0

LABEL=system  /data  btrfs  rw,relatime,discard=async,space_cache=v2,subvol=@data  0 0

# /dev/sda2
#LABEL=boot  /boot  vfat  rw,relatime,fmask=0022,dmask=0022,shortname=mixed,errors=remount-ro  0 2' \
  write_fstab

expect "report_disk_usage: both partitions, both numbers" \
"disc usage (root, before install): 733.8M of 1.3G used, 522.3M free
disc usage (boot, before install): 733.8M of 1.3G used, 522.3M free" \
  report_disk_usage "before"

mkdir -p "${CONTAINER_ROOTFS_FS}"
touch "${TARGET_BOOT}/A_vmlinuz" "${TARGET_BOOT}/A_initrd.img" \
  "${TARGET_BOOT}/B_vmlinuz" "${TARGET_BOOT}/B_initrd.img"

prepare_slot_boot_files() {
  prepare_slot >/dev/null 2>&1
  ls "${TARGET_BOOT}"
}
expect "prepare_slot: only the target slot's boot files go" \
  $'A_initrd.img\nA_vmlinuz' \
  prepare_slot_boot_files

slot_exists() {
  [[ -d "${CONTAINER_ROOTFS_FS}" ]] && echo "yes"
}
expect "prepare_slot: the slot subvolume is there afterwards" "yes" slot_exists

image_removals() {
  : >"${WORK_DIR}/docker.log"
  prepare_slot >/dev/null 2>&1
  grep -c "^image rm$" "${WORK_DIR}/docker.log" || true
}
expect "prepare_slot: a slot without /etc/image removes no image" "0" image_removals
mkdir -p "${CONTAINER_ROOTFS_FS}/etc"
echo "ghcr.io/cuos-dev/cuos-system:development@sha256:eeee" \
  >"${CONTAINER_ROOTFS_FS}/etc/image"
expect "prepare_slot: the old slot's image is removed" "1" image_removals

dockerenv_state() {
  [[ -f "${CONTAINER_ROOTFS_FS}/.dockerenv" ]] && echo "there" || echo "gone"
}

touch "${CONTAINER_ROOTFS_FS}/.dockerenv"
expect "export_rootfs: .dockerenv is written by docker" "there" dockerenv_state
expect_rc "export_rootfs: a working export" 0 rc_of export_rootfs
expect "export_rootfs: .dockerenv is removed" "gone" dockerenv_state

containers_removed() {
  : >"${WORK_DIR}/docker.log"
  rc_of export_rootfs >/dev/null
  grep -c "^rm container123$" "${WORK_DIR}/docker.log" || true
}
expect "export_rootfs: the container is removed" "1" containers_removed

# The regression test for the missing pipefail: docker export fails, tar
# succeeds, and the truncated rootfs must not be installed.
MOCK_EXPORT_RC=1
expect_rc "export_rootfs: a failing export is not masked by tar" 107 rc_of export_rootfs
expect "export_rootfs: a failed export does not leak the container" "1" \
  containers_removed
MOCK_EXPORT_RC=0

MOCK_TAR_RC=2
expect_rc "export_rootfs: a failing tar" 107 rc_of export_rootfs
MOCK_TAR_RC=0

summary
