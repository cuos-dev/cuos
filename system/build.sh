#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

raise() {
	echo "Error: $*" >&2
	exit 1
}

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

IMAGE="${IMAGE:-ghcr.io/cuos-dev/cuos-system}"
# The repository root: the image takes LICENSE.txt and NOTICE from there.
BUILD_CONTEXT="${BUILD_CONTEXT:-"${SCRIPT_DIR}/.."}"

if [[ -z "${TYPE:-}" ]]; then
	DOCKERFILE="${SCRIPT_DIR}/Dockerfile"
else
	IMAGE="${IMAGE}-${TYPE}"
	DOCKERFILE="${SCRIPT_DIR}/Dockerfile.${TYPE}"
fi

if docker buildx version >/dev/null 2>&1; then
	echo "🔧 Buildx detected – building with BuildKit"
	docker buildx build \
		-t "${IMAGE}:build" \
		-f "${DOCKERFILE}" \
		"$@" \
		"${BUILD_CONTEXT}" \
		|| raise "Buildx build failed"
else
	echo "⚠️  Buildx not available – falling back to legacy docker build"
	docker build \
		-t "${IMAGE}:build" \
		-f "${DOCKERFILE}" \
		"$@" \
		"${BUILD_CONTEXT}" \
		|| raise "Legacy docker build failed"
fi
