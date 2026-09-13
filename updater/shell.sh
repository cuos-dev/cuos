#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# An interactive shell in the same environment an update runs in - the target
# mounted, a docker daemon reachable. For commands like 'docker diff'.
#
# system/cuos/do-update-shell.sh pins this path as the container's entrypoint,
# and that script ships in the system image, which is versioned apart from this
# one. The path stays.

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/docker.sh
source "${SCRIPT_DIR}/lib/docker.sh"
# shellcheck source=lib/target.sh
source "${SCRIPT_DIR}/lib/target.sh"
# shellcheck source=lib/environment.sh
source "${SCRIPT_DIR}/lib/environment.sh"

main() {
  with_environment /bin/bash
  exit "$?"
}

# Execute main only if script is run, not sourced
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
