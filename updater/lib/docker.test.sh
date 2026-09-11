#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

# mocks: the daemon answers once someone has started it, so the fake dockerd
# reports readiness through a file - it runs in the background and cannot set a
# variable of ours.
docker() {
  [[ -n "${MOCK_DAEMON_ANSWERS-}" || -f "${WORK_DIR}/ready" ]]
}

dockerd() {
  echo "dockerd $*" >>"${WORK_DIR}/dockerd.log"
  [[ -n "${MOCK_DOCKERD_FAILS-}" ]] || : >"${WORK_DIR}/ready"
  # 'command', because sleep is mocked away below: a daemon that dies at once
  # takes the "the process is gone" path and never reaches the timeout.
  command sleep 5 >/dev/null 2>&1
}

btrfs() {
  echo "btrfs $*" >>"${WORK_DIR}/btrfs.log"
}

# The wait loop of a daemon that never answers would take 100 seconds, and
# docker_stop syncs every filesystem this machine has.
sleep() {
  :
}

sync() {
  :
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../system/cuos/lib-test.sh"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/docker.sh"

export CUOS_DOCKERD_WAIT=3

rc_of() {
  ( "$@" ) >/dev/null 2>&1
}

export CUOS_DOCKER_SOCKET="${WORK_DIR}/handed-in.sock"

expect_rc "docker_use_handed_in: no socket at all" 1 rc_of docker_use_handed_in

# A real socket, because docker_use_handed_in tests for one. perl is on every
# machine that runs this suite; nothing in the product needs it.
perl -e 'use IO::Socket::UNIX;
  IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => $ARGV[0], Listen => 1)
    or die $!;' "${CUOS_DOCKER_SOCKET}"
[[ -S "${CUOS_DOCKER_SOCKET}" ]] || echo "FAIL could not create a test socket"

# A socket that is there but answers nothing must not leave DOCKER_HOST behind,
# or the client never reaches a daemon started here.
host_after() {
  ( docker_use_handed_in
    echo "DOCKER_HOST=${DOCKER_HOST-}" )
}
expect "docker_use_handed_in: a socket that does not answer" "DOCKER_HOST=" \
  host_after

MOCK_DAEMON_ANSWERS=1
expect "docker_use_handed_in: a socket that answers" \
  "DOCKER_HOST=unix://${CUOS_DOCKER_SOCKET}" host_after

started_daemons() {
  : >"${WORK_DIR}/dockerd.log"
  ( docker_ensure "${WORK_DIR}/data-root" >/dev/null 2>&1
    grep -c "^dockerd " "${WORK_DIR}/dockerd.log" || true )
}
expect "docker_ensure: a handed-in daemon means no daemon of ours" "0" \
  started_daemons
MOCK_DAEMON_ANSWERS=""

rm -f "${WORK_DIR}/ready"
expect "docker_ensure: one of our own when nothing answers" "1" started_daemons
expect_rc "docker_ensure: and it is ready afterwards" 0 \
  rc_of docker_ensure "${WORK_DIR}/data-root"

rm -f "${WORK_DIR}/ready"
MOCK_DOCKERD_FAILS=1
expect "docker_ensure: a daemon that never answers is tried four times" "4" \
  started_daemons
expect_rc "docker_ensure: and then it fails" 1 \
  rc_of docker_ensure "${WORK_DIR}/data-root"

# A daemon that is up and silent still holds the lock on the data root, so
# every further attempt would fail against it.
no_orphan_left() {
  rm -f "${WORK_DIR}/ready"
  _CUOS_DOCKERD_PID=""
  docker_ensure "${WORK_DIR}/data-root" >/dev/null 2>&1
  echo "pid=${_CUOS_DOCKERD_PID}"
}
expect "docker_ensure: a daemon that never answers is not left running" "pid=" \
  no_orphan_left
MOCK_DOCKERD_FAILS=""

# Driven through docker_ensure, so that it is the wiring under test and not the
# state a test set by hand.
#   ours       - nothing answers, so a daemon is started here
#   leftover   - a daemon is handed in, and an earlier run's data root is there
data_root_after() {
  rm -rf "${WORK_DIR}/data-root" "${WORK_DIR}/ready"
  _CUOS_DOCKERD_PID=""
  _CUOS_DOCKERD_DATA_ROOT=""
  [[ "$1" = "leftover" ]] && MOCK_DAEMON_ANSWERS=1 || MOCK_DAEMON_ANSWERS=""

  docker_ensure "${WORK_DIR}/data-root" >/dev/null 2>&1
  # What a daemon leaves behind, whether it was ours or an earlier run's.
  mkdir -p "${WORK_DIR}/data-root/btrfs/subvolumes"

  docker_cleanup "${WORK_DIR}/data-root" >/dev/null 2>&1
  MOCK_DAEMON_ANSWERS=""
  [[ -d "${WORK_DIR}/data-root" ]] && echo "kept" || echo "gone"
}

# A copy of the system image that nothing reads afterwards, either way.
expect "docker_cleanup: the data root of our own daemon goes" "gone" \
  data_root_after "ours"
expect "docker_cleanup: an earlier run's leftover goes too" "gone" \
  data_root_after "leftover"

# Nothing started, nothing named: nothing removed.
untouched_without_a_path() {
  rm -rf "${WORK_DIR}/data-root"
  mkdir -p "${WORK_DIR}/data-root"
  _CUOS_DOCKERD_PID=""
  _CUOS_DOCKERD_DATA_ROOT=""

  docker_cleanup >/dev/null 2>&1
  [[ -d "${WORK_DIR}/data-root" ]] && echo "kept" || echo "gone"
}
expect "docker_cleanup: no data root named, nothing removed" "kept" \
  untouched_without_a_path

stops_the_daemon() {
  rm -f "${WORK_DIR}/ready"
  MOCK_DAEMON_ANSWERS=""
  docker_ensure "${WORK_DIR}/data-root" >/dev/null 2>&1
  docker_cleanup "${WORK_DIR}/data-root" >/dev/null 2>&1
  echo "pid=${_CUOS_DOCKERD_PID}"
}
expect "docker_cleanup: the daemon is stopped first" "pid=" stops_the_daemon

summary
