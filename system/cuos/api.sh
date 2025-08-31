#!/bin/bash

export CONFIG_PATH="/system.json"
export NEXT_CONFIG_PATH="/system_next.json"

set -uo pipefail

trap '' PIPE

SCRIPT_DIR="$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/functions.sh"

jq_replace() {
  local args=("$@")
  local file="${!#}"
  unset 'args[-1]'

  (
    #lock the execution
    flock -x 200

    local new_config
    new_config="$(jq "${args[@]}" "${file}")" || exit "$?"
    echo "${new_config}" >"${file}"

  ) 200>"/tmp/jq_replace.lock"
}

INPUT="{}"
COMMAND="${1:-""}"

if [[ "${COMMAND}" = "input" ]]; then
  read -r INPUT
  COMMAND="$(jq -r '.command // empty' <<< "${INPUT}")"
fi

if [[ "${COMMAND}" = "" || "${COMMAND}" = "help" || "${COMMAND}" = "--help" ]]; then
  cat <<EOF
USAGE: cuos ACTION

ACTIONS:
EOF

  grep -E "^##" "${BASH_SOURCE[0]}" | sed -e 's/^## \?//'

  echo

## version            - Show current system version
elif [[ "${COMMAND}" = "version" ]]; then
	cat "/etc/image"

## state              - Show current OS system state
elif [[ "${COMMAND}" = "state" ]]; then
	VERSION="$(cat "/etc/image")"
	VERSION="${VERSION/*\//}"
	VERSION="${VERSION/@*/}"
	PARTITION="$(cat "/etc/partition_mode")"
	jq \
		--arg partition "${PARTITION}" \
		--arg version "${VERSION}" \
		'.partition = $partition | .version = $version' \
		 "/data/state.json"

## update             - Perform OS update
elif [[ "${COMMAND}" = "update" ]]; then
	logger -t "cuos" "Update process was triggered"
	CONFIG="$(echo "${INPUT}" | jq -c '.config // empty')"
	if [[ -n "${CONFIG}" ]]; then
		NEW_CONFIG="$(echo "${CONFIG}" | jq -s '.[0] * .[1]' "${CONFIG_PATH}" -)" || exit 0
		OLD_CONFIG="$(cat "${CONFIG_PATH}")"
		# replace current config:
		echo "${NEW_CONFIG}" >"${NEXT_CONFIG_PATH}"
	else
		cat "${CONFIG_PATH}" >"${NEXT_CONFIG_PATH}"
	fi
	"${SCRIPT_DIR}/update.sh"
	UPDATE_EXIT_CODE="$?"

	if [[ "${UPDATE_EXIT_CODE}" = "2" ]]; then
		# swap next and current config:
		if [[ -n "${CONFIG}" ]]; then
			echo "${OLD_CONFIG}" >"/system_next.json"
			echo "${NEW_CONFIG}" >"/system.json"
		fi

		# and apply changes to current partition:
		"${SCRIPT_DIR}/init.sh" --reinit

		touch "/data/run-update"
		systemctl restart cuos-application.service
	fi

## patch              - Patch the system. Provide config object.
elif [[ "${COMMAND}" = "patch" ]]; then
	CONFIG="$(echo "${INPUT}" | jq -c '.config // empty')"
	# save current config for rollback:
	cat "${CONFIG_PATH}" >"${NEXT_CONFIG_PATH}"
	if [[ -n "${CONFIG}" ]]; then
		jq_replace \
			--argjson config "${CONFIG}" \
			'. * $config' \
			"${CONFIG_PATH}" || exit 0
	fi
	"${SCRIPT_DIR}/init.sh" --reinit

	touch "/data/run-update"
	systemctl restart cuos-application.service

## patch-network-0    - Patch the network[0]. Provide config object.
elif [[ "${COMMAND}" = "patch-network-0" ]]; then
	CONFIG="$(echo "${INPUT}" | jq -c '.config // empty')"
	if [[ -n "${CONFIG}" ]]; then
		jq_replace \
			--argjson config "${CONFIG}" \
			'.network[0] = $config' \
			"${CONFIG_PATH}" || exit 0
		"${SCRIPT_DIR}/init.sh" --reinit
	fi

## patch-network-1    - Patch the network[1]. Provide config object.
elif [[ "${COMMAND}" = "patch-network-1" ]]; then
	CONFIG="$(echo "${INPUT}" | jq -c '.config // empty')"
	if [[ -n "${CONFIG}" ]]; then
		jq_replace \
			--argjson config "${CONFIG}" \
			'.network[1] = $config' \
			"${CONFIG_PATH}" || exit 0
		"${SCRIPT_DIR}/init.sh" --reinit
	fi

## patch-hostname    - Patch the hostname. Provide config object.
elif [[ "${COMMAND}" = "patch-hostname" ]]; then
	CONFIG="$(echo "${INPUT}" | jq -c '.config // empty')"
	if [[ -n "${CONFIG}" ]]; then
		jq_replace \
			--argjson config "${CONFIG}" \
			'.hostname = $config' \
			"${CONFIG_PATH}" || exit 0
		"${SCRIPT_DIR}/init.sh" --reinit
	fi

## rollback           - Rollback last OS update
elif [[ "${COMMAND}" = "rollback" ]]; then
	"${SCRIPT_DIR}/rollback.sh" "Manual rollback triggerd by the user"

## factory-reset      - Factory reset
elif [[ "${COMMAND}" = "factory-reset" ]]; then
	logger -t "cuos" "Factory reset triggered by the user"
	"${SCRIPT_DIR}/factory-reset.sh"

## reboot             - Reboot the system
elif [[ "${COMMAND}" = "reboot" ]]; then
	logger -t "cuos" "Manuel reboot triggered by the user"
	"${SCRIPT_DIR}/state.sh" '.state' 'starting'
	/sbin/reboot

## shutdown           - Shutdown the system
elif [[ "${COMMAND}" = "shutdown" ]]; then
	logger -t "cuos" "Manuel shutdown triggered by the user"
	"${SCRIPT_DIR}/state.sh" '.state' 'starting'
	/sbin/shutdown -h now

## log                - Get reports
elif [[ "${COMMAND}" = "log" ]]; then
	#jq -s . /data/reports.json || echo "{}"
	journalctl -t cuos -n 100 -o json | jq '{
  date: (.["__REALTIME_TIMESTAMP"] | tonumber / 1000000 | strftime("%Y-%m-%dT%H:%M:%S")),
  level: ({"0":"EMERGENCY","1":"ALERT","2":"CRITICAL","3":"ERROR","4":"WARNING","5":"NOTICE","6":"INFO","7":"DEBUG"}[.PRIORITY] // "INFO"),
  message: .MESSAGE
}' | jq -s .

## app                - Call app API
elif [[ "${COMMAND}" = "app" ]]; then
	echo "${INPUT}" | docker exec -i cuos-app /api/trigger

## resources          - Get resources
elif [[ "${COMMAND}" = "resources" ]]; then
	"${SCRIPT_DIR}/resources.sh"

else
	echo "No valid command provided. Exiting."
fi

exit 0
