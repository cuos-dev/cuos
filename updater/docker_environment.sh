#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/docker.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/target.sh"

export TARGET_DEVICE="${TARGET_DEVICE:-"/dev/sda"}"
TARGET_BOOT_PARTITION="${TARGET_BOOT_PARTITION:-"LABEL=boot"}"
TARGET_ROOT_PARTITION="${TARGET_ROOT_PARTITION:-"LABEL=system"}"
export TARGET_BOOT="${TARGET_BOOT:-"/mnt/boot"}"
export TARGET_ROOT="${TARGET_ROOT:-"/mnt/os"}"
# A daemon started here writes into the target: nothing else in this container
# has room for a system image.
export DOCKER_DIR="${TARGET_ROOT}/docker"

# The trap stops a daemon of ours and unmounts, and does not delete anything:
# target_mount raises between the two mounts, and a trap that removes
# ${TARGET_ROOT}/docker would do that with the target's root already mounted.
# shellcheck disable=SC2329 disable=SC2317
cleanup() {
  docker_stop
  target_umount
}

main() {
  set -x
  trap cleanup EXIT

  if [[ "${INSTALLIMAGE}" != "true" ]]; then
    update-ca-certificates
  fi

  if [[ "${INSTALLGRUB}" = "true" && ! -b "${TARGET_DEVICE}" ]]; then
    raise 90 "No target device found: ${TARGET_DEVICE}"
  fi

  target_mount

  docker_ensure "${DOCKER_DIR}" || raise 94 "Could not start dockerd"
  docker info

  local script="$1"
  shift

  "${script}" "$@"
  local exit_code="$?"

  # Whatever the task did, the data root is a copy of the system image that
  # nothing reads again. Here and not in the trap: the failures before this line
  # have not put anything there.
  docker_cleanup "${DOCKER_DIR}"

  exit "${exit_code}"
}

# Execute main only if script is run, not sourced
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
