#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Boots an x86_64 disk image from image-factory in QEMU and looks at the system
# from the inside, through the QEMU guest agent the system enables on KVM.
# Writes inside.txt and two screenshots into the output directory. Fails when
# the agent never answers, when a unit failed, or when cuos-init is not active.
# Needs /dev/kvm - see the Dockerfile beside it.
#
# Usage: boot-in-qemu.sh <bios|uefi> <image> <disk size, e.g. 4G, or "same">
#                        <output dir> [timeout in s]
#
# The guest writes into a qcow2 overlay, not into the image: the first boot
# grows its partition, and the image stays as built. Only what the guest
# changes is written - a copy of the image would be gigabytes of I/O for
# nothing. "same" keeps the disk at the size of the image: the case the
# image's own free space is for.

set -uo pipefail

if (( $# < 4 )); then
  echo "Usage: $0 <bios|uefi> <image> <disk size, e.g. 4G, or \"same\"> <output dir> [timeout in s]" >&2
  exit 2
fi

FIRMWARE="$1"
IMAGE="$2"
DISK_SIZE="$3"
OUT_DIR="$4"
TIMEOUT="${5:-300}"
QEMU_PID=""

DISK="/tmp/disk.qcow2"
QGA_SOCKET="/tmp/qga.sock"
MONITOR_SOCKET="/tmp/monitor.sock"
OVMF_DIR="/usr/share/OVMF"

# What the first boot must have done, asked from inside.
INSIDE_CHECKS='
echo "== cmdline"; cat /proc/cmdline
echo "== mounts"
for m in / /data /swap; do findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS -M "$m"; done
echo "== lsblk"; lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID
echo "== df"; df -h / /data
echo "== subvolumes"; btrfs subvolume list /
echo "== image"; cat /etc/image /etc/active_slot
echo "== swap"; swapon --show
echo "== system.json"; ls -l /system.json /data/system_*.json 2>&1
echo "== failed units"; systemctl --failed --no-legend --plain
echo "== cuos-init"; systemctl is-active cuos-init.service
journalctl -u cuos-init -b --no-pager | grep -i -B4 -E "error|fail" | head -40
'

screenshot() {
  echo "screendump /tmp/screen.ppm" | socat - "UNIX-CONNECT:${MONITOR_SOCKET}" >/dev/null
  sleep 1
  pnmtopng /tmp/screen.ppm >"${OUT_DIR}/$1.png" 2>/dev/null
}

# One connection for the whole run: the agent's channel is a single stream, and
# replies to a closed connection turn up in the next one. guest-sync with a
# fresh id marks where the reply to a request starts. Sets QGA_REPLY rather than
# printing it, because a coprocess's descriptors do not reach a subshell.
qga_open() {
  coproc QGA { socat - "UNIX-CONNECT:${QGA_SOCKET}" 2>/dev/null; }
}

qga() {
  local id="$(( RANDOM * 32768 + RANDOM ))"
  local line

  QGA_REPLY=""
  if [[ -z "${QGA_PID:-}" ]] || ! kill -0 "${QGA_PID}" 2>/dev/null; then
    qga_open
  fi
  printf '{"execute":"guest-sync","arguments":{"id":%s}}\n%s\n' "${id}" "$1" \
    >&"${QGA[1]}" || return 1

  while IFS= read -r -t 10 line <&"${QGA[0]}"; do
    [[ "${line}" == *"\"return\": ${id}}"* ]] || continue
    IFS= read -r -t 30 QGA_REPLY <&"${QGA[0]}"
    return
  done
  return 1
}

# $1 is a shell command. Prints its stdout and stderr.
guest_exec() {
  local pid

  qga "$(jq -cn --arg c "$1" \
    '{execute: "guest-exec", arguments: {path: "/bin/sh", arg: ["-c", $c], "capture-output": true}}')"
  pid="$(jq -r '.return.pid // empty' <<<"${QGA_REPLY}")"
  if [[ -z "${pid}" ]]; then
    echo "(guest-exec failed: ${QGA_REPLY})"
    return 1
  fi

  for _ in $(seq 120); do
    qga "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":${pid}}}"
    if [[ "$(jq -r '.return.exited' <<<"${QGA_REPLY}")" == "true" ]]; then
      jq -r '.return["out-data"] // empty' <<<"${QGA_REPLY}" | base64 -d
      jq -r '.return["err-data"] // empty' <<<"${QGA_REPLY}" | base64 -d
      return 0
    fi
    sleep 1
  done
  echo "(no result for pid ${pid})"
  return 1
}

# $1 is inside.txt. The failed units, and cuos-init if it is not active.
inside_problems() {
  sed -n '/^== failed units$/,/^== cuos-init$/p' "$1" | grep -v '^=='
  sed -n '/^== cuos-init$/{n;p}' "$1" | grep -vx active
}

stop_qemu() {
  [[ -z "${QEMU_PID}" ]] && return
  kill "${QEMU_PID}" 2>/dev/null
  wait "${QEMU_PID}" 2>/dev/null
}

main() {
  local firmware_args=() start up="" problems

  trap stop_qemu EXIT

  mkdir -p "${OUT_DIR}"
  [[ "${DISK_SIZE}" != "same" ]] || DISK_SIZE=""
  # shellcheck disable=SC2086
  qemu-img create -q -f qcow2 -b "$(readlink -f "${IMAGE}")" -F raw "${DISK}" \
    ${DISK_SIZE} || exit 1

  if [[ "${FIRMWARE}" == "uefi" ]]; then
    cp "${OVMF_DIR}/OVMF_VARS_4M.fd" /tmp/vars.fd
    firmware_args=(
      -drive "if=pflash,format=raw,readonly=on,file=${OVMF_DIR}/OVMF_CODE_4M.fd"
      -drive "if=pflash,format=raw,file=/tmp/vars.fd"
    )
  fi

  qemu-system-x86_64 -enable-kvm -machine q35 -m 2048 -smp 2 \
    "${firmware_args[@]}" \
    -drive "file=${DISK},format=qcow2,if=virtio" \
    -nic user,model=virtio-net-pci \
    -device virtio-serial \
    -chardev "socket,path=${QGA_SOCKET},server=on,wait=off,id=qga0" \
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    -monitor "unix:${MONITOR_SOCKET},server=on,wait=off" \
    -display none -vga std &
  QEMU_PID="$!"

  start="${SECONDS}"
  sleep 8
  screenshot early
  while (( SECONDS - start < TIMEOUT )); do
    if qga '{"execute":"guest-ping"}' && [[ "${QGA_REPLY}" == *return* ]]; then
      up=1
      break
    fi
    sleep 5
  done
  echo "guest agent: $([[ -n "${up}" ]] && echo answered || echo "no answer") after $(( SECONDS - start )) s"

  [[ -n "${up}" ]] || { screenshot final; return 1; }

  # The agent starts before cuos-init has finished the first boot.
  sleep 45
  guest_exec "${INSIDE_CHECKS}" >"${OUT_DIR}/inside.txt"
  screenshot final

  problems="$(inside_problems "${OUT_DIR}/inside.txt")"
  if [[ -n "${problems}" ]]; then
    echo "inside: ${problems}"
    return 1
  fi
  echo "inside: no failed unit, cuos-init active"
}

main "$@"
