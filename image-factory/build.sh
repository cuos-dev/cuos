#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

raise() {
	echo "Error: $*" >&2
	exit 1
}

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

IMAGE_FACTORY_VERSION="${IMAGE_FACTORY_VERSION:-"cuos-image-factory-build"}"
docker buildx version >/dev/null 2>&1 \
	|| raise "docker buildx is required (Debian: docker-buildx)"
docker buildx build \
	-f "${SCRIPT_DIR}/Dockerfile" \
	-t "${IMAGE_FACTORY_VERSION}" \
	--build-context repo="${SCRIPT_DIR}/.." \
	--build-context updater="${SCRIPT_DIR}/../updater" \
	"${SCRIPT_DIR}" \
	|| raise "Failed to build image"
