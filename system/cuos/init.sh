#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

set -x

if [[ "${1:-}" = "--reinit" ]]; then
	export REINIT=1
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/functions.sh"

logger -t "cuos" "System startup"

prepare_data_volume

ensure_docker_config_json

ensure_system_config

set_hostname

configure_network

import_custom_ca_certs

create_ssh_hostkey

"${SCRIPT_DIR}/docker-configuration.sh"

create_swap_and_resize_fs

exit 0
