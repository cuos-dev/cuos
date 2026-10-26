#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

raise() {
	echo "Error: $*" >&2
	exit 1
}

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

IMAGE="${IMAGE:-ghcr.io/cuos-dev/cuos-system}"
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"

if [[ -z "${TYPE:-}" ]]; then
	DOCKERFILE="Dockerfile"
else
	IMAGE="${IMAGE}-${TYPE}"
	DOCKERFILE="Dockerfile.${TYPE}"
fi

docker buildx version >/dev/null 2>&1 \
	|| raise "docker buildx is required (Debian: docker-buildx)"
docker buildx build \
	-t "${IMAGE}:build" \
	-f "${DOCKERFILE}" \
	--build-context repo="${SCRIPT_DIR}/.." \
	"$@" \
	"${BUILD_CONTEXT}" \
	|| raise "Build failed"
