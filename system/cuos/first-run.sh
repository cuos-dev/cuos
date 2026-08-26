#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

set -euo pipefail

SLOT="$1"
IMAGE="$2"
DIGEST="$3"
ROOT="${ROOT:-""}"

echo "${SLOT}" >"${ROOT}/etc/active_slot"
chmod 444 "${ROOT}/etc/active_slot"

echo "${IMAGE}@${DIGEST}" >"${ROOT}/etc/image"
chmod 444 "${ROOT}/etc/image"

ln -sf "/data/system_${SLOT}.json" "${ROOT}/system.json"
NEXT_SLOT=$([[ "${SLOT}" == "A" ]] && echo "B" || echo "A")
ln -sf "/data/system_${NEXT_SLOT}.json" "${ROOT}/system_next.json"

if [[ -f "${SCRIPT_DIR}/custom-first-run.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/custom-first-run.sh"
fi

exit 0
