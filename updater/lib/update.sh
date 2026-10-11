#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# The steps of an update, in the order perform_update runs them. Sourced, never
# run.
#
# pipefail: a failing "docker export" must not be masked by a succeeding tar,
# which would install a truncated rootfs into the target slot.
set -o pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Named one by one, not globbed: this is the list of what an update is made of,
# and "shellcheck -x" follows it.
# shellcheck source=log.sh
source "${SCRIPT_DIR}/log.sh"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=platform.sh
source "${SCRIPT_DIR}/platform.sh"
# shellcheck source=disk.sh
source "${SCRIPT_DIR}/disk.sh"
# shellcheck source=docker.sh
source "${SCRIPT_DIR}/docker.sh"
# shellcheck source=target.sh
source "${SCRIPT_DIR}/target.sh"
# shellcheck source=image.sh
source "${SCRIPT_DIR}/image.sh"
# shellcheck source=slot.sh
source "${SCRIPT_DIR}/slot.sh"

export CONFIG_PATH="${CONFIG_PATH:-"/system.json"}"

perform_update() {
  SLOT="$(target_slot "${1:-}")"
  IMAGE="${2:-}"
  IMAGE_DIGEST="${3:-""}"

  check_environment

  export PRODUCT_NAME
  PRODUCT_NAME="$(product_name)"

  # Read by the libraries above, which shellcheck has already inlined.
  # shellcheck disable=SC2034
  TARGET_PLATFORM="$(target_platform "${OS_ARCH}")" || exit 1

  # shellcheck disable=SC2034
  CONTAINER_ROOTFS_FS="${TARGET_ROOT}/system-${SLOT}"
  # Consumed by the install-kernel-*.sh scripts inside the new rootfs:
  export CONTAINER_ROOTFS="@os/system-${SLOT}"

  if [[ "${INSTALLIMAGE}" != "true" ]] && remote_digest_is_installed; then
    raise_info 102 "No OS update available"
  fi

  if [[ "${INSTALLIMAGE}" != "true" ]]; then
    step "Removing the image slot ${SLOT} was installed from"
    remove_standby_image

    check_space_before_pull
  fi

  if ! is_local_build; then
    step "Fetching ${IMAGE}"
  fi
  pull_image

  NEW_DIGEST="$(repo_digest)"
  if [[ -n "${IMAGE_DIGEST}" && "${IMAGE_DIGEST}" != "${NEW_DIGEST}" ]]; then
    raise 104 "Image digest mismatch: ${IMAGE_DIGEST} != ${NEW_DIGEST}"
  fi

  if image_is_installed "${NEW_DIGEST}"; then
    raise_info 102 "No OS update available"
  fi

  if [[ "${INSTALLIMAGE}" != "true" ]]; then
    check_space_after_pull
  fi

  step "Clearing slot ${SLOT}"
  prepare_slot

  echo "INFO: Updating OS slot ${SLOT} to ${IMAGE}"

  report_disk_usage "before"

  DIGEST="$(image_digest "${NEW_DIGEST}")"
  if [[ -z "${DIGEST}" ]]; then
    raise 105 "Failed to get image digest"
  fi

  step "Unpacking the system into slot ${SLOT}"
  export_rootfs

  write_fstab

  step "Preparing the first boot"
  run_first_run

  step "Installing the kernel and the boot chain"
  install_kernel

  report_disk_usage "after"

  if [[ "${INSTALLIMAGE}" = "true" ]]; then
    copy_system_json

    check_boot_reserve
  fi

  step "Slot ${SLOT} installed: ${IMAGE}"
}

# "cuos pull": what perform_update does up to the point where the standby slot
# would be cleared, without removing anything - the image is fetched into the
# host's daemon, checked, and left there, so that a later update only installs.
#
# Exit codes are perform_update's. 127 is never one of them: it is what docker
# reports for an updater that has no /api/pull, and do-update.sh reads it that
# way.
perform_pull() {
  SLOT="$(target_slot "${1:-}")"
  IMAGE="${2:-}"
  IMAGE_DIGEST="${3:-""}"

  check_environment

  # Into a daemon of the updater's own the image would be fetched for nothing:
  # it goes when the updater ends.
  [[ -z "${_CUOS_DOCKERD_PID}" ]] \
    || raise 100 "The host's docker daemon is not reachable, so there is nowhere to keep the image"

  # shellcheck disable=SC2034
  TARGET_PLATFORM="$(target_platform "${OS_ARCH}")" || exit 1
  # shellcheck disable=SC2034
  CONTAINER_ROOTFS_FS="${TARGET_ROOT}/system-${SLOT}"

  if remote_digest_is_installed; then
    raise_info 102 "No OS update available"
  fi

  check_space_before_pull pull

  step "Fetching ${IMAGE}"
  pull_image

  NEW_DIGEST="$(repo_digest)"
  if [[ -n "${IMAGE_DIGEST}" && "${IMAGE_DIGEST}" != "${NEW_DIGEST}" ]]; then
    raise 104 "Image digest mismatch: ${IMAGE_DIGEST} != ${NEW_DIGEST}"
  fi

  if image_is_installed "${NEW_DIGEST}"; then
    raise_info 102 "No OS update available"
  fi

  check_space_after_pull pull

  step "Fetched ${IMAGE}: an update installs it without downloading it again"
}
