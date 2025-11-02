#!/bin/bash

SCRIPT_DIR="$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd)"

set -euo pipefail

echo "[Test] API help"

"${SCRIPT_DIR}/api.sh" help >/dev/null || exit 1

