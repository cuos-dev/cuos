#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# /api/pull: fetch the system image of an update without installing it
# ("cuos pull"). do-update.sh starts it with --entrypoint /api/pull; an updater
# older than this file has no such path and docker exits 127, which is how the
# host tells the two apart. Nothing in here may exit 127 itself.
#
# Reached through a symlink, so the directory is the link target's.
SCRIPT_DIR="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"

# shellcheck source=lib/update.sh
source "${SCRIPT_DIR}/lib/update.sh"
# shellcheck source=lib/environment.sh
source "${SCRIPT_DIR}/lib/environment.sh"

main() {
  set -x

  with_environment perform_pull "$@"
  exit "$?"
}

# Execute main only if script is run, not sourced
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
