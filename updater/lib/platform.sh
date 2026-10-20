#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# The architecture a system image is pulled and run for. Sourced, never run.

# $1 is OS_ARCH; empty asks the daemon what it runs.
target_platform() {
  local arch="${1:-}"
  local platform=""

  case "${arch}" in
    x86_64)
      platform="linux/amd64"
      ;;
    aarch64)
      platform="linux/arm64"
      ;;
    armv7l)
      platform="linux/arm/v7"
      ;;
    armv6l)
      platform="linux/arm/v6"
      ;;
    i686)
      platform="linux/386"
      ;;
    rpi-arm64)
      platform="linux/arm64"
      ;;
    rpi-arm32)
      # ARMv6 so the image also runs on Pi 1 and Zero
      platform="linux/arm/v6"
      ;;
    orangepi-zero3)
      platform="linux/arm64"
      ;;
    # Fixed rather than the daemon's: the image is built for Proxmox, which is
    # amd64, and a build on an arm64 Mac would otherwise ask for an arm64
    # image that does not exist.
    lxc)
      platform="linux/amd64"
      ;;
    "")
      ;;
    *)
      echo "Unknown architecture: ${arch}" >&2
      return 1
      ;;
  esac

  platform="${platform:-"$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')"}"
  if [[ "${platform}" = "linux/arm" ]]; then
    platform="linux/arm/v7"
  fi
  echo "${platform}"
}
