#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# The environment an update needs: the target mounted, a docker daemon, and
# both taken down afterwards. Sourced, never run.

export TARGET_DEVICE="${TARGET_DEVICE:-"/dev/sda"}"
TARGET_BOOT_PARTITION="${TARGET_BOOT_PARTITION:-"LABEL=boot"}"
TARGET_ROOT_PARTITION="${TARGET_ROOT_PARTITION:-"LABEL=system"}"
export TARGET_BOOT="${TARGET_BOOT:-"/mnt/boot"}"
export TARGET_ROOT="${TARGET_ROOT:-"/mnt/os"}"
# A daemon started here writes into the target: nothing else in this container
# has room for a system image.
export DOCKER_DIR="${TARGET_ROOT}/docker"

# Stops a daemon of ours and takes its data root with it, and unmounts. Nothing
# else: target_mount raises between the two mounts, and a cleanup that removed
# ${TARGET_ROOT}/docker by path would do that with the target's root already
# mounted and nothing of ours in it.
# shellcheck disable=SC2329 disable=SC2317
environment_cleanup() {
  docker_cleanup
  target_umount
}

# Runs "$@" with the target mounted and a docker daemon reachable. The task is a
# function of this shell, not a process: a raise inside it ends the run, and the
# trap is what unmounts.
with_environment() {
  trap environment_cleanup EXIT

  if [[ "${INSTALLIMAGE}" != "true" ]]; then
    update-ca-certificates
  fi

  if [[ "${INSTALLGRUB}" = "true" && ! -b "${TARGET_DEVICE}" ]]; then
    raise 90 "No target device found: ${TARGET_DEVICE}"
  fi

  target_mount

  docker_ensure "${DOCKER_DIR}" || raise 94 "Could not start dockerd"
  docker info

  "$@"
  local rc="$?"

  # By path, so that what an earlier run left there goes as well. Here and not
  # in the trap: the failures before this line have put nothing there.
  docker_cleanup "${DOCKER_DIR}"

  return "${rc}"
}
