#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# The partition layouts, and the filesystems that go into them. Every
# filesystem is built from a directory into a file of its own and then copied
# into its partition, so nothing here needs a loop device or a mount. Sourced,
# never run.

# Where the root partition starts in both layouts - the partition table gap and
# the boot partition are in front of it. lib/size.sh adds it to the root
# filesystem's size.
ROOT_PARTITION_START_MIB=256

# The arguments parted is given, so that the layout can be read - and asserted -
# without writing an image.
partition_plan() {
  local root="${ROOT_PARTITION_START_MIB}MiB"

  if [[ "${1}" == "mbr" ]]; then
    echo "mklabel msdos" \
      "mkpart primary fat32 1MiB ${root}" \
      "mkpart primary btrfs ${root} 100%" \
      "set 1 boot on"
    return
  fi

  echo "mklabel gpt" \
    "mkpart bios_boot 1MiB 3MiB" \
    "set 1 bios_grub on" \
    "mkpart ESP fat32 3MiB ${root}" \
    "set 2 boot on" \
    "mkpart primary btrfs ${root} 100%"
}

# $1 is the layout. Sets BOOT_PARTITION_NUM and ROOT_PARTITION_NUM, and
# BIOS_GRUB_PARTITION_NUM for gpt.
# shellcheck disable=SC2034
partition_numbers() {
  if [[ "${1}" == "mbr" ]]; then
    BOOT_PARTITION_NUM=1
    ROOT_PARTITION_NUM=2
    BIOS_GRUB_PARTITION_NUM=""
    return
  fi

  BIOS_GRUB_PARTITION_NUM=1
  BOOT_PARTITION_NUM=2
  ROOT_PARTITION_NUM=3
}

# $1 is the image, $2 the partition number. Prints its start and its size, in
# 512-byte sectors.
partition_geometry() {
  sfdisk -J "${1}" 2>/dev/null | jq -er --argjson n "${2}" \
    '.partitiontable.partitions[$n - 1] | "\(.start) \(.size)"'
}

# $1 is the image, $2 the partition number. Sets PART_START and PART_SECTORS
# rather than printing them, because it raises.
read_partition_geometry() {
  local geometry
  geometry="$(partition_geometry "${1}" "${2}")" \
    || raise "Could not read partition ${2} of ${1}"
  read -r PART_START PART_SECTORS <<<"${geometry}"
}

# $1 is the image, $2 the partition number, $3 the filesystem file. Whole MiB
# at a time: every partition of both layouts starts on a MiB boundary, and
# busybox's dd one sector at a time would take minutes for the root partition.
write_partition() {
  local image="$1" num="$2" file="$3"
  local size

  read_partition_geometry "${image}" "${num}"
  (( PART_START % 2048 == 0 )) \
    || raise "Partition ${num} of ${image} does not start on a MiB boundary"

  size="$(stat -c %s "${file}")"
  (( size <= PART_SECTORS * 512 )) \
    || raise "${file} is larger than partition ${num} of ${image}"

  dd if="${file}" of="${image}" bs=1M seek="$(( PART_START / 2048 ))" \
    conv=notrunc 2>&1 \
    || raise "Failed to write ${file} into partition ${num} of ${image}"
}

# A FAT volume id as mkfs.vfat takes it, and the UUID GRUB searches for.
new_fat_volume_id() {
  od -An -N4 -tx4 /dev/urandom | tr -d ' \n'
}

fat_uuid() {
  local id
  id="$(echo "${1}" | tr '[:lower:]' '[:upper:]')"
  echo "${id:0:4}-${id:4:4}"
}

# $1 is the file, $2 the size in sectors, $3 the partition's start sector, $4
# the volume id, $5 the directory to copy in.
#
# -h: the hidden sectors are what mkfs.vfat writes on its own when it formats a
# partition of a disk. On a file it cannot know them.
make_boot_filesystem() {
  local file="$1" sectors="$2" start="$3" volume_id="$4" dir="$5"
  local entry

  rm -f "${file}"
  mkfs.vfat -n boot -i "${volume_id}" -h "${start}" -C "${file}" \
    "$(( sectors / 2 ))" \
    || raise "Failed to create the boot filesystem"

  # mtools checks the geometry against that of a floppy and refuses an image
  # that does not look like one. Every entry, dotfiles too.
  for entry in "${dir}"/* "${dir}"/.[!.]*; do
    [[ -e "${entry}" ]] || continue
    MTOOLS_SKIP_CHECK=1 mcopy -s -p -m -Q -i "${file}" "${entry}" ::/ \
      || raise "Failed to copy ${entry} onto the boot filesystem"
  done
}

# $1 is the file, $2 its size in bytes, $3 the tree, $4 the slot.
#
# The subvolumes are the ones a device expects: @os with one slot in it, @data
# and @swap beside it. --rootdir takes ownership, modes, hard links and xattrs
# (file capabilities) from the tree, which has to be on a filesystem that keeps
# them - the factory's own does.
make_root_filesystem() {
  local file="$1" bytes="$2" tree="$3" slot="$4"

  rm -f "${file}"
  truncate -s "${bytes}" "${file}" || raise "Failed to create ${file}"
  mkfs.btrfs -L system \
    --rootdir "${tree}" \
    --subvol @os \
    --subvol "@os/system-${slot}" \
    --subvol @data \
    --subvol @swap \
    "${file}" \
    || raise "Failed to create the root filesystem. Is image_size_mb too small?"
}

# $1 is a btrfs filesystem in a file. Prints its free space in MiB, read from the
# superblock: the filesystem cannot be mounted here.
root_free_mb() {
  local total used

  read -r total used <<<"$(btrfs inspect-internal dump-super "${1}" 2>/dev/null \
    | awk '$1 == "total_bytes" { t = $2 } $1 == "bytes_used" { u = $2 }
           END { print t, u }')"
  [[ "${total}" =~ ^[0-9]+$ && "${used}" =~ ^[0-9]+$ ]] || return 1
  echo "$(( (total - used) / 1024 / 1024 ))"
}

# The factory installs one slot, and the first update puts a second one beside
# it on a boot partition that never grows: it is sized once, by partition_plan,
# and no update can repartition the disk it runs from. So the moment to find
# out that two slots do not fit is here, where the layout can still be changed -
# on a device it is a kernel that cannot be installed any more.
#
# 40 and not 50 percent: the second slot's kernel and initrd are a future
# build, and they will not be smaller than today's.
#
# $1 is the boot directory, complete with the boot loader, $2 the size of the
# partition in KiB.
check_boot_reserve() {
  local dir="$1" size_kb="$2"
  local used_kb percent

  used_kb="$(du -sk "${dir}" | awk '{ print $1 }')"
  [[ "${used_kb}" =~ ^[0-9]+$ && "${size_kb}" =~ ^[0-9]+$ && "${size_kb}" -gt 0 ]] \
    || raise 100 "Could not read the usage of ${dir}: \"${used_kb}\" of \"${size_kb}\" KiB"
  percent="$(( used_kb * 100 / size_kb ))"

  echo "boot: ${used_kb} KiB of ${size_kb} KiB used (${percent}%)"
  if (( percent > 40 )); then
    raise 115 "The boot partition is ${percent}% full with one slot installed, so
       the second slot will not fit. Give it more room in partition_plan,
       image-factory/lib/layout.sh."
  fi
}
