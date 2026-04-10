#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
export CONFIG_PATH="${SCRIPT_DIR}/../output/system.json"


raise() {
	echo "Error: $*" >&2
	exit 1
}


OS_VERSION="${2:-"$(jq -r '.os_image_version // "latest"' "${CONFIG_PATH}")"}"

UPDATE_REGISTRY="$(jq -r '.update_registry_proxy // .update_registry' "${CONFIG_PATH}")"
UPDATE_REGISTRY="${UPDATE_REGISTRY%/}/"
OS_IMAGE_FACTORY="cuos-image-factory"


if [[ "${VERSION}" == "build" ]]; then
	IMAGE_VERSION="cuos_imagebuilder"
	docker build -f "Dockerfile" -t "${IMAGE_VERSION}" .. \
		|| raise "Failed to build image"
else
	IMAGE_VERSION="${UPDATE_REGISTRY}${OS_IMAGE_FACTORY}:${OS_VERSION}"
	docker image pull "${IMAGE_VERSION}" \
		|| raise "Faild to fetch image"
fi


docker run --rm -it \
	--pull=never \
	--privileged \
	-v "${SCRIPT_DIR}/.docker_config.json":/root/.docker/config.json:ro \
	-v "${SCRIPT_DIR}/../output/:/output/" \
	--name cuos-imagebuilder-container \
	--entrypoint "/mount_image.sh" \
	"${IMAGE_VERSION}"
