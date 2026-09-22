#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# The MOCK_* variables and RESULTS are inputs of the sourced script under test,
# which shellcheck cannot see being read.
# shellcheck disable=SC2034

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

export CONFIG_PATH="${TMP}/system.json"
export T_FILE_STATE="${TMP}/state.json"
export T_FILE_SLOT="${TMP}/active_slot"
export T_FILE_VERSION="${TMP}/image"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/selftest.sh"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-test.sh"

# Nothing here touches a real system: every function that looks outward is
# replaced, and the files the checks read live in a temporary directory.
MOCK_VIRT="none"
MOCK_SUBVOLUMES="@os/system-A /
@data /data
@swap /swap"
MOCK_ADDRESSES="eth0 10.0.0.5/24"
MOCK_HOSTNAME="my-system"
MOCK_DOCKER_OK=0
MOCK_APP_STATE="running"
MOCK_LISTENING=0
MOCK_JOURNAL_ERRORS=0
MOCK_APPARMOR_ENABLED=0
MOCK_APPARMOR_PROFILES="docker-default (enforce)
/usr/sbin/dhclient (enforce)
unix-chkpwd (enforce)"

virt_type() { echo "${MOCK_VIRT}"; }
subvolumes() { echo "${MOCK_SUBVOLUMES}"; }
host_addresses() { echo "${MOCK_ADDRESSES}"; }
system_hostname() { echo "${MOCK_HOSTNAME}"; }
docker_ok() { return "${MOCK_DOCKER_OK}"; }
container_state() { echo "${MOCK_APP_STATE}"; }
listening_on() { return "${MOCK_LISTENING}"; }
journal_errors() { echo "${MOCK_JOURNAL_ERRORS}"; }
apparmor_enabled() { return "${MOCK_APPARMOR_ENABLED}"; }
apparmor_profiles() { echo "${MOCK_APPARMOR_PROFILES}"; }

# A healthy system, which each test then breaks in exactly one way.
reset_system() {
  RESULTS=()
  MOCK_VIRT="none"
  MOCK_SUBVOLUMES="@os/system-A /
@data /data
@swap /swap"
  MOCK_ADDRESSES="eth0 10.0.0.5/24"
  MOCK_HOSTNAME="my-system"
  MOCK_DOCKER_OK=0
  MOCK_APP_STATE="running"
  MOCK_LISTENING=0
  MOCK_JOURNAL_ERRORS=0
  MOCK_APPARMOR_ENABLED=0
  MOCK_APPARMOR_PROFILES="docker-default (enforce)
/usr/sbin/dhclient (enforce)
unix-chkpwd (enforce)"

  cat >"${CONFIG_PATH}" <<'EOF'
{
  "hostname": "my-system",
  "os_ssh_server": true,
  "network": [
    { "ip-address": "10.0.0.5", "network-mask": "255.255.255.0" }
  ]
}
EOF
  echo '{"state":"running","starting":false}' >"${T_FILE_STATE}"
  echo "A" >"${T_FILE_SLOT}"
  echo "ghcr.io/cuos-dev/cuos-system:development" >"${T_FILE_VERSION}"
}

# The whole report, for the assertions about the summary.
report() {
  reset_system
  "$@" >/dev/null 2>&1
  selftest
}

# The status of one check, after breaking the system with "$@".
status_of() {
  local id="$1"
  shift
  report "$@" | jq -r --arg id "${id}" '.checks[] | select(.id == $id) | .status'
}

detail_of() {
  local id="$1"
  shift
  report "$@" | jq -r --arg id "${id}" '.checks[] | select(.id == $id) | .detail'
}

overall() {
  report "$@" | jq -r '.ok'
}

nothing() { :; }

# ------------------------------------------------------------- a healthy system

failures_of() {
  report "$@" | jq -r '.summary.failed'
}

expect "a healthy system passes" "true" overall nothing
expect "a healthy system has no failed checks" "0" failures_of nothing

# ------------------------------------------------------------------ each check

break_config() { echo 'not json' >"${CONFIG_PATH}"; }
expect "config: invalid JSON fails" "failed" status_of config break_config
expect "config: a missing file fails" "failed" status_of config rm -f "${CONFIG_PATH}"

expect "version: an empty /etc/image fails" "failed" status_of version \
  bash -c ": >\"${T_FILE_VERSION}\""

break_slot() { echo "C" >"${T_FILE_SLOT}"; }
expect "slot: A or B, nothing else" "failed" status_of slot break_slot
expect "slot: an empty file fails" "failed" status_of slot rm -f "${T_FILE_SLOT}"

drop_data_subvolume() { MOCK_SUBVOLUMES="@os/system-A /"; }
expect "subvolumes: a missing @data fails" "failed" status_of subvolumes \
  drop_data_subvolume
expect "subvolumes: the failure names it" "not mounted: @data" detail_of \
  subvolumes drop_data_subvolume

# The root is @os/system-A or @os/system-B, never @os itself.
expect "subvolumes: the slot below @os counts as @os" "ok" status_of subvolumes
lose_the_os_subvolume() { MOCK_SUBVOLUMES="@osold/system-A /
@data /data"; }
expect "subvolumes: a subvolume merely starting with @os does not" "failed" \
  status_of subvolumes lose_the_os_subvolume

be_a_container() { MOCK_VIRT="lxc"; }
expect "subvolumes: skipped in a container" "skipped" status_of subvolumes \
  be_a_container
expect "network: skipped in a container - the host owns it" "skipped" \
  status_of network be_a_container
expect "a container is still healthy overall" "true" overall be_a_container

still_starting() { echo '{"state":"running","starting":true}' >"${T_FILE_STATE}"; }
expect "state: running but not ready is not a failure" "ok" status_of state \
  still_starting
expect "state: and says so" "running, but the application has not reported itself ready" \
  detail_of state still_starting

is_updating() { echo '{"state":"updating"}' >"${T_FILE_STATE}"; }
expect "state: anything but running fails" "failed" status_of state is_updating

break_docker() { MOCK_DOCKER_OK=1; }
expect "docker: an unresponsive daemon fails" "failed" status_of docker break_docker

lsm_off() { MOCK_APPARMOR_ENABLED=1; }
expect "apparmor: a kernel with the LSM off fails" "failed" status_of apparmor lsm_off
expect "apparmor: the failure names the command line" \
  "the kernel has AppArmor off - check apparmor=1 on the command line" \
  detail_of apparmor lsm_off

no_docker_default() { MOCK_APPARMOR_PROFILES="/usr/sbin/dhclient (enforce)"; }
expect "apparmor: enabled but no docker-default fails" "failed" status_of \
  apparmor no_docker_default
expect "apparmor: the failure counts what did load" \
  "dockerd loaded no docker-default; profiles in the kernel: 1" detail_of \
  apparmor no_docker_default

complaining() { MOCK_APPARMOR_PROFILES="docker-default (complain)"; }
expect "apparmor: a complaining docker-default fails" "failed" status_of \
  apparmor complaining
expect "apparmor: and says it confines nothing" \
  "docker-default is in complain mode, so it confines nothing" detail_of \
  apparmor complaining

# "docker-default-something" is a different profile, not this one.
similar_name() { MOCK_APPARMOR_PROFILES="docker-default-old (enforce)"; }
expect "apparmor: a profile merely starting with the name does not count" \
  "failed" status_of apparmor similar_name

expect "apparmor: a healthy system reports the count" \
  "3 profiles loaded, docker-default enforcing" detail_of apparmor nothing
expect "apparmor: skipped in a container" "skipped" status_of apparmor \
  be_a_container

app_exited() { MOCK_APP_STATE="exited"; }
expect "app: a stopped application fails" "failed" status_of app app_exited
app_missing() { MOCK_APP_STATE=""; }
expect "app: a missing container fails" "failed" status_of app app_missing

wrong_address() { MOCK_ADDRESSES="eth0 192.168.1.9/24"; }
expect "network: a configured address that is not on the machine fails" "failed" \
  status_of network wrong_address
expect "network: the failure names the address" \
  "configured but not on any interface: 10.0.0.5" detail_of network wrong_address

use_dhcp() { echo '{"hostname":"my-system","network":[{"dhcp":true}]}' >"${CONFIG_PATH}"; }
expect "network: DHCP everywhere is skipped, not failed" "skipped" status_of \
  network use_dhcp

no_network() { echo '{"hostname":"my-system"}' >"${CONFIG_PATH}"; }
expect "network: no section at all is skipped" "skipped" status_of network no_network

renamed() { MOCK_HOSTNAME="something-else"; }
expect "hostname: a mismatch fails" "failed" status_of hostname renamed
expect "hostname: the failure shows both" \
  "system says 'something-else', configuration says 'my-system'" detail_of \
  hostname renamed

ssh_not_listening() { MOCK_LISTENING=1; }
expect "ssh: enabled but not listening fails" "failed" status_of ssh \
  ssh_not_listening
expect "ssh: not enabled is skipped" "skipped" status_of ssh no_network

had_errors() { MOCK_JOURNAL_ERRORS=3; }
expect "log: errors this boot fail" "failed" status_of log had_errors
expect "log: the failure counts them" \
  "3 cuos log entries of level error or worse this boot" detail_of log had_errors

# --------------------------------------------------------------- the whole report

expect "one failed check fails the whole report" "false" overall renamed
expect "a skipped check does not" "true" overall be_a_container

check_count() {
  report nothing | jq -r '.checks | length'
}
expect "every check reports" "12" check_count

summary_adds_up() {
  report nothing | jq -r '
    if (.summary.ok + .summary.failed + .summary.skipped) == (.checks | length)
    then "yes" else "no" end'
}
expect "the summary adds up" "yes" summary_adds_up

summary
