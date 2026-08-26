#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
export CONFIG_PATH="${SCRIPT_DIR}/../output/system.json"


raise() {
	echo "Error: $*" >&2
	exit 1
}

dockerlogin() {
	DOCKER_CONFIG_FILE="${SCRIPT_DIR}/.docker_config.json" \
		"${SCRIPT_DIR}/../system/cuos/utils-docker-login.sh"
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

if command -v arch >/dev/null 2>&1; then
	default_arch=$(arch)
else
	default_arch=$(uname -m)
fi

OS_ARCH="${2:-$default_arch}"

OS_VERSION="${2:-"$(jq -r '.os_image_version // "latest"' "${CONFIG_PATH}")"}"

UPDATE_REGISTRY="$(jq -r '.update_registry_proxy // .update_registry' "${CONFIG_PATH}")"
UPDATE_REGISTRY="${UPDATE_REGISTRY%/}/"
OS_IMAGE_FACTORY="cuos-image-factory"


dockerlogin

if [[ "${VERSION}" == "build" ]]; then
	IMAGE_VERSION="cuos_imagebuilder"
	BUILD_CONTEXT="${SCRIPT_DIR}/.."
	if docker buildx version >/dev/null 2>&1; then
		echo "🔧 Using docker buildx …"
		docker buildx build \
			-f "${SCRIPT_DIR}/Dockerfile" \
			-t "${IMAGE_VERSION}" \
			"${BUILD_CONTEXT}" \
			|| raise "Failed to build image with buildx"
	else
		echo "⚠️  buildx not available – falling back to legacy docker build"
		docker build \
			-f "${SCRIPT_DIR}/Dockerfile" \
			-t "${IMAGE_VERSION}" \
			"${BUILD_CONTEXT}" \
			|| raise "Failed to build image with legacy docker"
	fi
else
	IMAGE_VERSION="${UPDATE_REGISTRY}${OS_IMAGE_FACTORY}:${OS_VERSION}"
	docker image pull "${IMAGE_VERSION}" \
		|| raise "Faild to fetch image"
fi

touch "${HOME}/.docker/config.json" 2>/dev/null
#cp "${HOME}/.docker/config.json" "${SCRIPT_DIR}/.docker_config.json"

docker run --rm \
	--pull=never \
	--privileged \
	-v "${SCRIPT_DIR}/.docker_config.json":/root/.docker/config.json:ro \
	-v "${SCRIPT_DIR}/../output/:/output/" \
        -e "TARGET=rpi" \
        -e "OS_ARCH=${OS_ARCH:-}" \
	--name cuos-imagebuilder-container \
	"${IMAGE_VERSION}"
