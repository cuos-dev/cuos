#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# In the image the entrypoints sit at / and their libraries do not - / already
# has a lib. In the tree both are beside each other.
CUOS_UPDATER_DIR="${CUOS_UPDATER_DIR:-"/usr/local/updater"}"
[[ -d "${CUOS_UPDATER_DIR}/lib" ]] || CUOS_UPDATER_DIR="${SCRIPT_DIR}/../updater"
CUOS_FACTORY_DIR="${CUOS_FACTORY_DIR:-"/usr/local/image-factory"}"
[[ -d "${CUOS_FACTORY_DIR}/lib" ]] || CUOS_FACTORY_DIR="${SCRIPT_DIR}"

# shellcheck source=../updater/lib/log.sh
source "${CUOS_UPDATER_DIR}/lib/log.sh"
# shellcheck source=../updater/lib/target.sh
source "${CUOS_UPDATER_DIR}/lib/target.sh"
# shellcheck source=lib/loopdev.sh
source "${CUOS_FACTORY_DIR}/lib/loopdev.sh"

OUTPUT_DIR="/output"
IMAGE_NAME="${IMAGE_NAME:-"image"}"
IMAGE_FILE="${OUTPUT_DIR}/${IMAGE_NAME}.img"

export TARGET_BOOT="${TARGET_BOOT:-"/mnt/boot"}"
export TARGET_ROOT="${TARGET_ROOT:-"/mnt/os"}"

LOOPDEV=""

# shellcheck disable=SC2329 disable=SC2317
cleanup() {
  target_umount
  loopdev_detach "${LOOPDEV}"
}

main() {
  trap cleanup EXIT

  [[ -d "${OUTPUT_DIR}" ]] || raise "Output dir not mounted"

  loopdev_attach "${IMAGE_FILE}"
  loopdev_map_partitions "${LOOPDEV}"
  loopdev_find_partitions "${LOOPDEV}"
  export TARGET_BOOT_PARTITION TARGET_ROOT_PARTITION

  echo "Boot partition: ${TARGET_BOOT_PARTITION} (vfat)"
  echo "Root partition: ${TARGET_ROOT_PARTITION} (btrfs)"

  target_mount

  /bin/bash
}

# Execute main only if script is run, not sourced
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
