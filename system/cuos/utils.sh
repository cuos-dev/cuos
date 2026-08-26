#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

set -uo pipefail

CONFIG_PATH="${CONFIG_PATH:-"/system.json"}"

if [[ -n "${TEST:-}" ]]; then
  logger() {
    echo logger "$@"
  }
fi

report_emerg() {
  local msg_id="$1"
  shift
  logger -t cuos -p daemon.emerg "${msg_id}" "$@"
  echo "[emerg]" "${msg_id}" "$@" >&2
}
report_alert() {
  local msg_id="$1"
  shift
  logger -t cuos -p daemon.alert "${msg_id}:" "$@"
  echo "[alert]" "${msg_id}" "$@" >&2
}
report_crit() {
  local msg_id=$1
  shift
  logger -t cuos -p daemon.crit "${msg_id}:" "$@"
  echo "[crit]" "${msg_id}" "$@" >&2
}
report_err() {
  local msg_id="$1"
  shift
  logger -t cuos -p daemon.err "${msg_id}:" "$@"
  echo "[err]" "${msg_id}" "$@" >&2
}
report_warning() {
  local msg_id="$1"
  shift
  logger -t cuos -p daemon.warning "${msg_id}:" "$@"
  echo "[warning]" "${msg_id}" "$@" >&2
}
report_notice() {
  local msg_id="$1"
  shift
  logger -t cuos -p daemon.notice "${msg_id}:" "$@"
  echo "[notice]" "${msg_id}" "$@" >&2
}
report_info() {
  local msg_id="$1"
  shift
  logger -t cuos -p daemon.info "${msg_id}:" "$@"
  echo "[info]" "${msg_id}" "$@" >&2
}
report_debug() {
  local msg_id="$1"
  shift
  logger -t cuos -p daemon.debug "${msg_id}:" "$@"
  echo "[debug]" "${msg_id}" "$@" >&2
}


raise() {
  local code=1
  local message="$*"

  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    code="${1:-}"
    message="${*:2}"
  fi

  echo "Error: $message" >&2
  exit "$code"
}

raise_info() {
  local code=1
  local message="$*"

  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    code="${1:-}"
    message="${*:2}"
  fi

  echo "Info: $message" >&2
  exit "$code"
}

raise_okay() {
  echo "Error: $*" >&2
  exit 0
}

jq_config() {
  jq -r "$@" "${CONFIG_PATH}"
}

jq_replace() {
  # Usage: jq_replace jq_expression file
  # like jq, but with inplace edit function
  local args=("${@:1:$#-1}")
  local file="${!#}"

  (
    #lock the execution
    flock -x 200

    local new_config
    new_config="$(jq "${args[@]}" "${file}")" || exit "$?"
    echo "${new_config}" >"${file}"

  ) 200>"/tmp/jq_replace.lock"
}

state() {
  local key="$1"
  local value="${2:-}"
  local state_file="/data/state.json"
  local new_state

  if [[ ! -f "${state_file}" ]] || \
      ! jq . "${state_file}" >/dev/null 2>&1; then
    echo "{}" >"${state_file}"
  fi

  if [[ -z "${value}" ]]; then
    jq -r "${key}" "${state_file}"
    return "$?"
  fi

  if [[ "${key}" == "jq" ]]; then
    local expression="$2"
    new_state="$(jq \
      "${expression}" \
      "${state_file}")" || return "$?"
    echo "${new_state}" >"${state_file}"
    return 0
  fi

  new_state="$(jq \
    --arg value "${value}" \
    "${key}"' = $value' \
    "${state_file}")" || return "$?"
  echo "${new_state}" >"${state_file}"
}

check_config() {
  jv "${SCRIPT_DIR}/system-schema.json" "/dev/stdin"
}

image_url() {
  local image
  image="$(jq -r \
    --arg prefix "${1:-}" '
    (
      if (.[$prefix + "_image"] | (type == "string" and . != "" and
          ((startswith("/")) or (contains(".") | not)))) then
        (.update_registry_proxy // .update_registry) + "/" + .[$prefix + "_image"]
      else
        .[$prefix + "_image"]
      end
    ) + (
      if .[$prefix + "_image_version"] and .[$prefix + "_image_version"] != ""then
        ":" + .[$prefix + "_image_version"]
      else
        ""
      end
    ) | gsub("/+"; "/")
    ' "${CONFIG_PATH}")"
  if [[ -z "${image}" ]]; then return 1; fi
  echo "${image}"
}

image_version() {
  local image="${1:-""}"
  #remove registry name including :[port]
  image="${image##*/}"
  if [[ "${image}" != *:* ]]; then
    echo "latest"
    return
  fi
  local version="${image##*:}"
  echo "${version:-"latest"}"
}

rename_function() {
  local func_name="$1"
  local new_name="$2"

  if declare -f "${func_name}" >/dev/null; then
    eval "$(declare -f "${func_name}" | sed '1s/'"${func_name}"'/'"${new_name}"'/')"
  fi
}
