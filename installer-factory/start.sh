#!/bin/bash
set -euo pipefail

raise() {
	echo "Error: $*" >&2
	exit "${2:-1}"
}

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

if [[ "${1:-}" != "" ]]; then
	"${SCRIPT_DIR}/../image-factory/start.sh" "$@" || exit "$?"
fi

IMAGE_NAME="minimal-installer"
BUILD_CTX="${SCRIPT_DIR}"

if docker buildx version >/dev/null 2>&1; then
	echo "🔧 Buildx detected – building with BuildKit"
	docker buildx build \
		-f "${SCRIPT_DIR}/Dockerfile" \
		-t "${IMAGE_NAME}" \
		"${BUILD_CTX}" \
		|| raise "Buildx build failed"
else
	echo "⚠️  Buildx not available – using legacy docker build"
	docker build \
		-f "${SCRIPT_DIR}/Dockerfile" \
		-t "${IMAGE_NAME}" \
		"${BUILD_CTX}" \
		|| raise "Legacy docker build failed"
fi

docker run --rm \
	-v "${SCRIPT_DIR}/../output/:/output/" \
	minimal-installer || exit "$?"

echo "ISO created at ../output/installer.iso"
