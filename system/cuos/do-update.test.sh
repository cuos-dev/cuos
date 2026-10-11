#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# do-update.sh runs as it does on a device, as a process of its own. What it
# reaches outside - docker, the boot disk, reboot - are commands in a directory
# put first in PATH; the device's files live in a scratch directory.

SCRIPT_DIR="$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-test.sh"

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

BIN="${WORK_DIR}/bin"
mkdir -p "${BIN}" "${WORK_DIR}/data" "${WORK_DIR}/run" "${WORK_DIR}/etc"

stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"${BIN}/$1"
  chmod +x "${BIN}/$1"
}
stub systemd-detect-virt 'echo none'
stub findmnt 'echo /dev/sda3'
stub lsblk 'echo sda'
stub arch 'echo x86_64'
stub logger ':'
stub sync ':'
stub reboot 'echo reboot >>"${WORK_DIR}/log"'
stub login 'exit 0'
stub docker '
case "$1" in
  image) exit "${MOCK_PULL_RC:-0}" ;;
  inspect) echo "registry.local/cuos/updater@sha256:uuuu" ;;
  run) echo "run $*" >>"${WORK_DIR}/log"; exit "${MOCK_RUN_RC:-0}" ;;
esac'

export WORK_DIR
export PATH="${BIN}:${PATH}"
export TMPDIR="${WORK_DIR}/run"
export LAYER_DIR="${WORK_DIR}/data"
export LAYER_LOCK="${WORK_DIR}/lock"
export T_FILE_SLOT="${WORK_DIR}/etc/active_slot"
export T_FILE_IMAGE="${WORK_DIR}/etc/image"
export T_FILE_ARCH="${WORK_DIR}/etc/cuos-arch"
export T_FILE_STATE="${WORK_DIR}/data/state.json"
export T_ACTIVE_CONFIG_PATH="${WORK_DIR}/data/system_A.json"
export T_NEXT_CONFIG_PATH="${WORK_DIR}/data/system_B.json"
export T_DOCKER_LOGIN="${BIN}/login"
export T_DOCKER_CONFIG="${WORK_DIR}/docker-config.json"
export T_DATA_DIR="${WORK_DIR}/data"

# The layer functions, to set the device up as this code would have left it.
export CONFIG_PATH="${T_ACTIVE_CONFIG_PATH}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"
set +u

# Slot A runs v1, with a network set at the console; B holds v0. The update is
# to v2, and it changes the network, so the console's goes - in B.
device() {
  rm -rf "${WORK_DIR}/data"/* "${WORK_DIR}/log" "${WORK_DIR}/run"/*
  echo "A" >"${T_FILE_SLOT}"
  echo "x86_64" >"${T_FILE_ARCH}"
  echo "registry.local/cuos/os:v1@sha256:1111" >"${T_FILE_IMAGE}"
  echo '{"os_image": "registry.local/cuos/os", "os_image_version": "v1", "updater_image": "registry.local/cuos/updater", "network": [{"dhcp": true}]}' \
    >"$(config_remote_path A)"
  echo '{"network": [{"dhcp": false, "ip-address": "10.0.0.5"}]}' >"$(config_local_path A)"
  config_rebuild >/dev/null
  echo '{"os_image_version": "v0"}' >"${T_NEXT_CONFIG_PATH}"

  local plan
  plan="$(config_plan_update "$(config_read "$(config_remote_path A)")" \
    '{"os_image_version": "v2", "network": [{"dhcp": true, "gateway": "10.0.0.1"}]}')"
  echo "${plan}" >"${WORK_DIR}/run/update.plan"
  config_effective "$(jq -c .remote <<<"${plan}")" \
    "$(config_withdraw "$(config_read "$(config_local_path A)")" \
      "$(jq -c .changed <<<"${plan}")" "$(jq -c .remote <<<"${plan}")")" \
    >"${WORK_DIR}/run/update.json"
}

# $1 the action. Prints the exit code.
run() {
  bash "${SCRIPT_DIR}/do-update.sh" "$1" "${WORK_DIR}/run/update.json" \
    "${WORK_DIR}/run/update.plan" >/dev/null 2>&1
  echo "rc=$?"
}

rebooted() {
  grep -c "^reboot$" "${WORK_DIR}/log" 2>/dev/null || true
}

# $1 a pattern. How many docker runs passed it.
docker_runs_with() {
  grep "^run " "${WORK_DIR}/log" | grep -c -- "$1" || true
}

a_layers() {
  echo "$(jq -c . "$(config_remote_path A)") $(jq -c . "$(config_local_path A)")"
}
A_BEFORE='{"os_image":"registry.local/cuos/os","os_image_version":"v1","updater_image":"registry.local/cuos/updater","network":[{"dhcp":true}]} {"network":[{"dhcp":false,"ip-address":"10.0.0.5"}]}'

device
expect "update: installed" "rc=0" run update
expect "update: reboots" "1" rebooted
expect "update: the new slot's configuration" \
  '{"os_image":"registry.local/cuos/os","os_image_version":"v2","updater_image":"registry.local/cuos/updater","network":[{"dhcp":true,"gateway":"10.0.0.1"}]}' \
  jq -c . "${T_NEXT_CONFIG_PATH}"
expect "update: the new slot's local layer, without the withdrawn network" '{}' \
  jq -c . "$(config_local_path B)"
expect "update: the running slot's layers stay, for a rollback" "${A_BEFORE}" a_layers
expect "update: and its configuration" \
  '{"os_image":"registry.local/cuos/os","os_image_version":"v1","updater_image":"registry.local/cuos/updater","network":[{"dhcp":false,"ip-address":"10.0.0.5"}]}' \
  jq -c . "${T_ACTIVE_CONFIG_PATH}"
expect "update: the default entrypoint - a downgrade's updater has no other" "0" \
  docker_runs_with "--entrypoint"
expect "update: the app is told" "yes" \
  bash -c '[[ -f "$1" ]] && echo yes' _ "${T_DATA_DIR}/run-update"

device
MOCK_RUN_RC=1 expect "update: a failed install" "rc=1" run update
expect "update: does not reboot" "0" rebooted
expect "update: leaves the standby slot's configuration" '{"os_image_version":"v0"}' \
  jq -c . "${T_NEXT_CONFIG_PATH}"
expect "update: and writes no layer for it" "none" \
  bash -c '[[ -e "$1" || -e "$2" ]] && echo some || echo none' _ \
  "$(config_remote_path B)" "$(config_local_path B)"

device
T_NEXT_CONFIG_PATH="${WORK_DIR}/no/such/dir/system_B.json" \
  expect "update: installed, but the configuration cannot be written" "rc=36" run update
expect "update: then it does not reboot" "0" rebooted
expect "update: and the running slot's layers stay" "${A_BEFORE}" a_layers

device
MOCK_RUN_RC=101 expect "update: no room" "rc=101" run update
expect "update: no reboot" "0" rebooted

device
MOCK_RUN_RC=127 expect "pull: an updater without /api/pull" "rc=35" run pull
expect "pull: asked for by name" "1" docker_runs_with "--entrypoint /api/pull"
expect "pull: never reboots" "0" rebooted

device
expect "pull: fetched" "rc=0" run pull
expect "pull: writes nothing" '{"os_image_version":"v0"} none' \
  bash -c 'echo "$(jq -c . "$1") $([[ -e "$2" ]] && echo some || echo none)"' _ \
  "${T_NEXT_CONFIG_PATH}" "$(config_remote_path B)"

device
echo "registry.local/cuos/os:v2@" >"${T_FILE_IMAGE}"
expect "update: the image is installed already" "rc=22" run update

device
MOCK_PULL_RC=1 expect "update: the updater cannot be fetched" "rc=34" run update

summary
