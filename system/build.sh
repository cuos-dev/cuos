#!/bin/bash
set -euo pipefail

raise() {
	echo "Error: $*" >&2
	exit 1
}

IMAGE="${IMAGE:-cuos-system}"
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"

if docker buildx version >/dev/null 2>&1; then
	echo "🔧 Buildx detected – building with BuildKit"
	docker buildx build \
		-t "${IMAGE}" \
		"${BUILD_CONTEXT}" \
		|| raise "Buildx build failed"
else
	echo "⚠️  Buildx not available – falling back to legacy docker build"
	docker build \
		-t "${IMAGE}" \
		"${BUILD_CONTEXT}" \
		|| raise "Legacy docker build failed"
fi
