#!/bin/bash

set -x
set -o pipefail

PARTITION="A"

raise() {
	echo "Error: $*" >&2
	exit 1
}

export CONFIG_PATH="$1"
if [[ ! -f "${CONFIG_PATH}" ]]; then
	echo "Config file not found."
	exit 1
fi

UPDATE_REGISTRY="$(jq -r '.update_registry' "${CONFIG_PATH}")"
OS_IMAGE="$(jq -r '.os_image_lxc' "${CONFIG_PATH}")"
OS_VERSION="$(jq -r '.os_image_lxc_version // "latest"' "${CONFIG_PATH}")"
OS_DIGEST="$(jq -r '.os_image_lxc_digest // empty' "${CONFIG_PATH}")"

IMAGE_VERSION="${UPDATE_REGISTRY}${OS_IMAGE}:${OS_VERSION}"

docker image pull "${IMAGE_VERSION}" || raise "Faild to fetch image"
NEW_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE_VERSION}" 2>/dev/null | cut -d '@' -f 2)
if [[ -n "${OS_IMAGE_DIGEST}" && "${OS_IMAGE_DIGEST}" != "${NEW_DIGEST}" ]]; then
	echo "Image digest mismatch: ${OS_IMAGE_DIGEST} != ${NEW_DIGEST}"
	exit 1
fi

CONTAINER_NAME="cuos-lxc-$$"
docker run -it -d \
	--pull=never \
	--restart=always \
	--name "${CONTAINER_NAME}" \
	"${IMAGE}" || raise "Failed to run container"
docker exec "${CONTAINER_NAME}" /usr/local/cuos/first-run.sh "${PARTITION}" "${IMAGE_VERSION}" "${OS_DIGEST}" \
	|| raise "Failed to run first-run script in container"

if ! docker export "${CONTAINER_NAME}" | gzip >image.tar.gz; then
	raise "Failed to export the container"
fi
docker rm -f "${CONTAINER_NAME}" \
	|| raise "Failed to remove the container"

