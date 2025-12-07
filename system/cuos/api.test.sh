#!/bin/bash

SCRIPT_DIR="$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd)"

set -euo pipefail

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-test.sh"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/api.sh"

"${SCRIPT_DIR}/api.sh" help >/dev/null || exit 1



T_FILE_STATE="${T_FILE_STATE:-"${SCRIPT_DIR}/api.test.state.json"}"
T_FILE_SLOT="${T_FILE_SLOT:-"${SCRIPT_DIR}/api.test.active_slot"}"
T_FILE_VERSION="${T_FILE_VERSION:-"${SCRIPT_DIR}/api.test.image"}"
expect \
  "api: state" \
  $'{\n  "start_date": "2025-12-07T12:33:51Z",\n  "last_update_check": "2025-12-01T22:59:28Z",\n  "state": "running",\n  "last_update_date": "2025-12-01T23:00:03Z",\n  "update_state": "updated partition B to ghcr.io/cuos-dev/cuos-system-lxc:v0.4.0",\n  "slot": "B",\n  "version": "cuos-system-lxc:v0.4.0"\n}' \
  api_main state

summary
