#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

set -x

SLOT="$1"
# from exports:
# TARGET_BOOT
# TARGET_DEVICE

rm -Rf "${TARGET_BOOT}/prev" || true
mkdir -p "${TARGET_BOOT}/prev" || true
for file in "${TARGET_BOOT}"/*; do
  filename="$(basename "${file}")"
  if [[ "$filename" != "prev" && "$filename" != "system.json" ]]; then
    mv "$file" "${TARGET_BOOT}/prev/"
  fi
done
cp -r "${ROOT}/boot/." "${TARGET_BOOT}" \
  || raise 112 "Failed to copy kernel"


# U-Boot itself is written by image-factory, into the image file. An older
# factory hands in a block device and expects this script to do it.
if [[ "${INSTALLIMAGE:-}" = "true" && -b "${TARGET_DEVICE:-}" ]]; then
  raise 123 "This system image does not install U-Boot itself. Build it with an
       image factory that reads the dev.cuos.boot label."
fi

# Resolve the slot placeholder in the u-boot environment. Only the text
# config is templated: sed -i on Image/uInitrd/u-boot.bin would append a
# trailing newline and corrupt them.
if [[ -f "${TARGET_BOOT}/armbianEnv.txt" ]]; then
  sed -i "s/{{SLOT}}/${SLOT}/g" "${TARGET_BOOT}/armbianEnv.txt" \
    || raise 126 "Failed to set the boot slot in armbianEnv.txt"
fi
