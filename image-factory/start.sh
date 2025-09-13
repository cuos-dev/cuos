#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CONFIG_PATH="${SCRIPT_DIR}/../output/system.json"


raise() {
	echo "Error: $*" >&2
	exit 1
}

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

export LOCAL_CONFIG_PATH="$1"
if [[ ! -f "${LOCAL_CONFIG_PATH}" ]]; then
	echo "Config file not found."
	exit 1
fi
mkdir -p "${SCRIPT_DIR}/../output/"
cp "${LOCAL_CONFIG_PATH}" "${CONFIG_PATH}"


if [[ ! -f "${CONFIG_PATH}" ]]; then
	echo "Config file not found: ${CONFIG_PATH}"
	exit 1
fi

OS_VERSION="${2:-"$(jq -r '.os_image_version // "latest"' "${CONFIG_PATH}")"}"

UPDATE_REGISTRY="$(jq -r '.update_registry' "${CONFIG_PATH}")"
OS_IMAGE="cuos-image-factory"
OS_IMAGE_DIGEST="$(jq -r '.os_image_digest // empty' "${CONFIG_PATH}")"


dockerlogin

if [[ "${VERSION}" == "build" ]]; then
	IMAGE_VERSION="cuos_imagebuilder"
	docker build -f "Dockerfile" -t "${IMAGE_VERSION}" .. \
		|| raise "Failed to build image"
else
	IMAGE_VERSION="${UPDATE_REGISTRY}${OS_IMAGE}:${OS_VERSION}"
	docker image pull "${IMAGE_VERSION}" \
		|| raise "Faild to fetch image"
fi

touch "${HOME}/.docker/config.json" 2>/dev/null
docker run --rm \
	--pull=never \
	--privileged \
	-v "${HOME}/.docker/config.json":/root/.docker/config.json:ro \
	-v "${SCRIPT_DIR}/../output/:/output/" \
	--name cuos-imagebuilder-container \
	"${IMAGE_VERSION}"
