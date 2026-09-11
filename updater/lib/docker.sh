#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# A usable docker, wherever this runs: the daemon the caller handed in, or one
# started here. Sourced, never run.
#
# The caller's daemon arrives under a name of its own, because /var/run/docker.sock
# has to stay free for a daemon started here - a bind mount over that path cannot
# be unlinked, and the daemon would never come up. The plain path is still
# honoured by whoever mounts it there.

CUOS_DOCKER_SOCKET="${CUOS_DOCKER_SOCKET:-"/run/cuos-docker.sock"}"

_CUOS_DOCKERD_PID=""
_CUOS_DOCKERD_DATA_ROOT=""

docker_available() {
  docker info >/dev/null 2>&1
}

docker_use_handed_in() {
  [[ -S "${CUOS_DOCKER_SOCKET}" ]] || return 1

  export DOCKER_HOST="unix://${CUOS_DOCKER_SOCKET}"
  if docker_available; then
    return 0
  fi

  # A socket that does not answer must not keep the client from reaching a
  # daemon started here, which listens on the default path.
  unset DOCKER_HOST
  return 1
}

# $1 is the data root. Everything it writes lands there, and docker_cleanup
# takes it away again.
docker_start() {
  local data_root="$1"
  local counter=0

  mkdir -p "${data_root}"
  dockerd \
    --storage-driver btrfs \
    --iptables=false \
    --ip6tables=false \
    --ip-forward=false \
    --ip-masq=false \
    --bridge=none \
    --data-root "${data_root}" &
  _CUOS_DOCKERD_PID="$!"
  _CUOS_DOCKERD_DATA_ROOT="${data_root}"

  echo "Waiting for Docker to be ready..."
  until docker_available; do
    counter="$((counter + 1))"
    if [[ "${counter}" -gt 100 ]]; then
      return 1
    fi
    sleep 1
    if ! kill -0 "${_CUOS_DOCKERD_PID}" 2>/dev/null; then
      _CUOS_DOCKERD_PID=""
      return 1
    fi
  done
  return 0
}

# $1 is the data root for a daemon of our own, if one is needed.
docker_ensure() {
  docker_use_handed_in && return 0
  docker_available && return 0

  local attempt=0
  while (( attempt < 4 )); do
    docker_start "$1" && return 0
    attempt="$(( attempt + 1 ))"
  done
  return 1
}

docker_stop() {
  [[ -n "${_CUOS_DOCKERD_PID}" ]] || return 0

  sync
  sleep 1
  kill "${_CUOS_DOCKERD_PID}" || true
  wait "${_CUOS_DOCKERD_PID}" || true
  _CUOS_DOCKERD_PID=""
}

# $1 is the data root this run offered, and it holds a copy of the system image
# that nothing reads afterwards: the installed system keeps its own under
# /data/docker, and a caller who hands a daemon in has one elsewhere. So once
# our daemon is stopped, whatever is left at that path can go - this run's, or
# what a run that stopped its daemon afterwards left behind.
docker_cleanup() {
  local data_root="${1:-"${_CUOS_DOCKERD_DATA_ROOT}"}"

  docker_stop

  [[ -n "${data_root}" && -d "${data_root}" ]] || return 0

  btrfs subvolume delete -R "${data_root}/btrfs/subvolumes"/* 2>/dev/null || true
  rm -Rf "${data_root}"
  _CUOS_DOCKERD_DATA_ROOT=""
}
