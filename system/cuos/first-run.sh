#!/bin/bash

set -euo pipefail

PARTITION="$1"
IMAGE="$2"
DIGEST="$3"

echo "${PARTITION}" >/etc/partition_mode
chmod 444 /etc/partition_mode

echo "${IMAGE}@${DIGEST}" >/etc/image
chmod 444 /etc/image

ln -sf "/data/system_${PARTITION}.json" "/system.json"
NEXT_PARTITION=$([[ "${PARTITION}" == "A" ]] && echo "B" || echo "A")
ln -sf "/data/system_${NEXT_PARTITION}.json" "/system_next.json"

exit 0
