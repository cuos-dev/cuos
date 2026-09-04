#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# selftest.sh — check the invariants of a running CuOS system and report them
# as JSON. Reached as `cuos selftest`.
#
# This answers "is this system actually healthy?" in one call, for a support
# case and for an automated test alike. It only reads: nothing here changes the
# system, so it is safe to run at any time.
#
# Every check reports ok, failed or skipped. A check is skipped when it does not
# apply to this kind of system - a container has no disk subvolumes, and its
# network belongs to the host - never to hide a problem.

set -uo pipefail

CONFIG_PATH="${CONFIG_PATH:-"/system.json"}"
FILE_STATE="${T_FILE_STATE:-"/data/state.json"}"
FILE_SLOT="${T_FILE_SLOT:-"/etc/active_slot"}"
FILE_VERSION="${T_FILE_VERSION:-"/etc/image"}"
APP_CONTAINER="${APP_CONTAINER:-"cuos-app"}"
SSH_PORT="${SSH_PORT:-"4222"}"

RESULTS=()

record() {
  RESULTS+=("$(jq -nc \
    --arg id "$1" --arg status "$2" --arg detail "${3:-}" \
    '{id: $id, status: $status, detail: $detail}')")
}
ok() { record "$1" "ok" "${2:-}"; }
failed() { record "$1" "failed" "$2"; }
skipped() { record "$1" "skipped" "$2"; }

cfg() {
  jq -r "$1" "${CONFIG_PATH}" 2>/dev/null
}

# ------------------------------------------------------------ the outside world
#
# Everything the checks learn about the machine goes through one of these, so a
# test can replace them without a running system underneath.

virt_type() {
  systemd-detect-virt 2>/dev/null || echo "none"
}

is_container() {
  local virt
  virt="$(virt_type)"
  [[ "${virt}" == "lxc" || "${virt}" == "docker" ]]
}

# "<subvolume> <mountpoint>" per line, for every mounted btrfs subvolume.
subvolumes() {
  findmnt -t btrfs -no TARGET,OPTIONS 2>/dev/null \
    | sed -n 's|^\(\S*\)\s.*subvol=/\([^,]*\).*|\2 \1|p'
}

# "<interface> <address>/<prefix>" per line.
host_addresses() {
  ip -o -4 addr show 2>/dev/null | awk '{print $2, $4}'
}

system_hostname() {
  hostname 2>/dev/null
}

docker_ok() {
  docker info >/dev/null 2>&1
}

container_state() {
  docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null
}

listening_on() {
  ss -ltn 2>/dev/null | grep -qE "[:.]$1[[:space:]]"
}

# How many cuos journal entries of priority error or worse this boot produced.
journal_errors() {
  journalctl -t cuos -b -p 3 --no-pager -o cat 2>/dev/null | grep -c . || true
}

# ------------------------------------------------------------------- the checks

check_config() {
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    failed "config" "${CONFIG_PATH} does not exist"
    return
  fi
  if ! jq -e . "${CONFIG_PATH}" >/dev/null 2>&1; then
    failed "config" "${CONFIG_PATH} is not valid JSON"
    return
  fi
  ok "config" "$(cfg '."__filename" // "system.json"')"
}

check_version() {
  local version
  version="$(cat "${FILE_VERSION}" 2>/dev/null)"
  if [[ -z "${version}" ]]; then
    failed "version" "${FILE_VERSION} is empty or missing"
    return
  fi
  ok "version" "${version}"
}

check_slot() {
  local slot
  slot="$(cat "${FILE_SLOT}" 2>/dev/null)"
  case "${slot}" in
    A|B) ok "slot" "${slot}" ;;
    "") failed "slot" "${FILE_SLOT} is empty or missing" ;;
    *) failed "slot" "${FILE_SLOT} holds '${slot}', expected A or B" ;;
  esac
}

# The A/B design rests on these being separate subvolumes. A system that booted
# with @data missing would look healthy and lose every bit of state on update.
check_subvolumes() {
  if is_container; then
    skipped "subvolumes" "a container has no subvolumes; the root is swapped instead"
    return
  fi

  local mounted missing=""
  mounted="$(subvolumes)"
  local wanted
  for wanted in "@os" "@data"; do
    if ! grep -q "^${wanted}[[:space:]]" <<<"${mounted}"; then
      missing+="${missing:+, }${wanted}"
    fi
  done

  if [[ -n "${missing}" ]]; then
    failed "subvolumes" "not mounted: ${missing}"
    return
  fi
  ok "subvolumes" "$(tr '\n' ' ' <<<"$(cut -d' ' -f1 <<<"${mounted}")" | sed 's/ $//')"
}

check_state() {
  if [[ ! -f "${FILE_STATE}" ]]; then
    failed "state" "${FILE_STATE} does not exist"
    return
  fi

  local state starting
  state="$(jq -r '.state // "unknown"' "${FILE_STATE}" 2>/dev/null)"
  starting="$(jq -r '.starting // false' "${FILE_STATE}" 2>/dev/null)"

  if [[ "${state}" != "running" ]]; then
    failed "state" "state is '${state}', expected 'running'"
    return
  fi
  # The application clears this through 'report_app_ready'. An application that
  # never reports leaves it true forever, which is why this is a warning in the
  # detail rather than a failure.
  if [[ "${starting}" == "true" ]]; then
    ok "state" "running, but the application has not reported itself ready"
    return
  fi
  ok "state" "running"
}

check_docker() {
  if docker_ok; then
    ok "docker"
    return
  fi
  failed "docker" "docker is not responding"
}

check_app() {
  local status
  status="$(container_state "${APP_CONTAINER}")"
  case "${status}" in
    running) ok "app" "${APP_CONTAINER} is running" ;;
    "") failed "app" "there is no ${APP_CONTAINER} container" ;;
    *) failed "app" "${APP_CONTAINER} is ${status}" ;;
  esac
}

# Every statically configured address has to be on an interface. This is what
# catches a configuration that was written but never applied.
check_network() {
  if is_container; then
    skipped "network" "a container's interface is configured by its host"
    return
  fi

  local count
  count="$(cfg '(.network // []) | length')"
  if [[ "${count}" == "0" ]]; then
    skipped "network" "no network section in the configuration"
    return
  fi

  local addresses missing="" found=""
  addresses="$(host_addresses)"

  local i address
  for (( i = 0; i < count; i++ )); do
    address="$(cfg ".network[${i}][\"ip-address\"] // empty")"
    if [[ -z "${address}" ]]; then
      # DHCP, or an entry that only identifies an interface.
      continue
    fi
    if grep -qE "[[:space:]]${address}/" <<<"${addresses}"; then
      found+="${found:+, }${address}"
    else
      missing+="${missing:+, }${address}"
    fi
  done

  if [[ -n "${missing}" ]]; then
    failed "network" "configured but not on any interface: ${missing}"
    return
  fi
  if [[ -z "${found}" ]]; then
    skipped "network" "every interface is on DHCP"
    return
  fi
  ok "network" "${found}"
}

check_hostname() {
  local wanted actual
  wanted="$(cfg '.hostname // empty')"
  if [[ -z "${wanted}" ]]; then
    skipped "hostname" "no hostname in the configuration"
    return
  fi
  actual="$(system_hostname)"
  if [[ "${actual}" != "${wanted}" ]]; then
    failed "hostname" "system says '${actual}', configuration says '${wanted}'"
    return
  fi
  ok "hostname" "${actual}"
}

check_ssh() {
  local wanted
  wanted="$(cfg '.os_ssh_server // false')"
  if [[ "${wanted}" != "true" ]]; then
    skipped "ssh" "not enabled in the configuration"
    return
  fi
  if listening_on "${SSH_PORT}"; then
    ok "ssh" "listening on ${SSH_PORT}"
    return
  fi
  failed "ssh" "enabled in the configuration, but nothing listens on ${SSH_PORT}"
}

check_log() {
  local errors
  errors="$(journal_errors)"
  errors="${errors//[^0-9]/}"
  if [[ -z "${errors}" || "${errors}" == "0" ]]; then
    ok "log" "no errors this boot"
    return
  fi
  failed "log" "${errors} cuos log entries of level error or worse this boot"
}

## selftest           - Check the invariants of this system
selftest() {
  check_config
  check_version
  check_slot
  check_subvolumes
  check_state
  check_docker
  check_app
  check_network
  check_hostname
  check_ssh
  check_log

  printf '%s\n' "${RESULTS[@]}" | jq -s '
    {
      ok: ((map(select(.status == "failed")) | length) == 0),
      summary: {
        ok: (map(select(.status == "ok")) | length),
        failed: (map(select(.status == "failed")) | length),
        skipped: (map(select(.status == "skipped")) | length)
      },
      checks: .
    }'
}

# Execute only if the script is run, not sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  selftest
fi
