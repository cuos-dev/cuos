#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# The environment an update needs: the target mounted, a docker daemon, and
# both taken down afterwards. Sourced, never run.

TARGET_BOOT_PARTITION="${TARGET_BOOT_PARTITION:-"LABEL=boot"}"
TARGET_ROOT_PARTITION="${TARGET_ROOT_PARTITION:-"LABEL=system"}"
export TARGET_BOOT="${TARGET_BOOT:-"/mnt/boot"}"
export TARGET_ROOT="${TARGET_ROOT:-"/mnt/os"}"
# A daemon started here writes into the target: nothing else in this container
# has room for a system image.
export DOCKER_DIR="${TARGET_ROOT}/docker"

# ${TARGET_ROOT}/docker is also where earlier versions kept the system itself:
# docker's btrfs storage driver created the subvolumes, and one of them was the
# OS root. On a system still half in that layout the root it runs from is in
# there, so the directory may only go once both slots exist beside it.
environment_may_drop_docker_dir() {
  [[ -d "${TARGET_ROOT}/system-A" && -d "${TARGET_ROOT}/system-B" ]]
}

# The trap: stops a daemon of ours - with its data root, under the guard above -
# and unmounts. It removes nothing by path: target_mount can fail between its
# two mounts, and ${TARGET_ROOT}/docker would then be the target's own, with
# nothing of ours in it. Removing by path is with_environment's, once the task
# has run.
# shellcheck disable=SC2329 disable=SC2317
environment_cleanup() {
  if environment_may_drop_docker_dir; then
    docker_cleanup
  else
    docker_stop
  fi
  target_umount
}

# Runs "$@" with the target mounted and a docker daemon reachable. The task is a
# function of this shell, not a process: a raise inside it ends the run, and the
# trap is what unmounts.
with_environment() {
  trap environment_cleanup EXIT

  update-ca-certificates
  target_mount

  docker_ensure "${DOCKER_DIR}" || raise 94 "Could not start dockerd"
  docker info

  "$@"
  local rc="$?"

  # By path, so that what an earlier run left there goes as well. Here and not
  # in the trap: the failures before this line have put nothing there.
  if environment_may_drop_docker_dir; then
    docker_cleanup "${DOCKER_DIR}"
  fi

  return "${rc}"
}
