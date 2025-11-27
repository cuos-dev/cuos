#!/bin/bash

SCRIPT_DIR="$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd)"

set -uo pipefail
trap '' PIPE

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

export CONFIG_PATH="/system.json"
export NEXT_CONFIG_PATH="/system_next.json"
INPUT="{}"
COMMAND="${1:-""}"
shift

if [[ "${COMMAND}" = "input" ]]; then
  read -r INPUT
  COMMAND="$(jq -r '.command // empty' <<< "${INPUT}")"
elif [[ "${1:-}" == "-" ]]; then
  INPUT="$(cat)"
fi

if [[ -f "${SCRIPT_DIR}/custom-api.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/custom-api.sh"
fi

case "${COMMAND}" in
  ""|"help"|"--help")
    cat <<EOF
USAGE: cuos ACTION

ACTIONS:
EOF

    grep -E "^##" "${BASH_SOURCE[0]}" | sed -e 's/^## \?//'
    echo
  ;;
## version            - Show current system version
  "version")
    cat "/etc/image"
  ;;

## state              - Show current OS system state
  "state")
    VERSION="$(cat "/etc/image")"
    VERSION="${VERSION/*\//}"
    VERSION="${VERSION/@*/}"
    PARTITION="$(cat "/etc/partition_mode")"
    jq \
      --arg partition "${PARTITION}" \
      --arg version "${VERSION}" \
      '.partition = $partition | .version = $version' \
       "/data/state.json"
  ;;

## update             - Perform OS update
  "update")
    report_info "cuos:update:start" "Update process was triggered"
    CONFIG="$(echo "${INPUT}" | jq -c '.config // {}')"
    if ! echo "${CONFIG}" | check_config; then
      report_err "cuos:update:err_invalid_config" "Update: Invalid configuration provided."
      echo "Invalid configuration provided."
      exit 0
    fi

    # update and swap configuration (config -> new)
    NEW_CONFIG="$(echo "${CONFIG}" | jq -s '.[0] * .[1]' "${CONFIG_PATH}" -)" || exit 0
    OLD_CONFIG="$(cat "${CONFIG_PATH}")"
    echo "${NEW_CONFIG}" >"${NEXT_CONFIG_PATH}"

    # perform update
    "${SCRIPT_DIR}/do-update.sh"
    UPDATE_EXIT_CODE="$?"

    # if system container did not need an update
    if [[ "${UPDATE_EXIT_CODE}" = "2" ]]; then
      # apply new configuration to CURRENT system:
      echo "${NEW_CONFIG}" >"${CONFIG_PATH}"
      # and save old configuration for rollback
      echo "${OLD_CONFIG}" >"${NEXT_CONFIG_PATH}"

      # apply changes to current partition
      "${SCRIPT_DIR}/init.sh" --reinit

      # we need to check, if app container needs update
      touch "/data/run-update-app"
      systemctl restart cuos-app-init.service
    fi
  ;;
  "pull")
    echo "Pull not jet implemented."
  ;;
  "trigger-update")
    docker exec cuos-app /api/cuos-trigger-update
    R="$?"
    # if Container not started or API it not defined, perform cuos update
    if [[ "$R" == 1 || "$R" == "126" ]]; then
      cuos update
    fi
  ;;

## patch              - Patch the current system. Provide config object.
  "patch")
    report_info "cuos:patch" "Patching the system"
    CONFIG="$(echo "${INPUT}" | jq -c '.config // empty')"
    if [[ -n "${CONFIG}" ]]; then
      if ! echo "${CONFIG}" | check_config; then
        report_err "cuos:update:err_invalid_config" "Update: Invalid configuration provided."
        echo "Invalid configuration provided."
        exit 0
      fi
      # save current config for rollback:
      cat "${CONFIG_PATH}" >"${NEXT_CONFIG_PATH}"

      jq_replace \
        --argjson config "${CONFIG}" \
        '. * $config' \
        "${CONFIG_PATH}" || exit 0
    fi

    # apply changes to current partition
    "${SCRIPT_DIR}/init.sh" --reinit
  ;;

## patch-network    - Patch the network. Provide config object.
  "patch-network")
    report_info "cuos:patch:network" "Patching the network"
    CONFIG="$(echo "${INPUT}" | jq -c '.config // empty')"
    NETWORK_ID="$(echo "${INPUT}" | jq -r '.network_id // 0')"
    if [[ -n "${CONFIG}" ]]; then
      jq_replace \
        --argjson config "${CONFIG}" \
        --arg network_id "${NETWORK_ID}" \
        '.network[$network_id | tonumber] = $config' \
        "${CONFIG_PATH}" || exit 0
      "${SCRIPT_DIR}/init.sh" --reinit configure_network
    fi
  ;;

## patch-hostname    - Patch the hostname. Provide config object.
  "patch-hostname")
    report_info "cuos:patch:hostname" "Patching the hostname"
    CONFIG="$(echo "${INPUT}" | jq -c '.config // empty')"
    if [[ -n "${CONFIG}" ]]; then
      jq_replace \
        --argjson config "${CONFIG}" \
        '.hostname = $config' \
        "${CONFIG_PATH}" || exit 0
      "${SCRIPT_DIR}/init.sh" --reinit set_hostname
    fi
  ;;

## rollback           - Rollback last OS update
  "rollback")
    report_notice "cuos:useraction:rollback" "Manual rollback triggerd by the user"
    "${SCRIPT_DIR}/do-rollback.sh" "Manual rollback triggerd by the user"
  ;;

## factory-reset      - Factory reset
  "factory-reset")
    report_notice "cuos:useraction:factory-reset" "Factory reset triggered by the user"
    setsid "${SCRIPT_DIR}/do-factory-reset.sh" >/data/log/factory-reset.log 2>&1 &
    tail -f /data/log/factory-reset.log
  ;;

## reboot             - Reboot the system
  "reboot")
    report_notice "cuos:useraction:reboot" "Manual reboot triggered by the user"
    state '.state' 'starting'

    # disable live-restore for proper stop of all containers
    jq_replace '."live-restore" = false' /etc/docker/daemon.json
    systemctl reload docker

    sync

    echo "Rebooting ..."
    reboot
  ;;

## shutdown           - Shutdown the system
  "shutdown")
    report_notice "cuos:useraction:shutdown" "Manual shutdown triggered by the user"
    state '.state' 'starting'

    # disable live-restore for proper stop of all containers
    jq_replace '."live-restore" = false' /etc/docker/daemon.json
    systemctl reload docker

    sync

    echo "Shutting down ..."
    shutdown -h now
  ;;

## log                - Get reports
  "log")
    journalctl -t cuos -n 100 -o json | jq '{
      date: (.["__REALTIME_TIMESTAMP"] | tonumber / 1000000 | strftime("%Y-%m-%dT%H:%M:%S")),
      level: ({"0":"EMERGENCY","1":"ALERT","2":"CRITICAL","3":"ERROR","4":"WARNING","5":"NOTICE","6":"INFO","7":"DEBUG"}[.PRIORITY] // "INFO"),
      message: .MESSAGE
    }' | jq -s .
  ;;

## app                - Call app API
  "app")
    echo "${INPUT}" | docker exec -i cuos-app /api/trigger "$@"
  ;;

## resources          - Get resources
  "resources")
    "${SCRIPT_DIR}/resources.sh"
  ;;

  *)
    echo "No valid command provided. Exiting."
  ;;
esac

exit 0
