#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CONFIG_PATH="${SCRIPT_DIR}/../output/system.json"


raise() {
	echo "Error: $*" >&2
	exit 1
}

VERSION="${1:-"development"}"
BUILDER_IMAGE="/base-system-docker-boot/base-system-docker-boot-image"

dockerlogin() {
	## docker login:
	UPDATE_REGISTRY="$(jq -r '.update_registry' "${CONFIG_PATH}")"
	# just the server name:
	UPDATE_REGISTRY_SERVER="${UPDATE_REGISTRY//\/*}"

	UPDATE_REGISTRY_USER="$(jq -r '.update_registry_user // .update_server_user // ""' "${CONFIG_PATH}")"
	UPDATE_REGISTRY_PASSWORD="$(jq -r '.update_registry_password // .update_server_password // ""' "${CONFIG_PATH}")"


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
}

if [[ ! -f "${CONFIG_PATH}" ]]; then
	echo "Config file not found: ${CONFIG_PATH}"
	exit 1
fi

dockerlogin

if [[ "${VERSION}" == "build" ]]; then
	IMAGE="dockerboot_imagebuilder"
	docker build -f "Dockerfile" -t "${IMAGE}" .. \
		|| raise "Failed to build image"
else
	IMAGE="${UPDATE_REGISTRY}${BUILDER_IMAGE}:${VERSION}"
	docker image pull "${IMAGE}" \
		|| raise "Faild to fetch image"
fi

touch "${HOME}/.docker/config.json"
docker run --rm \
	--pull=never \
	--network=host \
	--privileged \
	-v "${HOME}/.docker/config.json":/root/.docker/config.json:ro \
	-v "${PWD}/../output/:/output/" \
	--name dockerboot-imagebuilder-container \
	"${IMAGE}"
