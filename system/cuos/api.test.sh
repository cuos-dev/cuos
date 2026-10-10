#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR="$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd)"

set -euo pipefail

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-test.sh"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/api.sh"

"${SCRIPT_DIR}/api.sh" help >/dev/null || exit 1

# mocks:
systemd-detect-virt() {
  echo "test-system"
}


T_FILE_STATE="${T_FILE_STATE:-"${SCRIPT_DIR}/api.test.state.json"}"
T_FILE_SLOT="${T_FILE_SLOT:-"${SCRIPT_DIR}/api.test.active_slot"}"
T_FILE_VERSION="${T_FILE_VERSION:-"${SCRIPT_DIR}/api.test.image"}"
expect \
  "api: state" \
  $'{\n  "start_date": "2025-12-07T12:33:51Z",\n  "last_update_check": "2025-12-01T22:59:28Z",\n  "state": "running",\n  "last_update_date": "2025-12-01T23:00:03Z",\n  "update_state": "updated partition B to ghcr.io/cuos-dev/cuos-system-lxc:v0.4.0",\n  "slot": "B",\n  "version": "cuos-system-lxc:v0.4.0",\n  "virt_type": "test-system"\n}' \
  api_main state

# mock of journalctl
journalctl() {
	cat <<EOF
{"SYSLOG_IDENTIFIER":"cuos","__CURSOR":"s=123;i=123;b=123;m=123;t=123;x=123","_CAP_EFFECTIVE":"123","SYSLOG_FACILITY":"3","_GID":"0","_RUNTIME_SCOPE":"system","__REALTIME_TIMESTAMP":"1773230248262606","SYSLOG_TIMESTAMP":"Mar 11 11:57:28 ","_SYSTEMD_SLICE":"system.slice","__MONOTONIC_TIMESTAMP":"5468251","PRIORITY":"6","_COMM":"logger","_UID":"0","_SYSTEMD_INVOCATION_ID":"123","MESSAGE":"cuos:startup:start: System starting up ...","_TRANSPORT":"syslog","_SYSTEMD_UNIT":"cuos-init.service","__SEQNUM_ID":"123","_PID":"123","__SEQNUM":"123","_SELINUX_CONTEXT":"system_u:system_r:kernel_t:s0","_SOURCE_REALTIME_TIMESTAMP":"1773230248261618","_BOOT_ID":"123","_SYSTEMD_CGROUP":"/system.slice/cuos-init.service","_HOSTNAME":"cuos-test"}
{"_HOSTNAME":"cuos-test","__SEQNUM":"123","_CAP_EFFECTIVE":"123","_GID":"0","SYSLOG_FACILITY":"3","PRIORITY":"4","_SELINUX_CONTEXT":"system_u:system_r:kernel_t:s0","__SEQNUM_ID":"123","__CURSOR":"123","_BOOT_ID":"123","_SOURCE_REALTIME_TIMESTAMP":"1773230250152197","_COMM":"logger","_TRANSPORT":"syslog","SYSLOG_TIMESTAMP":"Mar 11 11:57:30 ","__MONOTONIC_TIMESTAMP":"7357897","SYSLOG_IDENTIFIER":"cuos","MESSAGE":"cuos:init:ssh_server: Start SSH server","__REALTIME_TIMESTAMP":"1773230250152252","_PID":"1037","_RUNTIME_SCOPE":"system","_UID":"0"}
{"__CURSOR":"123","__REALTIME_TIMESTAMP":"1780498350663053","_TRANSPORT":"syslog","_BOOT_ID":"123","MESSAGE":"cuos:mytest:err: My Error","SYSLOG_IDENTIFIER":"cuos","__SEQNUM_ID":"123","_HOSTNAME":"cuos-test","_GID":"0","_MACHINE_ID":"123","_SOURCE_REALTIME_TIMESTAMP":"1780498350663004","_COMM":"logger","_UID":"0","__MONOTONIC_TIMESTAMP":"16680766204072","SYSLOG_TIMESTAMP":"Jun  3 14:52:30 ","_RUNTIME_SCOPE":"system","__SEQNUM":"123","_PID":"123","PRIORITY":"3","SYSLOG_FACILITY":"3"}
EOF
}

expect \
  "api: log" \
  $'[\n  {\n    "date": "2026-03-11T11:57:28",\n    "level": "info",\n    "type": "cuos:startup:start",\n    "message": "System starting up ..."\n  },\n  {\n    "date": "2026-03-11T11:57:30",\n    "level": "warning",\n    "type": "cuos:init:ssh_server",\n    "message": "Start SSH server"\n  },\n  {\n    "date": "2026-06-03T14:52:30",\n    "level": "error",\n    "type": "cuos:mytest:err",\n    "message": "My Error"\n  }\n]' \
  api_main log

expect \
  "api: log" \
  $'{"date":"2026-03-11T11:57:28","level":"info","type":"cuos:startup:start","message":"System starting up ..."}\n{"date":"2026-03-11T11:57:30","level":"warning","type":"cuos:init:ssh_server","message":"Start SSH server"}\n{"date":"2026-06-03T14:52:30","level":"error","type":"cuos:mytest:err","message":"My Error"}' \
  api_main log-follow

# update and pull. The device's files live in a scratch directory; do-update.sh
# and init.sh are replaced by functions that record what they were given.
WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

export T_RUN_DIR="${WORK_DIR}/run"
mkdir -p "${T_RUN_DIR}"
CONFIG_PATH="${WORK_DIR}/system.json"
NEXT_CONFIG_PATH="${WORK_DIR}/system_next.json"

check_config() {
  jq -e 'type == "object"' >/dev/null
}
systemctl() {
  :
}
touch() {
  :
}
report_info() {
  :
}
report_err() {
  :
}

MOCK_DO_UPDATE_RC=0
api_do_update() {
  echo "$1" >"${WORK_DIR}/action"
  jq -c . "$2" >"${WORK_DIR}/given"
  return "${MOCK_DO_UPDATE_RC}"
}
api_reinit() {
  echo "reinit" >>"${WORK_DIR}/reinit"
}

device() {
  echo '{"os_image_version": "v1", "hostname": "box"}' >"${CONFIG_PATH}"
  echo '{"os_image_version": "v0", "hostname": "box"}' >"${NEXT_CONFIG_PATH}"
  rm -f "${WORK_DIR}/action" "${WORK_DIR}/given" "${WORK_DIR}/reinit"
}

# $1 is the command, $2 the config given, $3 the code do-update.sh returns.
# Prints the code, then both configuration files and what is left in /run.
call() {
  local rc

  MOCK_DO_UPDATE_RC="$3"
  echo "{\"config\": $2}" | "api_command_$1" >/dev/null 2>&1
  rc="$?"
  echo "rc=${rc}"
  echo "action=$(cat "${WORK_DIR}/action" 2>/dev/null)"
  echo "given=$(cat "${WORK_DIR}/given" 2>/dev/null)"
  echo "system=$(jq -c . "${CONFIG_PATH}")"
  echo "next=$(jq -c . "${NEXT_CONFIG_PATH}")"
  echo "reinit=$(cat "${WORK_DIR}/reinit" 2>/dev/null | wc -l | tr -d ' ')"
  echo "run=$(ls "${T_RUN_DIR}")"
}

device
expect "update: a failed update leaves the rollback slot's config alone" \
'rc=103
action=update
given={"os_image_version":"v2","hostname":"box"}
system={"os_image_version":"v1","hostname":"box"}
next={"os_image_version":"v0","hostname":"box"}
reinit=0
run=' \
  call update '{"os_image_version": "v2"}' 103

device
expect "update: no new image - the config applies to this slot, the old one is kept" \
'rc=102
action=update
given={"os_image_version":"v1","hostname":"other"}
system={"os_image_version":"v1","hostname":"other"}
next={"os_image_version":"v1","hostname":"box"}
reinit=1
run=' \
  call update '{"hostname": "other"}' 102

device
expect "update: no new image, no new config - nothing is written" \
'rc=22
action=update
given={"os_image_version":"v1","hostname":"box"}
system={"os_image_version":"v1","hostname":"box"}
next={"os_image_version":"v0","hostname":"box"}
reinit=1
run=' \
  call update '{}' 22

device
expect "update: an invalid config reaches nothing" \
'rc=60
action=
given=
system={"os_image_version":"v1","hostname":"box"}
next={"os_image_version":"v0","hostname":"box"}
reinit=0
run=' \
  call update '"not an object"' 0

device
expect "pull: fetches for the merged config and writes nothing" \
'rc=0
action=pull
given={"os_image_version":"v2","hostname":"box"}
system={"os_image_version":"v1","hostname":"box"}
next={"os_image_version":"v0","hostname":"box"}
reinit=0
run=' \
  call pull '{"os_image_version": "v2"}' 0

device
expect "pull: nothing new applies nothing either" \
'rc=102
action=pull
given={"os_image_version":"v1","hostname":"other"}
system={"os_image_version":"v1","hostname":"box"}
next={"os_image_version":"v0","hostname":"box"}
reinit=0
run=' \
  call pull '{"hostname": "other"}' 102

expect "api_handle_code: a pull that worked" \
  '{"err":0,"message":"images fetched, an update installs them"}' \
  api_handle_code 0 pull
expect "api_handle_code: an updater that cannot pull" \
  '{"err":"35","message":"The updater of this configuration cannot pull"}' \
  api_handle_code 35 pull
expect "api_handle_code: an update that worked" \
  '{"err":0,"message":"os update successful"}' \
  api_handle_code 0

summary
