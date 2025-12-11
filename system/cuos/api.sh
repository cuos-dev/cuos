#!/bin/bash

SCRIPT_DIR="$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd)"

set -uo pipefail
trap '' PIPE

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

export CONFIG_PATH="/system.json"
export NEXT_CONFIG_PATH="/system_next.json"

api_command_help() {
  cat <<EOF
USAGE: cuos ACTION

ACTIONS:
EOF

  grep -E "^##" "${BASH_SOURCE[0]}" | sed -e 's/^## //'
  echo
}

## state              - Show current OS system state
api_command_state() {
  local file_state="${T_FILE_STATE:-"/data/state.json"}"
  local file_slot="${T_FILE_SLOT:-"/etc/active_slot"}"
  local file_version="${T_FILE_VERSION:-"/etc/image"}"
  local virt_type="$(systemd-detect-virt)"

  local version
  version="$(cat "${file_version}")"
  version="${version/*\//}"
  version="${version/@*/}"
  local slot
  slot="$(cat "${file_slot}")"
  jq \
    --arg slot "${slot}" \
    --arg version "${version}" \
    --arg virt_type "${virt_type}" \
    '. + {"slot": $slot, "version": $version, "virt_type": $virt_type}' \
     "${file_state}"
}

## version            - Show current system version
api_command_version() {
  cat "/etc/image"
}
api_command_version_json() {
  jq -nc \
    --arg version "$(api_command_version)" \
    '{"version": $version}'
}

api_handle_code() {
  local exit_code="${1:-}"
  # we only report potential user errors:
  if [[ "${exit_code}" == "0" ]]; then
    jq -nc \
      '{"err": 0, "message": "os update successful"}'
    echo "R"
  elif [[ "${exit_code}" == "60" ]]; then
    jq -nc \
      --arg code "${exit_code}" \
      '{"err": $code, "message": "Invalid configuration provided"}'
  elif [[ "${exit_code}" == "61" ]]; then
    jq -nc \
      --arg code "${exit_code}" \
      '{"err": $code, "message": "Invalid JSON provided"}'
  elif [[ "${exit_code}" == "101" || "${exit_code}" == "21" ]]; then
    jq -nc \
      --arg code "${exit_code}" \
      '{"err": $code, "message": "Not enough free disk space available"}'
  elif [[ "${exit_code}" == "102" || "${exit_code}" == "22" ]]; then
    jq -nc \
      '{"err": 0, "message": "No update available"}'
  else
    jq -nc \
      --arg code "${exit_code}" \
      '{"err": $code, "message": "OS update failed"}'
  fi
}

## update             - Perform OS update
api_command_update() {
  local input
  input="$(cat)"

  report_info "cuos:update:start" "Update process was triggered"
  local config
  config="$(echo "${input}" | jq -c '.config // {}')"
  if ! echo "${config}" | check_config; then
    report_err "cuos:update:err_invalid_config" "Update: Invalid configuration provided."
    echo "Invalid configuration provided."
    return 60
  fi

  # update and swap configuration (config -> new)
  local new_config
  new_config="$(echo "${config}" | jq -s '.[0] * .[1]' "${CONFIG_PATH}" -)" || return 61
  local old_config
  old_config="$(cat "${CONFIG_PATH}")"
  echo "${new_config}" >"${NEXT_CONFIG_PATH}"

  # perform update
  "${SCRIPT_DIR}/do-update.sh"
  local update_exit_code="$?"

  # if system container did not need an update
  if [[ "${update_exit_code}" = "22" || "${update_exit_code}" = "102" ]]; then
    # apply new configuration to CURRENT system:
    echo "${new_config}" >"${CONFIG_PATH}"
    # and save old configuration for rollback
    echo "${old_config}" >"${NEXT_CONFIG_PATH}"

    # apply changes to current partition
    "${SCRIPT_DIR}/init.sh" --reinit

    # we need to check, if app container needs update
    touch "/data/run-update-app"
    systemctl restart cuos-app-init.service

    return "${update_exit_code}"
  fi

  return "${update_exit_code}"
}
api_command_update_json() {
  api_command_update >&2
  api_handle_code "$?"
}

api_command_pull() {
  echo "Pull not jet implemented."
  return 1
}

api_command_trigger-update() {
  docker exec cuos-app /api/cuos-trigger-update
  R="$?"
  # if Container not started or API it not defined, perform cuos update
  if [[ "$R" == 1 || "$R" == "126" ]]; then
    cuos update
  fi
}

## patch              - Patch the current system. Provide config object.
api_command_patch_func() {
  local input
  input="$(cat)"

  report_info "cuos:patch" "Patching the system"
  local config
  config="$(echo "${input}" | jq -c '.config // empty')"
  if [[ -n "${config}" ]]; then
    if ! echo "${config}" | check_config; then
      report_err "cuos:update:err_invalid_config" "Update: Invalid configuration provided."
      echo "Invalid configuration provided."
      return 60
    fi
    # save current config for rollback:
    cat "${CONFIG_PATH}" >"${NEXT_CONFIG_PATH}"

    jq_replace \
      --argjson config "${config}" \
      '. * $config' \
      "${CONFIG_PATH}" || return 61
  fi

  # apply changes to current slot
  "${SCRIPT_DIR}/init.sh" --reinit
}
api_command_patch() {
  api_command_patch_func >&2
  api_handle_code "$?"
}

## patch-network      - Patch the network. Provide config object.
api_command_patch-network_func() {
  local input
  input="$(cat)"

  report_info "cuos:patch:network" "Patching the network"
  local config
  config="$(echo "${input}" | jq -c '.config // empty')"
  local network_id
  network_id="$(echo "${input}" | jq -r '.network_id // 0')"
  if [[ -n "${config}" ]]; then
    jq_replace \
      --argjson config "${config}" \
      --arg network_id "${network_id}" \
      '.network[$network_id | tonumber] = $config' \
      "${CONFIG_PATH}" || return 61

    "${SCRIPT_DIR}/init.sh" --reinit configure_network
  fi
}
api_command_patch-network() {
  api_command_patch-network_func >&2
  api_handle_code "$?"
}

## patch-hostname     - Patch the hostname. Provide config object.
api_command_patch-hostname_func() {
  local input
  input="$(cat)"

  report_info "cuos:patch:hostname" "Patching the hostname"
  local config
  config="$(echo "${input}" | jq -c '.config // empty')"
  if [[ -n "${config}" ]]; then
    jq_replace \
      --argjson config "${config}" \
      '.hostname = $config' \
      "${CONFIG_PATH}" || return 61

    "${SCRIPT_DIR}/init.sh" --reinit set_hostname
  fi
}
api_command_patch-hostname() {
  api_command_patch-hostname_func >&2
  api_handle_code "$?"
}

## rollback           - Rollback last OS update
api_command_rollback() {
  report_notice "cuos:useraction:rollback" "Manual rollback triggerd by the user"
  "${SCRIPT_DIR}/do-rollback.sh" "Manual rollback triggerd by the user"
}

## factory-reset      - Factory reset
api_command_factory-reset() {
  report_notice "cuos:useraction:factory-reset" "Factory reset triggered by the user"
  setsid "${SCRIPT_DIR}/do-factory-reset.sh" >/data/log/factory-reset.log 2>&1 &
  tail -f /data/log/factory-reset.log
}

## reboot             - Reboot the system
api_command_reboot() {
  report_notice "cuos:useraction:reboot" "Manual reboot triggered by the user"
  state '.state' 'starting'

  # disable live-restore for proper stop of all containers
  jq_replace '."live-restore" = false' /etc/docker/daemon.json
  systemctl reload docker

  sync

  echo "Rebooting ..."
  reboot
}

## shutdown           - Shutdown the system
api_command_shutdown() {
  report_notice "cuos:useraction:shutdown" "Manual shutdown triggered by the user"
  state '.state' 'starting'

  # disable live-restore for proper stop of all containers
  jq_replace '."live-restore" = false' /etc/docker/daemon.json
  systemctl reload docker

  sync

  echo "Shutting down ..."
  shutdown -h now
}

## log                - Get reports
api_command_log() {
  journalctl -t cuos -n 100 -o json | jq '{
    date: (.["__REALTIME_TIMESTAMP"] | tonumber / 1000000 | strftime("%Y-%m-%dT%H:%M:%S")),
    level: ({"0":"EMERGENCY","1":"ALERT","2":"CRITICAL","3":"ERROR","4":"WARNING","5":"NOTICE","6":"INFO","7":"DEBUG"}[.PRIORITY] // "INFO"),
    message: .MESSAGE
  }' | jq -s .
}

## report_app_ready   - App announces itself as ready.
api_command_report_app_ready() {
  local input
  input="$(cat)"

  if [[ "$(state '.starting')" == "true" ]]; then
    local message
    message="$(echo "${input}" | jq -r '.message // ""')"

    report_info "cuos:startup:done" "Startup complete${message+" - ${message}"}"
    state jq '.starting = false'
  fi
}

## report             - Write a report
api_command_report() {
  local input
  input="$(cat)"

  local id
  id="$(echo "${input}" | jq -r '.id // "cuos:userreport:other"')"
  local message
  message="$(echo "${input}" | jq -r '.message // ""')"
  local level
  level="$(echo "${input}" | jq -r '.level // ""')"

  logger -t cuos -p "daemon.${level}" "${id}" "${message}"
}

## app                - Call app API
api_command_app() {
  local input
  input="$(cat)"

  echo "${input}" | docker exec -i cuos-app /api/trigger "$@"
}

## resources          - Get resources
api_command_resources() {
  "${SCRIPT_DIR}/resources.sh"
}

api_main() {
  local input="{}"
  local command="${1:-""}"
  shift

  if [[ "${command}" = "input" ]]; then
    read -r input
    command="$(jq -r '.command // empty' <<< "${input}")"
  elif [[ "${1:-}" == "-" ]]; then
    input="$(cat)"
  fi

  case "${command}" in
    ""|"help"|"--help") command=help ;;
  esac

  local fcommand
  fcommand="$(echo "api_command_${command}" | sed -e 's/[:-]/_/g')"
  if [[ "$(type -t "${fcommand}")" != "function" ]]; then
    echo "No valid command provided. Exiting."
    return 0
  fi

  echo "${input}" | "${fcommand}" "$@"
  # exit with 0, because systemd socket activation otherwise stop working
  return 0
}

if [[ -f "${SCRIPT_DIR}/custom-api.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/custom-api.sh"
fi

# Execute main only if script is run, not sourced
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  api_main "$@"
fi
