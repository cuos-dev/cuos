#!/bin/bash

HOME="${HOME:-/root}"

# Check and read configuration:
CONFIG_PATH="${CONFIG_PATH:-"/system.json"}"

## docker login:
UPDATE_REGISTRY="$(jq -r '.update_registry' "${CONFIG_PATH}")"
# just the server name:
UPDATE_REGISTRY_SERVER="${UPDATE_REGISTRY//\/*}"

UPDATE_REGISTRY_USER="$(jq -r '.update_registry_user // .update_server_user // ""' "${CONFIG_PATH}")"
UPDATE_REGISTRY_PASSWORD="$(jq -r '.update_registry_password // .update_server_password // ""' "${CONFIG_PATH}")"

rmdir /root/.docker/config.json 2>/dev/null && echo "Warning: deleted config.json as dir"

# Do docker login only if not already in .docker/config.json file
if ! grep -q "${UPDATE_REGISTRY_SERVER}" "${HOME}/.docker/config.json" 2>/dev/null
then
	echo "${UPDATE_REGISTRY_PASSWORD}" | docker login \
		"${UPDATE_REGISTRY_SERVER}" \
		--username "${UPDATE_REGISTRY_USER}" --password-stdin
	if test "$?" != "0"
	then
		echo "Error: Docker login failed" >&2
		exit 1
	fi
else
	echo "Credentials for ${UPDATE_REGISTRY_SERVER} already existing. Skipped login."
fi

exit 0
