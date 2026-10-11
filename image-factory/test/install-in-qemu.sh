#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Installs an installer ISO onto a blank disk in QEMU (SeaBIOS), unattended:
# the ISO's configuration has to set installer_auto_overwrite_disk, and the
# blank disk is the only one, so the installer picks it without asking. QEMU
# ends with the installer's reboot (-no-reboot). The disk can then be booted
# with boot-in-qemu.sh - without the ISO, which is the case to test.
#
# Writes screenshots after 1, 3 and 6 minutes into the disk's directory: an
# installer that stopped with an error waits in a shell, and its message is on
# the screen. Needs /dev/kvm - see the Dockerfile beside it.
#
# Usage: install-in-qemu.sh <iso> <disk to create> <size, e.g. 4G> [timeout in s]

set -uo pipefail

if (( $# < 3 )); then
  echo "Usage: $0 <iso> <disk to create> <size, e.g. 4G> [timeout in s]" >&2
  exit 2
fi

ISO="$1"
DISK="$2"
DISK_SIZE="$3"
TIMEOUT="${4:-900}"
MONITOR_SOCKET="/tmp/install-monitor.sock"
QEMU_PID=""

screenshot() {
  echo "screendump /tmp/install.ppm" | socat - "UNIX-CONNECT:${MONITOR_SOCKET}" >/dev/null
  sleep 1
  pnmtopng /tmp/install.ppm >"$(dirname "${DISK}")/install-$1.png" 2>/dev/null
}

stop_qemu() {
  [[ -z "${QEMU_PID}" ]] && return
  kill "${QEMU_PID}" 2>/dev/null
  wait "${QEMU_PID}" 2>/dev/null
}

main() {
  local at elapsed=0 rc

  trap stop_qemu EXIT

  rm -f "${DISK}"
  qemu-img create -q -f raw "${DISK}" "${DISK_SIZE}" || exit 1

  timeout "${TIMEOUT}" qemu-system-x86_64 -enable-kvm -machine q35 -m 2048 -smp 2 \
    -no-reboot \
    -drive "file=${DISK},format=raw,if=virtio" \
    -cdrom "${ISO}" -boot d \
    -monitor "unix:${MONITOR_SOCKET},server=on,wait=off" \
    -display none -vga std &
  QEMU_PID="$!"

  for at in 60 180 360; do
    sleep "$(( at - elapsed ))"
    elapsed="${at}"
    kill -0 "${QEMU_PID}" 2>/dev/null || break
    screenshot "${at}s"
  done

  wait "${QEMU_PID}"
  rc="$?"
  QEMU_PID=""
  if (( rc == 124 )); then
    echo "install: no reboot within ${TIMEOUT} s - see the screenshots"
    return 1
  fi
  echo "install: the installer rebooted (qemu exit ${rc})"
}

main "$@"
