#!/bin/bash

docker build -t minimal-installer .
docker run --rm \
	-v "$(pwd)/output:/output" \
	minimal-installer

echo "ISO created at ./output/installer.iso"

