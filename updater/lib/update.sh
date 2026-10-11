#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# What an update is made of, and the two runs built from it: perform_update and
# perform_pull. The image factory installs its one slot with the same
# install_slot. Sourced, never run.

UPDATER_LIB_DIR="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"

# Named one by one, not globbed: this is the list of what an update is made of,
# and "shellcheck -x" follows it.
# shellcheck source=log.sh
source "${UPDATER_LIB_DIR}/log.sh"
# shellcheck source=config.sh
source "${UPDATER_LIB_DIR}/config.sh"
# shellcheck source=platform.sh
source "${UPDATER_LIB_DIR}/platform.sh"
# shellcheck source=disk.sh
source "${UPDATER_LIB_DIR}/disk.sh"
# shellcheck source=docker.sh
source "${UPDATER_LIB_DIR}/docker.sh"
# shellcheck source=target.sh
source "${UPDATER_LIB_DIR}/target.sh"
# shellcheck source=image.sh
source "${UPDATER_LIB_DIR}/image.sh"
# shellcheck source=slot.sh
source "${UPDATER_LIB_DIR}/slot.sh"

export CONFIG_PATH="${CONFIG_PATH:-"/system.json"}"

# $1 is the slot to write, $2 the image, $3 the digest it is pinned to, if any.
# Sets what every step below reads.
# shellcheck disable=SC2034
select_target() {
  SLOT="$1"
  IMAGE="$2"
  PINNED_DIGEST="${3:-}"

  [[ -n "${IMAGE}" ]] || raise 100 "No image to install given"

  TARGET_PLATFORM="$(target_platform "${OS_ARCH}")" || exit 1
  CONTAINER_ROOTFS_FS="${TARGET_ROOT}/system-${SLOT}"
  # Read by the install-kernel-*.sh scripts inside the new rootfs.
  export CONTAINER_ROOTFS="@os/system-${SLOT}"
}

# Sets PULLED_DIGEST, the registry's digest of IMAGE - empty for an image built
# locally, which has none - and holds it against the pin.
check_pinned_digest() {
  PULLED_DIGEST="$(repo_digest)"
  if [[ -n "${PINNED_DIGEST}" && "${PINNED_DIGEST}" != "${PULLED_DIGEST}" ]]; then
    raise 104 "Image digest mismatch: ${PINNED_DIGEST} != ${PULLED_DIGEST}"
  fi
}

# Up to here nothing is deleted on a device, and nothing needs to be: the image
# is new only if it is not the one running.
fetch_image() {
  step "Fetching ${IMAGE}"
  pull_image
  check_pinned_digest

  if image_is_installed "${PULLED_DIGEST}"; then
    raise_info 102 "No OS update available"
  fi
}

# The image is pulled, the slot is an empty directory: what is left is the
# system in it, and its kernel on the boot side.
install_slot() {
  export PRODUCT_NAME
  PRODUCT_NAME="$(product_name)"

  # What /etc/image of the new slot records, and what the next update compares.
  RECORDED_DIGEST="$(recorded_digest "${PULLED_DIGEST}")"
  [[ -n "${RECORDED_DIGEST}" ]] || raise 105 "Failed to get image digest"

  step "Unpacking the system into slot ${SLOT}"
  export_rootfs
  write_fstab

  step "Preparing the first boot"
  run_first_run

  step "Installing the kernel and the boot chain"
  install_kernel
}

# $1 is the slot in use - the update goes to the other one -, $2 the image and
# $3 the digest it is pinned to.
perform_update() {
  select_target "$(other_slot "${1:-}")" "${2:-}" "${3:-}"
  check_mounted_target

  if remote_digest_is_installed; then
    raise_info 102 "No OS update available"
  fi

  step "Removing the image slot ${SLOT} was installed from"
  remove_standby_image
  check_space_before_pull

  fetch_image
  check_space_after_pull

  step "Clearing slot ${SLOT}"
  clear_slot

  report_disk_usage "before"
  install_slot
  report_disk_usage "after"

  step "Slot ${SLOT} installed: ${IMAGE}"
}

# "cuos pull": perform_update up to the point where the standby slot would be
# cleared, without removing anything - the image is fetched into the host's
# daemon, checked, and left there, so that a later update only installs it.
#
# Exit codes are perform_update's. 127 is never one of them: it is what docker
# reports for an updater that has no /api/pull, and do-update.sh reads it that
# way.
perform_pull() {
  select_target "$(other_slot "${1:-}")" "${2:-}" "${3:-}"
  check_mounted_target

  # Into a daemon of the updater's own the image would be fetched for nothing:
  # it goes when the updater ends.
  [[ -z "${_CUOS_DOCKERD_PID}" ]] \
    || raise 100 "The host's docker daemon is not reachable, so there is nowhere to keep the image"

  if remote_digest_is_installed; then
    raise_info 102 "No OS update available"
  fi

  check_space_before_pull

  fetch_image
  check_space_after_pull

  step "Fetched ${IMAGE}: an update installs it without downloading it again"
}
