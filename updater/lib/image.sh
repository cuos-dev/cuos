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
# only be asked once the image has been pulled - which on a small ARM board costs
# half an hour for an update that turns out to be unnecessary, and the standby
# slot's image, which is removed to make room for the pull.
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
    || raise 103 "Failed to fetch system image"
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

# $1 is "name:tag@digest", as /etc/image holds it. Prints "name@digest": a
# reference with both a tag and a digest is not one the daemon looks up the same
# way everywhere. The tag is cut from the last path component only, because a
# registry's port is a colon as well.
digest_ref() {
  local ref="${1:-}"
  local name="${ref%@*}"

  [[ "${ref}" == *@* ]] || return 1
  if [[ "${name##*/}" == *:* ]]; then
    name="${name%:*}"
  fi
  echo "${name}@${ref##*@}"
}

# $1 is an image reference. Prints the image's id, fails if it is not there.
image_id() {
  docker image inspect --format '{{.Id}}' "$1" 2>/dev/null
}

# $1 is an image reference. Fails if the image is not there.
image_size_kb() {
  local size
  size="$(docker image inspect --format '{{.Size}}' "$1" 2>/dev/null)" || return 1
  [[ "${size}" =~ ^[0-9]+$ ]] || return 1
  echo "$(( size / 1024 ))"
}

# An image fetched beforehand ("cuos pull") takes its room already, and the
# estimate would count it a second time. Pinned, the digest says whether it is
# there; unpinned, a tag that points at anything but the running image can only
# have been moved by such a pull - the standby's image is gone by now.
target_is_local() {
  local id active

  if [[ -n "${IMAGE_DIGEST}" ]]; then
    image_id "$(digest_ref "${IMAGE}@${IMAGE_DIGEST}")" >/dev/null
    return
  fi

  id="$(image_id "${IMAGE}")" || return 1
  active="$(digest_ref "$(cat "${T_FILE_IMAGE:-"/etc/image"}" 2>/dev/null)")"
  [[ "${id}" != "$(image_id "${active}")" ]]
}

# The image just pulled, when it cannot be installed after all. Never the
# running one: image_is_installed has turned that case away before this.
remove_pulled_image() {
  local id

  id="$(image_id "${IMAGE}")" || return 0
  docker image rm "${id}" || true
}
