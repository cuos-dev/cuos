#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../system/cuos/lib-test.sh"
# shellcheck source=../../updater/lib/log.sh
source "${SCRIPT_DIR}/../../updater/lib/log.sh"
# shellcheck source=layout.sh
source "${SCRIPT_DIR}/layout.sh"
# shellcheck source=bootloader.sh
source "${SCRIPT_DIR}/bootloader.sh"

rc_of() {
  ( "$@" ) >/dev/null 2>&1
}

du() {
  printf '%s\t%s\n' "${MOCK_USED_KB-70041}" "${*: -1}"
}

# The x86_64 build of 2026-09-10: 68.4 MiB of 252.7 MiB, one slot.
expect_rc "check_boot_reserve: one slot at 27%" 0 \
  rc_of check_boot_reserve "${WORK_DIR}" 258812
MOCK_USED_KB=40000
expect_rc "check_boot_reserve: 40% is still fine" 0 \
  rc_of check_boot_reserve "${WORK_DIR}" 100000
MOCK_USED_KB=41000
expect_rc "check_boot_reserve: 41% leaves the second slot too little" 115 \
  rc_of check_boot_reserve "${WORK_DIR}" 100000
MOCK_USED_KB="du: cannot access"
expect_rc "check_boot_reserve: a du that says nothing is not guessed at" 100 \
  rc_of check_boot_reserve "${WORK_DIR}" 100000
unset MOCK_USED_KB
unset -f du

partition_numbers gpt
expect "partition_numbers: gpt" "1 2 3" \
  echo "${BIOS_GRUB_PARTITION_NUM} ${BOOT_PARTITION_NUM} ${ROOT_PARTITION_NUM}"
partition_numbers mbr
expect "partition_numbers: mbr has no bios_grub" " 1 2" \
  echo "${BIOS_GRUB_PARTITION_NUM} ${BOOT_PARTITION_NUM} ${ROOT_PARTITION_NUM}"

expect "fat_uuid: as GRUB prints a FAT serial" "1A2B-3C4D" fat_uuid "1a2b3c4d"
expect "new_fat_volume_id: 32 bits in hex" "yes" \
  eval '[[ "$(new_fat_volume_id)" =~ ^[0-9a-f]{8}$ ]] && echo yes'

expect "layout_of: grub" "gpt" layout_of grub
expect "layout_of: rpi" "mbr" layout_of rpi
expect "layout_of: uboot" "mbr" layout_of uboot
expect_rc "layout_of: lxc has no disk" 1 layout_of lxc

bytes_at() {
  od -An -tx1 -j "${2}" -N "${3}" "${1}" | tr -d ' \n'
}
head -c 32 /dev/zero >"${WORK_DIR}/le"
put_le "${WORK_DIR}/le" 8 2049 4
expect "put_le: 8 bytes, little-endian, at the offset" \
  "00000000010800000000000000000000" bytes_at "${WORK_DIR}/le" 0 16
put_le "${WORK_DIR}/le" 2 $(( 0xabcd )) 20
expect "put_le: 2 bytes, nothing around them touched" "00cdab00" \
  bytes_at "${WORK_DIR}/le" 19 4
expect "put_le: the file keeps its size" "32" stat -c %s "${WORK_DIR}/le"

uboot_fits() {
  head -c "${1}" /dev/zero >"${WORK_DIR}/u-boot.bin"
  : >"${WORK_DIR}/image"
  install_uboot "${WORK_DIR}/image" "${WORK_DIR}/u-boot.bin" 2048
}
expect_rc "install_uboot: up to the first partition" 0 \
  rc_of uboot_fits $(( 1024 * 1024 - 8192 ))
expect_rc "install_uboot: one byte into it" 1 \
  rc_of uboot_fits $(( 1024 * 1024 - 8191 ))

summary
