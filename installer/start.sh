#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

if [[ "${1:-}" != "" ]]; then
  "${SCRIPT_DIR}/../image-factory/start.sh" "$@" || exit "$?"
fi

docker build -t minimal-installer . || exit "$?"
docker run --rm \
	-v "${SCRIPT_DIR}/../output/:/output/" \
	minimal-installer || exit "$?"

echo "ISO created at ../output/installer.iso"

