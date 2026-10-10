#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# The updater image's default entrypoint, reached as /api/update as well. An
# old system calls the updater without --entrypoint, so this is what an update
# runs whichever path the image starts it by. /usr/local/updater/updater.sh is
# what image-factory/create_image.sh calls; keep it.
#
# Reached through a symlink, so the directory is the link target's.
SCRIPT_DIR="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"

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
