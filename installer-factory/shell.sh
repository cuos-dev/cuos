#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

docker build -t minimal-installer . || exit "$?"
docker run --rm \
	-it \
	-v "$(pwd)/output:/output" \
	--entrypoint /bin/bash \
	minimal-installer
