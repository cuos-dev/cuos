#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Attaching an image file to a loop device and mapping its partitions.
# Sourced, never run.

# This container's /dev is a snapshot of the host's, taken when the container
# started - 'docker run --privileged' enumerates the host's devices once and
# creates them in here. A device the kernel makes afterwards therefore exists on
# the host and not in this container, and asking for a free loop device is
# exactly that: /dev/loop-control hands out a number, and the node for it never
# appears. losetup then fails with ENOENT and calls the node "lost".
#
# It bites on the first build of a machine, where no loop device existed when
# the container started, and stops biting on the second, where one did.
# Creating the node ourselves is enough wherever we are allowed to.
attach_loop_device() {
  local image="$1"
  local dev

  dev="$(losetup --find --show "${image}" 2>/dev/null)" || dev=""
  if [[ -n "${dev}" ]]; then
    printf '%s' "${dev}"
    return 0
  fi

  local free num
  free="$(losetup --find 2>/dev/null)" || free=""
  num="${free##*/loop}"
  if [[ -n "${num}" && "${num}" =~ ^[0-9]+$ && ! -e "${free}" ]]; then
    echo "Creating the missing device node ${free} ..." >&2
    mknod "${free}" b 7 "${num}" 2>/dev/null || true
    chmod 0660 "${free}" 2>/dev/null || true
  fi

  losetup --find --show "${image}" 2>/dev/null
}

# Sets LOOPDEV. Not an echo into a command substitution: this function raises,
# and a raise inside "$( )" ends the subshell only - the caller would carry on
# with an empty device and mkfs whatever /dev/mapper/p2 happens to be.
#
# Three attempts, and an explanation for every way this can fail - the messages
# are the whole point: each names what to do on the build host.
loopdev_attach() {
  local image="$1"
  local dev=""
  local attempt=0

  while (( attempt < 3 )); do
    dev="$(attach_loop_device "${image}")" && [[ -n "${dev}" ]] && break
    attempt="$(( attempt + 1 ))"
    sleep 2
  done

  if [[ -z "${dev}" ]]; then
    if [[ ! -e /dev/loop-control ]]; then
      raise "There is no /dev/loop-control, so no loop device can be asked for.

       The loop module is not loaded on the build host, or it was not loaded
       when this container started. On the host:

         sudo modprobe loop

       then build again. Loading it inside the container does not help: this
       container's /dev was taken from the host at start and does not follow it."
    fi

    raise "Could not attach ${image} to a loop device.

       The kernel did hand out a loop device - 'device node /dev/loopN is lost'
       above says so - but this container has no node for it, and creating one
       was not permitted either.

       On a normal host or VM this only happens on the very first build, before
       any loop device exists. Load the module on the host and build again:

         sudo modprobe loop dm_mod

       Inside an LXC container it happens every time, because loop devices,
       device-mapper and mounting all belong to the host kernel. Build on a host
       or in a VM instead; if it has to be that container, it must be privileged
       and unconfined, with at least:

         lxc.apparmor.profile: unconfined
         lxc.cgroup2.devices.allow: b 7:* rwm
         lxc.cgroup2.devices.allow: c 10:237 rwm
         lxc.mount.entry: /dev/loop-control dev/loop-control none bind,create=file
         lxc.mount.entry: /dev/loop0 dev/loop0 none bind,create=file

       plus one bind entry per loop device wanted.

       Building for '--platform lxc' needs none of this: it exports a container
       rather than partitioning a disk."
  fi

  # Device-mapper is the next thing needed, and it is the same story: kpartx
  # maps the image's partitions through it, and /dev/mapper/control has to be
  # here.
  if [[ ! -e /dev/mapper/control ]]; then
    raise "There is no /dev/mapper/control, so the partitions of ${image} cannot
       be mapped.

       Same cause as a missing loop device: this container's /dev was taken from
       the host when it started. On the host:

         sudo modprobe dm_mod

       then build again."
  fi

  # shellcheck disable=SC2034
  LOOPDEV="${dev}"
}

loopdev_map_partitions() {
  partprobe "$1"
  kpartx -av "$1"
  sleep 1
}

loopdev_detach() {
  [[ -n "${1:-}" ]] || return 0

  kpartx -dv "$1" 2>/dev/null || true
  losetup -d "$1" 2>/dev/null || true
}

# Which mapped partition is which, by filesystem: the numbers differ per layout
# (MBR + FAT boot is 1/2, GPT + bios_grub + ESP is 2/3). Sets
# TARGET_BOOT_PARTITION and TARGET_ROOT_PARTITION.
loopdev_find_partitions() {
  local loopdev="$1"
  local part

  TARGET_BOOT_PARTITION=""
  TARGET_ROOT_PARTITION=""

  for part in "/dev/mapper/$(basename "${loopdev}")p"*; do
    [[ -b "${part}" ]] || continue
    case "$(blkid -s TYPE -o value "${part}" 2>/dev/null)" in
      vfat)
        [[ -n "${TARGET_BOOT_PARTITION}" ]] || TARGET_BOOT_PARTITION="${part}"
        ;;
      btrfs)
        [[ -n "${TARGET_ROOT_PARTITION}" ]] || TARGET_ROOT_PARTITION="${part}"
        ;;
    esac
  done

  [[ -n "${TARGET_BOOT_PARTITION}" ]] \
    || raise "No FAT boot partition found in ${loopdev}. Was the image built?"
  [[ -n "${TARGET_ROOT_PARTITION}" ]] \
    || raise "No BTRFS root partition found in ${loopdev}. Was the image built?"
}
