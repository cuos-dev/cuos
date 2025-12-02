#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

set -euo pipefail

SLOT="$1"
IMAGE="$2"
DIGEST="$3"

echo "${SLOT}" >/etc/active_slot
chmod 444 /etc/active_slot

echo "${IMAGE}@${DIGEST}" >/etc/image
chmod 444 /etc/image

ln -sf "/data/system_${SLOT}.json" "/system.json"
NEXT_SLOT=$([[ "${SLOT}" == "A" ]] && echo "B" || echo "A")
ln -sf "/data/system_${NEXT_SLOT}.json" "/system_next.json"

if [[ -f "${SCRIPT_DIR}/custom-first-run.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/custom-first-run.sh"
fi

/usr/sbin/fake-hwclock save force

exit 0
