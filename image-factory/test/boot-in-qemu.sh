#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Boots an x86_64 disk image from image-factory in QEMU and looks at the system
# from the inside, through the QEMU guest agent the system enables on KVM.
# Writes inside.txt and two screenshots into the output directory, and fails
# when the agent never answers. Needs /dev/kvm - see the Dockerfile beside it.
#
# Usage: boot-in-qemu.sh <bios|uefi> <image> <disk size, e.g. 4G, or "same">
#                        <output dir> [timeout in s]
#
# The image is copied first, because the first boot grows its partition.
# "same" keeps the disk at the size of the image: the case the image's own free
# space is for.

set -uo pipefail

FIRMWARE="$1"
IMAGE="$2"
DISK_SIZE="$3"
OUT_DIR="$4"
TIMEOUT="${5:-300}"

DISK="/tmp/disk.img"
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
echo "== failed units"; systemctl --failed --no-legend
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

main() {
  local firmware_args=() qemu_pid start up=""

  mkdir -p "${OUT_DIR}"
  cp --sparse=always "${IMAGE}" "${DISK}" || exit 1
  if [[ "${DISK_SIZE}" != "same" ]]; then
    qemu-img resize -f raw "${DISK}" "${DISK_SIZE}" >/dev/null || exit 1
  fi

  if [[ "${FIRMWARE}" == "uefi" ]]; then
    cp "${OVMF_DIR}/OVMF_VARS_4M.fd" /tmp/vars.fd
    firmware_args=(
      -drive "if=pflash,format=raw,readonly=on,file=${OVMF_DIR}/OVMF_CODE_4M.fd"
      -drive "if=pflash,format=raw,file=/tmp/vars.fd"
    )
  fi

  qemu-system-x86_64 -enable-kvm -machine q35 -m 2048 -smp 2 \
    "${firmware_args[@]}" \
    -drive "file=${DISK},format=raw,if=virtio" \
    -nic user,model=virtio-net-pci \
    -device virtio-serial \
    -chardev "socket,path=${QGA_SOCKET},server=on,wait=off,id=qga0" \
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    -monitor "unix:${MONITOR_SOCKET},server=on,wait=off" \
    -display none -vga std &
  qemu_pid="$!"

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
  echo "guest agent: ${up:+answered}${up:-no answer} after $(( SECONDS - start )) s"

  if [[ -n "${up}" ]]; then
    # The agent starts before cuos-init has finished the first boot.
    sleep 45
    guest_exec "${INSIDE_CHECKS}" >"${OUT_DIR}/inside.txt"
  fi
  screenshot final

  kill "${qemu_pid}" 2>/dev/null
  wait "${qemu_pid}" 2>/dev/null
  [[ -n "${up}" ]]
}

main "$@"
