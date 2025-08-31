#!/bin/bash

KEY="$1"
VALUE="$2"
STATE_FILE="/data/state.json"

if [[ ! -f "${STATE_FILE}" ]] || \
		! jq . "${STATE_FILE}" >/dev/null 2>&1; then
	echo "{}" >"${STATE_FILE}"
fi

if [[ -z "${VALUE}" ]]; then
	jq -r "${KEY}" "${STATE_FILE}"
	exit "$?"
fi

if [[ "${KEY}" == "jq" ]]; then
	EXPRESSION="$2"
	NEW_STATE="$(jq \
		"${EXPRESSION}" \
		"${STATE_FILE}")" || exit "$?"
	echo "${NEW_STATE}" >"${STATE_FILE}"
	exit 0
fi

NEW_STATE="$(jq \
	--arg value "${VALUE}" \
	"${KEY}"' = $value' \
	"${STATE_FILE}")" || exit "$?"
echo "${NEW_STATE}" >"${STATE_FILE}"

