#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# The system image: which one is installed, fetching it, unpacking it into a
# slot. Sourced, never run.

# $1 is a digest of ${IMAGE}
image_is_installed() {
  local image_file="${T_FILE_IMAGE:-"/etc/image"}"

  [[ "${IMAGE}@${1}" == "$(cat "${image_file}" 2>/dev/null)" ]]
}

# Asks the registry whether there is anything new, before anything is downloaded
# or deleted. image_is_installed below the pull is the same question, but it can
# only be asked once the image has been pulled - and the pull needs the room
# that deleting the standby slot frees, so by then the slot this system would
# roll back to is already gone. On a small ARM board that costs half an hour and
# the rollback target for an update that turns out to be unnecessary.
#
# imagetools reports the digest of the manifest *list*, which is what docker
# records in RepoDigests after a pull and therefore what /etc/image holds.
# "docker manifest inspect -v" is not a substitute: it reports the digests of
# the individual platform manifests, which are different values (measured on a
# board, 2026-09-06).
#
# Advisory only. An empty answer - no buildx, an unreachable or a
# non-conforming registry - falls through to the pull and changes nothing.
remote_digest_is_installed() {
  local remote_digest
  remote_digest="$(docker buildx imagetools inspect \
    --format '{{.Manifest.Digest}}' "${IMAGE}" 2>/dev/null)"

  [[ -n "${remote_digest}" ]] && image_is_installed "${remote_digest}"
}

repo_digest() {
  docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}" 2>/dev/null \
    | cut -d '@' -f 2
}

# $1 is the digest from the registry, empty for a locally built image: that one
# has no RepoDigests, and its id identifies it just as well.
image_digest() {
  echo "${1:-"$(docker inspect --format='{{.Id}}' "${IMAGE}")"}"
}

# The factory tags the image it has just built ':build' and hands it over
# locally, so there is no registry to pull it from.
is_local_build() {
  [[ "${INSTALLIMAGE}" = "true" && "${IMAGE}" = *:build ]]
}

pull_image() {
  if is_local_build; then return; fi

  docker image pull --platform "${TARGET_PLATFORM}" "${IMAGE}" \
    || raise 103 "Faild to fetch system image"
}

export_rootfs() {
  local container
  container="$(docker create --platform "${TARGET_PLATFORM}" "${IMAGE}")" \
    || raise 106 "Failed to create container for export"

  if ! docker export "${container}" \
      | tar -C "${CONTAINER_ROOTFS_FS}" --numeric-owner --xattrs --xattrs-include='*' -xf -; then
    docker rm "${container}" >/dev/null 2>&1 || true
    raise 107 "Failed to export the container"
  fi
  docker rm "${container}" \
    || raise 108 "Failed to remove the container"

  rm -f "${CONTAINER_ROOTFS_FS}/.dockerenv" || true
}

