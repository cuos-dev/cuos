#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

export TARGET_ROOT="${WORK_DIR}/os"
export TARGET_BOOT="${WORK_DIR}/boot"
export INSTALLIMAGE="true"
export INSTALLGRUB="false"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../system/cuos/lib-test.sh"

# shellcheck source=log.sh
source "${SCRIPT_DIR}/log.sh"
# shellcheck source=environment.sh
source "${SCRIPT_DIR}/environment.sh"

# The steps with_environment orders, each saying it happened. What they do is
# tested in docker.test.sh and by the mounts themselves.
LOG="${WORK_DIR}/steps.log"
target_mount() { echo "mount" >>"${LOG}"; }
target_umount() { echo "umount" >>"${LOG}"; }
docker_ensure() { echo "docker_ensure $1" >>"${LOG}"; }
docker_cleanup() { echo "docker_cleanup ${1:-<own>}" >>"${LOG}"; }
docker_stop() { echo "docker_stop" >>"${LOG}"; }
docker() { :; }

steps_of() {
  : >"${LOG}"
  ( with_environment "$@" >/dev/null 2>&1 )
  tr '\n' ' ' <"${LOG}"
  echo
}

task_that_works() {
  echo "task" >>"${LOG}"
}

# One slot only: the system may still run from inside ${TARGET_ROOT}/docker.
mkdir -p "${TARGET_ROOT}/system-A"
expect "with_environment: with one slot, docker/ is left alone" \
  "mount docker_ensure ${TARGET_ROOT}/docker task docker_stop umount " \
  steps_of task_that_works
mkdir -p "${TARGET_ROOT}/system-B"

expect "with_environment: mount, daemon, task, cleanup, unmount" \
  "mount docker_ensure ${TARGET_ROOT}/docker task docker_cleanup ${TARGET_ROOT}/docker docker_cleanup <own> umount " \
  steps_of task_that_works

task_that_fails() {
  return 3
}
rc_of() {
  ( "$@" ) >/dev/null 2>&1
}
expect_rc "with_environment: the task's exit code is the run's" 3 \
  rc_of with_environment task_that_fails

# A task is a function of this shell, so its raise ends the run - and the trap
# is what unmounts. The data root is not removed by path on that path: nothing
# after the failure put anything there.
task_that_raises() {
  raise 107 "no"
}
expect_rc "with_environment: a raise in the task ends the run" 107 \
  rc_of with_environment task_that_raises
expect "with_environment: and the trap still unmounts" \
  "mount docker_ensure ${TARGET_ROOT}/docker docker_cleanup <own> umount " \
  steps_of task_that_raises

no_target_device() {
  # shellcheck disable=SC2034
  ( INSTALLGRUB="true"; TARGET_DEVICE="${WORK_DIR}/absent"; with_environment task_that_works )
}
expect_rc "with_environment: no target device" 90 rc_of no_target_device

summary
