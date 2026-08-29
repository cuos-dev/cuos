#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

set -x

# shellcheck disable=SC2034  # unused here, but every install-kernel-* takes the
# slot as its first argument and the callers pass it uniformly.
SLOT="$1"
# from exports:
# TARGET_BOOT
# TARGET_DEVICE


# Swap the current boot files with the ones kept by install-kernel-uboot.sh,
# using the same "everything except prev and system.json" rule.
if [[ -d "${TARGET_BOOT}/prev" ]]; then
  mkdir -p "${TARGET_BOOT}/next"
  for file in "${TARGET_BOOT}"/*; do
    filename="$(basename "${file}")"
    if [[ "${filename}" != "prev" && "${filename}" != "next" && "${filename}" != "system.json" ]]; then
      mv "${file}" "${TARGET_BOOT}/next/"
    fi
  done
  mv "${TARGET_BOOT}"/prev/* "${TARGET_BOOT}/"
  rm -Rf "${TARGET_BOOT}/prev"
  mv "${TARGET_BOOT}/next" "${TARGET_BOOT}/prev"
fi

