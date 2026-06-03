#!/bin/bash

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

summary
