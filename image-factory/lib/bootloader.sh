#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# The boot chain a system image asks for, and writing it into the image file.
# Sourced, never run.

GRUB_LIB_DIR="${GRUB_LIB_DIR:-"/usr/lib/grub"}"

# What GRUB's first stage needs to find the boot partition and read grub.cfg
# from it. Everything else it loads from /grub on that partition.
GRUB_CORE_MODULES=(part_gpt part_msdos fat search normal configfile)

# $1 is the system image, $2 the platform. Prints the boot chain its
# dev.cuos.boot label names, and fails for an image without one: such an image
# installs its boot loader itself, onto a block device this factory does not
# have.
#
# --platform first: a daemon that keeps several platforms of one image (the
# containerd store) needs to be told which one is meant. One older than API 1.49
# does not know the flag and has only one platform to answer with.
boot_type_of() {
  local image="$1" platform="${2:-}"
  local format='{{ index .Config.Labels "dev.cuos.boot" }}'
  local type=""

  if [[ -n "${platform}" ]]; then
    type="$(docker image inspect --platform "${platform}" --format "${format}" \
      "${image}" 2>/dev/null)" || type=""
  fi
  if [[ -z "${type}" ]]; then
    type="$(docker image inspect --format "${format}" "${image}" 2>/dev/null)" \
      || return 1
  fi

  case "${type}" in
    grub|rpi|uboot|lxc) echo "${type}" ;;
    *) return 1 ;;
  esac
}

# $1 is the boot chain. Prints the partition layout it boots from.
layout_of() {
  case "${1}" in
    grub) echo "gpt" ;;
    rpi|uboot) echo "mbr" ;;
    *) return 1 ;;
  esac
}

# The configuration GRUB's first stage carries, $1 being the FAT UUID of the
# boot partition. By UUID, as grub-install does it: a stick with a filesystem
# labelled "boot" must not be where the boot loader looks for its modules.
grub_early_config() {
  cat <<EOF
search --no-floppy --fs-uuid --set=root ${1}
set prefix=(\$root)/grub
EOF
}

# $1 is the boot directory, $2 the GRUB target. The modules the first stage
# loads at boot, where it looks for them.
copy_grub_modules() {
  local boot_dir="$1" target="$2"

  mkdir -p "${boot_dir}/grub/${target}" || return 1
  cp "${GRUB_LIB_DIR}/${target}"/*.mod "${GRUB_LIB_DIR}/${target}"/*.lst \
    "${boot_dir}/grub/${target}/"
}

# $1 is the boot directory, $2 the FAT UUID of the boot partition, $3 a work
# directory. Everything that lives on the boot partition: the modules for both
# targets, and the UEFI image on the removable-media path, which firmware finds
# without an NVRAM entry. core.img, which goes outside the partitions, is left
# in the work directory for install_grub_bios.
grub_boot_files() {
  local boot_dir="$1" uuid="$2" work_dir="$3"
  local config="${work_dir}/grub-early.cfg"

  grub_early_config "${uuid}" >"${config}"

  copy_grub_modules "${boot_dir}" x86_64-efi \
    || raise "Failed to copy the GRUB modules (UEFI)"
  mkdir -p "${boot_dir}/EFI/BOOT"
  grub-mkimage -O x86_64-efi -d "${GRUB_LIB_DIR}/x86_64-efi" \
    -o "${boot_dir}/EFI/BOOT/BOOTX64.EFI" -c "${config}" -p /grub \
    "${GRUB_CORE_MODULES[@]}" \
    || raise "Failed to build the GRUB image (UEFI)"

  copy_grub_modules "${boot_dir}" i386-pc \
    || raise "Failed to copy the GRUB modules (BIOS)"
  grub-mkimage -O i386-pc -d "${GRUB_LIB_DIR}/i386-pc" \
    -o "${work_dir}/core.img" -c "${config}" -p /grub \
    biosdisk "${GRUB_CORE_MODULES[@]}" \
    || raise "Failed to build the GRUB image (BIOS)"
}

# Writes $3, little-endian and $2 bytes wide, at byte $4 of the file $1.
put_le() {
  local file="$1" width="$2" value="$3" offset="$4"
  local bytes="" i

  for (( i = 0; i < width; i++ )); do
    bytes+="$(printf '\\%03o' "$(( (value >> (8 * i)) & 0xff ))")"
  done
  # shellcheck disable=SC2059
  printf "${bytes}" | dd of="${file}" bs=1 seek="${offset}" conv=notrunc 2>/dev/null
}

# What grub-bios-setup does, which cannot run here: it insists on the block
# device that holds its own directory, and an unprivileged container has none.
#
# boot.img goes into the first 440 bytes of the MBR - the disk signature and
# the partition table after it stay - and core.img into the bios_grub
# partition. boot.img is told the sector where core.img starts, and the first
# sector of core.img the one where the rest of it follows. grub-mkimage has
# filled in the length and the load segment already. No Reed-Solomon codes:
# their redundancy stays 0, as grub-bios-setup --no-rs-codes writes it.
#
# The two nops replace the jump that skips the boot drive check, as
# grub-bios-setup does for any disk that is not a floppy: some BIOSes pass a
# wrong drive number.
#
# $1 is the image, $2 the first sector of the bios_grub partition, $3 its size
# in sectors, $4 the work directory grub_boot_files left core.img in.
install_grub_bios() {
  local image="$1" start="$2" sectors="$3" work_dir="$4"
  local core="${work_dir}/core.img" boot="${work_dir}/boot.img"
  local core_sectors

  core_sectors="$(( ($(stat -c %s "${core}") + 511) / 512 ))"
  (( core_sectors <= sectors )) \
    || raise "core.img (${core_sectors} sectors) does not fit the bios_grub partition (${sectors})"

  cp "${GRUB_LIB_DIR}/i386-pc/boot.img" "${boot}"
  put_le "${boot}" 8 "${start}" $(( 0x5c ))
  printf '\220\220' | dd of="${boot}" bs=1 seek=$(( 0x66 )) conv=notrunc 2>/dev/null
  put_le "${core}" 8 "$(( start + 1 ))" $(( 0x1f4 ))
  put_le "${core}" 4 0 $(( 512 + 0x10 ))

  dd if="${boot}" of="${image}" bs=440 count=1 conv=notrunc 2>/dev/null \
    || raise "Failed to write boot.img"
  dd if="${core}" of="${image}" bs=512 seek="${start}" conv=notrunc 2>/dev/null \
    || raise "Failed to write core.img"
}

# U-Boot for the Allwinner boards: 8 KiB into the disk, in front of the first
# partition. $1 is the image, $2 u-boot.bin, $3 the first partition's start
# sector.
install_uboot() {
  local image="$1" uboot="$2" first_sector="$3"
  local size

  [[ -f "${uboot}" ]] || raise "No ${uboot} in the system image"
  size="$(stat -c %s "${uboot}")"
  (( 8192 + size <= first_sector * 512 )) \
    || raise "u-boot.bin (${size} bytes) runs into the first partition"

  dd if="${uboot}" of="${image}" bs=1024 seek=8 conv=notrunc 2>/dev/null \
    || raise "Failed to write u-boot.bin"
}
