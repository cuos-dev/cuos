#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/docker.sh
source "${SCRIPT_DIR}/lib/docker.sh"
# shellcheck source=lib/target.sh
source "${SCRIPT_DIR}/lib/target.sh"
# shellcheck source=lib/environment.sh
source "${SCRIPT_DIR}/lib/environment.sh"
# shellcheck source=lib/update.sh
source "${SCRIPT_DIR}/lib/update.sh"

main() {
  set -x

  with_environment perform_update "$@"
  exit "$?"
}

# Execute main only if script is run, not sourced
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
