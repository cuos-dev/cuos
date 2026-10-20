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
      case "${2}" in
        inspect)
          mock_image_inspect "$@"
          return
          ;;
        rm)
          mock_image_rm "${*: -1}"
          ;;
        pull)
          echo "${1} ${2}" >>"${WORK_DIR}/docker.log"
          return "${MOCK_PULL_RC-0}"
          ;;
        *)
          echo "${1} ${2}" >>"${WORK_DIR}/docker.log"
          ;;
      esac
      ;;
  esac
  return 0
}

# The daemon's images: reference -> id, and id -> size in bytes.
declare -A MOCK_REF=()
declare -A MOCK_BYTES=()

mock_image_inspect() {
  local ref="${*: -1}"
  local id="${MOCK_REF[${ref}]-}"

  [[ -n "${id}" ]] || return 1
  case "$*" in
    *.Size*) echo "${MOCK_BYTES[${id}]-0}" ;;
    *) echo "${id}" ;;
  esac
}

# Only removal by id is modelled: every reference to the image goes, and the
# image with them.
mock_image_rm() {
  local id="$1"
  local ref

  echo "image rm ${id}" >>"${WORK_DIR}/docker.log"
  for ref in "${!MOCK_REF[@]}"; do
    if [[ "${MOCK_REF[${ref}]}" == "${id}" ]]; then
      unset "MOCK_REF[${ref}]"
    fi
  done
}

mock_refs() {
  local ref

  for ref in "${!MOCK_REF[@]}"; do
    echo "${ref} ${MOCK_REF[${ref}]}"
  done | sort
}

du() {
  printf '%s\t%s\n' "${MOCK_SLOT_KB-0}" "${*: -1}"
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
    delete) echo "btrfs delete ${4}" >>"${WORK_DIR}/docker.log"; rm -rf "${4}" ;;
    create) echo "btrfs create ${3}" >>"${WORK_DIR}/docker.log"; mkdir -p "${3}" ;;
    sync) echo "btrfs sync ${3}" >>"${WORK_DIR}/docker.log" ;;
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
      echo "Filesystem     1024-blocks      Used Available Capacity Mounted on"
      echo "/dev/disk/by-uuid/1a2b3c4d-0000-1111-2222-334455667788 1412360 751616 ${MOCK_AVAIL_KB-5242880} 53% ${path}"
      ;;
    *)
      # Without -P the device name gets a line of its own and the columns move.
      echo "Filesystem     1024-blocks      Used Available Use% Mounted on"
      echo "/dev/disk/by-uuid/1a2b3c4d-0000-1111-2222-334455667788"
      echo "               1412360  751616 ${MOCK_AVAIL_KB-5242880}  53% ${path}"
      ;;
  esac
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../system/cuos/lib-test.sh"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/update.sh"

# raise() exits, so anything asserted to fail runs in a subshell.
rc_of() {
  ( "$@" ) 2>/dev/null
}

expect "other_slot: A runs, B is written" "B" other_slot "A"
expect "other_slot: B runs, A is written" "A" other_slot "B"
expect "other_slot: no slot yet" "A" other_slot ""

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
expect "target_platform: lxc is amd64 whatever the daemon runs" "linux/amd64" target_platform "lxc"
MOCK_SERVER_PLATFORM="linux/amd64"
expect_rc "target_platform: unknown architecture" 1 rc_of target_platform "sparc64"

export CONFIG_PATH="${SCRIPT_DIR}/update.test.system.json"
expect "product_name: from the config" "My OS" product_name
export CONFIG_PATH="${SCRIPT_DIR}/update.test.system-iac.json"
expect "product_name: guessed from init_image" "CuOS IaC" product_name
export CONFIG_PATH="${SCRIPT_DIR}/update.test.system-plain.json"
expect "product_name: neither" "CuOS" product_name
export CONFIG_PATH="${WORK_DIR}/absent.json"
expect "product_name: no config at all" "CuOS" product_name


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
expect "recorded_digest: from the registry" "sha256:cccc" recorded_digest "sha256:cccc"
MOCK_IMAGE_ID="sha256:dddd"
expect "recorded_digest: a local build falls back to the id" "sha256:dddd" recorded_digest ""

pulls_of() {
  : >"${WORK_DIR}/docker.log"
  pull_image
  grep -c "^image pull$" "${WORK_DIR}/docker.log" || true
}
expect "pull_image: an image from a registry is pulled" "1" pulls_of
pulls_of_build() {
  ( IMAGE="cuos-system:build"; pulls_of )
}
expect "pull_image: so is a :build, which only the factory has locally" "1" \
  pulls_of_build

expect_rc "check_mounted_target: everything mounted" 0 rc_of check_mounted_target
MOCK_UNMOUNTED="${TARGET_ROOT}"
expect_rc "check_mounted_target: no root filesystem" 100 rc_of check_mounted_target
MOCK_UNMOUNTED="${TARGET_BOOT}"
expect_rc "check_mounted_target: no boot partition" 100 rc_of check_mounted_target
MOCK_UNMOUNTED=""

selected() {
  ( export OS_ARCH="x86_64"
    select_target "$@" >/dev/null 2>&1 \
      && echo "${SLOT} ${IMAGE} ${PINNED_DIGEST:-unpinned} ${TARGET_PLATFORM} ${CONTAINER_ROOTFS}" )
}
expect "select_target: the slot it is given, not the other one" \
  "B ${IMAGE} sha256:ffff linux/amd64 @os/system-B" \
  selected "B" "${IMAGE}" "sha256:ffff"
expect_rc "select_target: no image given" 100 rc_of selected "B" ""

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

expect "digest_ref: the tag goes" "ghcr.io/cuos-dev/cuos-system@sha256:aaaa" \
  digest_ref "ghcr.io/cuos-dev/cuos-system:v1@sha256:aaaa"
expect "digest_ref: a registry port stays" "reg.local:5000/cuos-system@sha256:aaaa" \
  digest_ref "reg.local:5000/cuos-system:v1@sha256:aaaa"
expect "digest_ref: a port and no tag" "reg.local:5000/cuos-system@sha256:aaaa" \
  digest_ref "reg.local:5000/cuos-system@sha256:aaaa"
expect_rc "digest_ref: no digest" 1 digest_ref "ghcr.io/cuos-dev/cuos-system:v1"

REPO="ghcr.io/cuos-dev/cuos-system"
MiB=1048576

# The running image, "id-active", 1000 MiB, installed from :development.
reset_images() {
  MOCK_REF=()
  MOCK_BYTES=()
  MOCK_REF["${REPO}@sha256:aaaa"]="id-active"
  MOCK_BYTES["id-active"]="$(( 1000 * MiB ))"
  echo "${REPO}:development@sha256:aaaa" >"${T_FILE_IMAGE}"
  rm -rf "${CONTAINER_ROOTFS_FS}"
  : >"${WORK_DIR}/docker.log"
}

standby_installed_from() {
  mkdir -p "${CONTAINER_ROOTFS_FS}/etc"
  echo "$1" >"${CONTAINER_ROOTFS_FS}/etc/image"
}

removals() {
  grep -c "^image rm" "${WORK_DIR}/docker.log" || true
}

export PINNED_DIGEST=""
export REMOTE_DIGEST=""

# Same tag: the tag has moved on to the running image, the standby's image is
# left with its digest reference alone.
reset_images
MOCK_REF["${REPO}:development"]="id-active"
MOCK_REF["${REPO}@sha256:eeee"]="id-standby"
standby_installed_from "${REPO}:development@sha256:eeee"
remove_standby_image >/dev/null 2>&1
expect "remove_standby_image: same tag - the standby's image goes, the running one stays" \
  "${REPO}:development id-active
${REPO}@sha256:aaaa id-active" mock_refs

# New tag: the standby's tag still points at its image, and has to go with it.
reset_images
MOCK_REF["${REPO}:v1"]="id-standby"
MOCK_REF["${REPO}@sha256:eeee"]="id-standby"
standby_installed_from "${REPO}:v1@sha256:eeee"
remove_standby_image >/dev/null 2>&1
expect "remove_standby_image: new tag - the image goes with its tag" \
  "${REPO}@sha256:aaaa id-active" mock_refs

reset_images
standby_installed_from "${REPO}:development@sha256:aaaa"
remove_standby_image >/dev/null 2>&1
expect "remove_standby_image: never the running image" "0" removals

reset_images
MOCK_REF["${REPO}@sha256:ffff"]="id-target"
standby_installed_from "${REPO}:v3@sha256:ffff"
PINNED_DIGEST="sha256:ffff"
remove_standby_image >/dev/null 2>&1
PINNED_DIGEST=""
expect "remove_standby_image: never the image about to be installed" "0" removals

# After a rollback the standby slot holds the newer system, and an unpinned
# update to it finds its digest at the registry.
reset_images
MOCK_REF["${REPO}@sha256:ffff"]="id-target"
standby_installed_from "${REPO}:development@sha256:ffff"
REMOTE_DIGEST="sha256:ffff"
remove_standby_image >/dev/null 2>&1
REMOTE_DIGEST=""
expect "remove_standby_image: never what the registry has for the tag" "0" removals

reset_images
MOCK_REF["${REPO}@sha256:eeee"]="id-active"
standby_installed_from "${REPO}:mirror@sha256:eeee"
remove_standby_image >/dev/null 2>&1
expect "remove_standby_image: never the running image under another digest" "0" removals

reset_images
mkdir -p "${CONTAINER_ROOTFS_FS}"
remove_standby_image >/dev/null 2>&1
expect "remove_standby_image: a slot without /etc/image removes no image" "0" removals

reset_images
standby_installed_from "${REPO}:v1@sha256:eeee"
remove_standby_image >/dev/null 2>&1
expect "remove_standby_image: an image the daemon does not have" "0" removals

# Space. 300 MiB have to be left: free + standby slot - what the update needs.
# The standby slot counts only once it is gone, after the pull: the download
# itself has to fit beside it.
reset_images
MOCK_AVAIL_KB="$(( 2300 * 1024 ))"
expect_rc "check_space_before_pull: 2300 MiB free, no standby, 2 x 1000 needed" 0 \
  rc_of check_space_before_pull
MOCK_AVAIL_KB="$(( 2299 * 1024 ))"
expect_rc "check_space_before_pull: one MiB short of the reserve" 101 \
  rc_of check_space_before_pull
mkdir -p "${CONTAINER_ROOTFS_FS}"
MOCK_SLOT_KB="$(( 900 * 1024 ))"
MOCK_AVAIL_KB="$(( 1400 * 1024 ))"
expect_rc "check_space_before_pull: the standby slot it frees counts" 0 \
  rc_of check_space_before_pull
# The reviewer's case: the end state leaves 400 MiB, but the download fills the
# disk to nothing while the slot is still there.
MOCK_SLOT_KB="$(( 1200 * 1024 ))"
MOCK_AVAIL_KB="$(( 800 * 1024 ))"
MOCK_BYTES["id-active"]="$(( 800 * MiB ))"
expect_rc "check_space_before_pull: not before the slot is gone - the download has to fit beside it" 101 \
  rc_of check_space_before_pull
MOCK_AVAIL_KB="$(( 1100 * 1024 ))"
expect_rc "check_space_before_pull: 1100 MiB free, 800 to download beside the slot" 0 \
  rc_of check_space_before_pull
MOCK_BYTES["id-active"]="$(( 1000 * MiB ))"
MOCK_AVAIL_KB="$(( 1299 * 1024 ))"
expect_rc "check_space_before_pull: a pull never counts the slot" 101 \
  rc_of check_space_before_pull pull
MOCK_AVAIL_KB="$(( 1300 * 1024 ))"
expect_rc "check_space_before_pull: a pull needs room for the download only" 0 \
  rc_of check_space_before_pull pull
MOCK_SLOT_KB=0
MOCK_DF_UNSUPPORTED=1
expect_rc "check_space_before_pull: a df without -P is not guessed at" 100 \
  rc_of check_space_before_pull
MOCK_DF_UNSUPPORTED=""

MOCK_REF=()
MOCK_AVAIL_KB="$(( 2049 * 1024 ))"
expect_rc "check_space_before_pull: running image unknown, more than 2 GB" 0 \
  rc_of check_space_before_pull
MOCK_AVAIL_KB="$(( 2048 * 1024 ))"
expect_rc "check_space_before_pull: running image unknown, 2 GB" 101 \
  rc_of check_space_before_pull

reset_images
MOCK_AVAIL_KB="$(( 500 * 1024 ))"
MOCK_REF["${REPO}@sha256:ffff"]="id-target"
PINNED_DIGEST="sha256:ffff"
expect_rc "check_space_before_pull: a pinned image fetched before is not counted twice" 0 \
  rc_of check_space_before_pull
PINNED_DIGEST=""
MOCK_REF["${IMAGE}"]="id-target"
REMOTE_DIGEST="sha256:ffff"
expect_rc "check_space_before_pull: nor is a tag fetched before, if the registry still has it" 0 \
  rc_of check_space_before_pull
REMOTE_DIGEST="sha256:9999"
expect_rc "check_space_before_pull: a tag fetched before, the registry has moved on" 101 \
  rc_of check_space_before_pull
REMOTE_DIGEST=""
expect_rc "check_space_before_pull: no answer from the registry, nothing taken as here" 101 \
  rc_of check_space_before_pull

# After the pull: the image is in docker's storage, the slot is what is left.
reset_images
MOCK_REF["${IMAGE}"]="id-new"
MOCK_REF["${REPO}@sha256:ffff"]="id-new"
MOCK_BYTES["id-new"]="$(( 1000 * MiB ))"
MOCK_AVAIL_KB="$(( 1300 * 1024 ))"
expect_rc "check_space_after_pull: 1300 MiB free, 1000 to unpack" 0 \
  rc_of check_space_after_pull
expect "check_space_after_pull: the image stays" "0" removals
MOCK_AVAIL_KB="$(( 1299 * 1024 ))"
expect_rc "check_space_after_pull: one MiB short" 101 rc_of check_space_after_pull
expect "check_space_after_pull: the pulled image goes again" "1" removals
refs_after_failed_check() {
  # check_space_after_pull exits, so the refs are read on the way out.
  ( exec 3>&1; trap "mock_refs >&3" EXIT; check_space_after_pull >/dev/null 2>&1 )
}
expect "check_space_after_pull: and only that one" \
  "${REPO}@sha256:aaaa id-active" refs_after_failed_check
MOCK_AVAIL_KB="$(( 1300 * 1024 ))"
expect_rc "check_space_after_pull: a pull leaves the reserve and can be installed" 0 \
  rc_of check_space_after_pull pull
MOCK_AVAIL_KB="$(( 299 * 1024 ))"
mkdir -p "${CONTAINER_ROOTFS_FS}"
MOCK_SLOT_KB="$(( 2000 * 1024 ))"
expect_rc "check_space_after_pull: a pull that ate into the reserve, the slot not counted" 101 \
  rc_of check_space_after_pull pull
expect_rc "check_space_after_pull: an update deletes the slot before it unpacks" 0 \
  rc_of check_space_after_pull
MOCK_SLOT_KB=0
rm -rf "${CONTAINER_ROOTFS_FS}"

# The running image under another registry name - update_registry_proxy
# changed. Its digest is new to /etc/image, its id is not.
reset_images
MOCK_REF["${IMAGE}"]="id-active"
MOCK_AVAIL_KB="$(( 1000 * 1024 ))"
rc_of check_space_after_pull >/dev/null
expect "check_space_after_pull: never removes the running image under another name" "0" removals

reset_images
unset "MOCK_REF[${IMAGE}]"
expect_rc "check_space_after_pull: no size to read" 100 rc_of check_space_after_pull
unset MOCK_AVAIL_KB

mkdir -p "${CONTAINER_ROOTFS_FS}"
touch "${TARGET_BOOT}/A_vmlinuz" "${TARGET_BOOT}/A_initrd.img" \
  "${TARGET_BOOT}/B_vmlinuz" "${TARGET_BOOT}/B_initrd.img"

clear_slot_boot_files() {
  clear_slot >/dev/null 2>&1
  ls "${TARGET_BOOT}"
}
expect "clear_slot: only the target slot's boot files go" \
  $'A_initrd.img\nA_vmlinuz' \
  clear_slot_boot_files

slot_exists() {
  [[ -d "${CONTAINER_ROOTFS_FS}" ]] && echo "yes"
}
expect "clear_slot: the slot subvolume is there afterwards" "yes" slot_exists

syncs_of_clear_slot() {
  : >"${WORK_DIR}/docker.log"
  clear_slot >/dev/null 2>&1
  grep -c "^btrfs sync ${TARGET_ROOT}$" "${WORK_DIR}/docker.log" || true
}
expect "clear_slot: waits for btrfs to give the space back" "1" \
  syncs_of_clear_slot

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

# The whole run, up to the point where the standby slot would go. Each case
# starts from a standby slot installed from :v1, whose image is still there.
export OS_ARCH="x86_64"
MOCK_REMOTE_DIGEST=""
MOCK_REPO_DIGEST="sha256:ffff"

with_standby() {
  reset_images
  MOCK_REF["${REPO}:v1"]="id-standby"
  MOCK_REF["${REPO}@sha256:eeee"]="id-standby"
  standby_installed_from "${REPO}:v1@sha256:eeee"
  MOCK_REF["${IMAGE}"]="id-new"
  MOCK_BYTES["id-new"]="$(( 1000 * MiB ))"
  MOCK_AVAIL_KB="$(( 5000 * 1024 ))"
}

# $1 is perform_update or perform_pull. Prints the exit code and what is left of the slot.
run_and_look() {
  local rc

  ( "$1" "A" "${IMAGE}" "" ) >/dev/null 2>&1
  rc="$?"
  echo "rc=${rc} slot=$(cat "${CONTAINER_ROOTFS_FS}/etc/image" 2>/dev/null || echo gone)"
}

with_standby
MOCK_PULL_RC=1
expect "perform_update: a failed pull leaves the standby slot alone" \
  "rc=103 slot=${REPO}:v1@sha256:eeee" run_and_look perform_update
MOCK_PULL_RC=0

run_pinned() {
  ( "$1" "A" "${IMAGE}" "sha256:ffff" ) >/dev/null 2>&1
  echo "rc=$? slot=$(cat "${CONTAINER_ROOTFS_FS}/etc/image" 2>/dev/null || echo gone)"
}

with_standby
MOCK_REPO_DIGEST="sha256:9999"
expect "perform_update: a digest mismatch leaves the standby slot alone" \
  "rc=104 slot=${REPO}:v1@sha256:eeee" run_pinned perform_update
MOCK_REPO_DIGEST="sha256:ffff"

pulls() {
  grep -c "^image pull$" "${WORK_DIR}/docker.log" || true
}

# The runs are subshells, so what they removed is read from the log.
new_image_removed() {
  grep -c "^image rm id-new$" "${WORK_DIR}/docker.log" || true
}

# The new image turns out larger than the estimate: the check after the pull
# catches it.
with_standby
MOCK_REMOTE_DIGEST="sha256:aaaa"
expect "perform_update: nothing new, and nothing is removed" \
  "rc=102 slot=${REPO}:v1@sha256:eeee" run_and_look perform_update
expect "perform_update: not even the standby's image" "0" removals
MOCK_REMOTE_DIGEST=""

with_standby
MOCK_AVAIL_KB="$(( 1200 * 1024 ))"
MOCK_BYTES["id-active"]="$(( 400 * MiB ))"
expect "perform_update: too little room for the new image aborts before the slot goes" \
  "rc=101 slot=${REPO}:v1@sha256:eeee" run_and_look perform_update
expect "perform_update: after the pull" "1" pulls
expect "perform_update: and the slot was never synced away" "0" \
  grep -c "^btrfs sync" "${WORK_DIR}/docker.log"

# The estimate says no: nothing is downloaded.
with_standby
MOCK_AVAIL_KB="$(( 800 * 1024 ))"
MOCK_SLOT_KB="$(( 1200 * 1024 ))"
MOCK_BYTES["id-active"]="$(( 800 * MiB ))"
expect "perform_update: a download that would fill the disk is not started" \
  "rc=101 slot=${REPO}:v1@sha256:eeee" run_and_look perform_update
expect "perform_update: nothing pulled" "0" pulls
MOCK_SLOT_KB=0

with_standby
expect "perform_pull: fetches, and the standby slot stays" \
  "rc=0 slot=${REPO}:v1@sha256:eeee" run_and_look perform_pull
expect "perform_pull: and so does the standby's image" "0" removals

with_standby
MOCK_AVAIL_KB="$(( 1200 * 1024 ))"
expect "perform_pull: no room for the download, nothing fetched" \
  "rc=101 slot=${REPO}:v1@sha256:eeee" run_and_look perform_pull
expect "perform_pull: nothing pulled" "0" pulls

with_standby
MOCK_AVAIL_KB="$(( 1200 * 1024 ))"
MOCK_BYTES["id-active"]="$(( 400 * MiB ))"
expect "perform_pull: no room for a later update, nothing kept" \
  "rc=101 slot=${REPO}:v1@sha256:eeee" run_and_look perform_pull
expect "perform_pull: pulled" "1" pulls
expect "perform_pull: and removed again" "1" new_image_removed

with_standby
MOCK_REMOTE_DIGEST="sha256:aaaa"
expect "perform_pull: nothing new is not an error" \
  "rc=102 slot=${REPO}:v1@sha256:eeee" run_and_look perform_pull
MOCK_REMOTE_DIGEST=""

without_docker_host() {
  ( _CUOS_DOCKERD_PID="123"; run_and_look perform_pull )
}

with_standby
expect "perform_pull: not into a daemon of the updater's own" \
  "rc=100 slot=${REPO}:v1@sha256:eeee" without_docker_host

# A whole run that succeeds, in the order the steps have to come: nothing goes
# before the new image is there and checked, and the slot is cleared only then.
# The steps are replaced, in a subshell, by ones that say that they ran.
steps_of_update() {
  local log="${WORK_DIR}/steps.log"
  : >"${log}"
  (
    remove_standby_image() { echo "remove_standby_image" >>"${log}"; }
    pull_image() { echo "pull_image" >>"${log}"; }
    check_space_after_pull() { echo "check_space_after_pull" >>"${log}"; }
    clear_slot() { echo "clear_slot" >>"${log}"; mkdir -p "${CONTAINER_ROOTFS_FS}"; }
    export_rootfs() { echo "export_rootfs" >>"${log}"; }
    run_first_run() { echo "first-run ${SLOT} ${IMAGE} ${RECORDED_DIGEST}" >>"${log}"; }
    install_kernel() { echo "install-kernel ${SLOT} ${CONTAINER_ROOTFS} ${PRODUCT_NAME}" >>"${log}"; }
    perform_update "A" "${IMAGE}" "sha256:ffff"
  ) >/dev/null 2>&1
  echo "rc=$?"
  cat "${log}"
}
with_standby
export CONFIG_PATH="${SCRIPT_DIR}/update.test.system.json"
expect "perform_update: the steps of a whole run, in order" \
"rc=0
remove_standby_image
pull_image
check_space_after_pull
clear_slot
export_rootfs
first-run B ${IMAGE} sha256:ffff
install-kernel B @os/system-B My OS" steps_of_update

summary
