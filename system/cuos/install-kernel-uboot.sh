#!/bin/bash

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

#mv "${TARGET_BOOT}/dtb-6.18.33-current-sunxi64" "${TARGET_BOOT}/dtb"
#mv "${TARGET_BOOT}/vmlinuz-6.18.33-current-sunxi64" "${TARGET_BOOT}/Image"
#rm "${TARGET_BOOT}/initrd.img-6.18.33-current-sunxi64"


echo "disc free (boot): $(df -h "${TARGET_BOOT}" | tail -n 1)"


if [[ "${INSTALLIMAGE}" = "true" ]]; then
  if [[ -f "${CONFIG_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${TARGET_BOOT}/system.json" \
      || raise 120 "Failed to copy system.json from dir"
  else
    cp "${ROOT}/usr/local/cuos/system-default.json" "${TARGET_BOOT}/system.json" \
      || raise 121 "Failed to copy system.json from container"
  fi

  UBOOT_FILE="${ROOT}/boot/u-boot.bin"
  dd if="$UBOOT_FILE" of="${TARGET_DEVICE}" bs=1024 seek=8 conv=fsync

fi


for file in "${TARGET_BOOT}"/*; do
  if [[ -f "${file}" ]]; then
    sed -i "s/{{SLOT}}/${SLOT}/g" "$file"
  fi
done


ls -lR "${TARGET_BOOT}"
