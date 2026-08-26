#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

/usr/local/updater/docker_environment.sh /usr/local/updater/perform_update.sh "$@"
exit "$?"
