#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

raise() {
	echo "Error: $*" >&2
	exit 1
}

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

IMAGE_FACTORY_VERSION="${IMAGE_FACTORY_VERSION:-"cuos-image-factory-build"}"
BUILD_CONTEXT="${SCRIPT_DIR}/.."
if docker buildx version >/dev/null 2>&1; then
	docker buildx build \
		-f "${SCRIPT_DIR}/Dockerfile" \
		-t "${IMAGE_FACTORY_VERSION}" \
		"${BUILD_CONTEXT}" \
		|| raise "Failed to build image with buildx"
else
	docker build \
		-f "${SCRIPT_DIR}/Dockerfile" \
		-t "${IMAGE_FACTORY_VERSION}" \
		"${BUILD_CONTEXT}" \
		|| raise "Failed to build image with legacy docker"
fi
