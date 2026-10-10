#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

set -x

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

VIRT_TYPE="$(systemd-detect-virt)"
if [[ "${VIRT_TYPE}" == "lxc" || "${VIRT_TYPE}" == "docker" ]]; then
  "${SCRIPT_DIR}/do-update-lxc.sh" "$@"
  exit "$?"
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

# $1 is "update" or "pull", $2 the merged configuration to update to. It is a
# file of its own and not /system_next.json: that one is the standby slot's
# configuration, and it is only replaced once the slot holds the image this
# configuration names. A pull leaves both alone.
ACTION="${1:-}"
export CONFIG_PATH="${2:-}"

case "${ACTION}" in
  update|pull) ;;
  *) raise 1 "Unknown action: ${ACTION}" ;;
esac
[[ -f "${CONFIG_PATH}" ]] \
  || raise 1 "No configuration to ${ACTION} to: ${CONFIG_PATH}"

SLOT="$(cat "/etc/active_slot")"

UPDATE_IMAGE="$(image_url "updater")" || \
  raise 31 "Updater image not defined"
UPDATE_IMAGE_DIGEST="$(jq -r '.updater_image_digest // empty' "${CONFIG_PATH}")"

OS_ARCH="$(cat "/etc/cuos-arch" 2>/dev/null || arch)"

OS_IMAGE="$(image_url "${OS_ARCH}" || image_url "os")" || \
  raise 32 "OS image not defined"
OS_DIGEST="$(jq -r --arg arch "${OS_ARCH}" '.[$arch+"_image_digest"] // .os_image_digest // empty' "${CONFIG_PATH}")"

IMAGE_VERSION_STRING="${OS_IMAGE}@${OS_DIGEST}"

if [[ "${IMAGE_VERSION_STRING}" == "$(cat /etc/image)" ]]; then
  report_info "cuos:update:not_needed" "The system is up-to-date"
  raise_info 22 "No new image version available. Exiting (pre)"
fi

if [[ "${ACTION}" == "update" ]]; then
  state jq '.last_update_check = (now | todate)'
fi

"${SCRIPT_DIR}/utils-docker-login.sh" || raise 33 "Docker login failed"

docker image pull "${UPDATE_IMAGE}" || raise 34 "Faild to fetch image"
NEW_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${UPDATE_IMAGE}" 2>/dev/null | cut -d '@' -f 2)
if [[ -n "${UPDATE_IMAGE_DIGEST}" && "${UPDATE_IMAGE_DIGEST}" != "${NEW_DIGEST}" ]]; then
  raise 30 "Image digest mismatch: ${UPDATE_IMAGE_DIGEST} != ${NEW_DIGEST}"
fi

# Get Root Disk:
ROOT_DEV="$(findmnt -n -o SOURCE -T "/" | sed 's/\[.*\]//')"
ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_DEV" | head -n1)"

# An update runs the image's default entrypoint, because a downgrade runs an
# updater whose only one that is (updater.sh). Everything else is asked for by
# name, and an updater too old to have it is told apart by docker's 127.
ENTRYPOINT=()
if [[ "${ACTION}" == "pull" ]]; then
  ENTRYPOINT=(--entrypoint /api/pull)
fi

touch "/root/.docker/config.json"
# The host's docker socket goes in under a name of its own, because
# /var/run/docker.sock inside the updater has to stay free: an updater that
# brings no daemon along starts a dockerd there, and a bind mount over that
# path cannot be unlinked, so the daemon never comes up. The updater of an
# older release - the one a downgrade runs - is such an updater.
docker run --rm \
  --pull=never \
  --log-driver=journald \
  --privileged \
  --device "${ROOT_DISK}" \
  -v "/root/.docker/config.json:/root/.docker/config.json:ro" \
  -v "/var/run/docker.sock:/run/cuos-docker.sock:ro" \
  -v "/usr/local/share/ca-certificates/custom:/usr/local/share/ca-certificates/custom:ro" \
  -v "/etc/image:/etc/image:ro" \
  -v "${CONFIG_PATH}:/system.json:ro" \
  -e "TARGET_DEVICE=${ROOT_DISK}" \
  -e "OS_ARCH=${OS_ARCH}" \
  "${ENTRYPOINT[@]}" \
  "${UPDATE_IMAGE}" \
  "${SLOT}" "${OS_IMAGE}" "${OS_DIGEST}"

DOCKER_EXIT_CODE="$?"

echo "Exit Code: ${DOCKER_EXIT_CODE}"

SLOT_NEXT="A"
[[ "${SLOT}" == "A" ]] && SLOT_NEXT="B"

if [[ "${ACTION}" == "pull" ]]; then
  if [[ "${DOCKER_EXIT_CODE}" = "0" ]]; then
    report_info "cuos:pull:done" "Fetched ${OS_IMAGE}; an update installs it without downloading"
  elif [[ "${DOCKER_EXIT_CODE}" = "127" ]]; then
    report_err "cuos:pull:not_supported" "The updater ${UPDATE_IMAGE} cannot pull"
    raise 35 "The updater ${UPDATE_IMAGE} cannot pull: it has no /api/pull"
  elif [[ "${DOCKER_EXIT_CODE}" = "102" ]]; then
    report_info "cuos:update:not_needed" "The system is up-to-date"
  else
    report_err "cuos:pull:failed" "Pull failed. Exit code ${DOCKER_EXIT_CODE}"
  fi
  exit "${DOCKER_EXIT_CODE}"
fi

if [[ "${DOCKER_EXIT_CODE}" = "0" ]]; then
  # The new slot is installed, and the boot chain points at it. Its
  # configuration is the one this update was given, and the reboot waits for it:
  # a slot that came up with the configuration of whatever image it held before
  # would be worse than none.
  if ! replace_file_content "/system_next.json" <"${CONFIG_PATH}"; then
    state '.update_state' "update of slot ${SLOT_NEXT} to ${OS_IMAGE} failed: its configuration could not be written"
    report_err "cuos:update:failed" "Update installed, but the configuration of slot ${SLOT_NEXT} could not be written. Not rebooting"
    raise 36 "Failed to write /system_next.json; slot ${SLOT_NEXT} is installed and will boot next"
  fi

  touch "/data/run-update"
  state '.state' 'updating'
  state jq '.last_update_date = (now | todate)'
  state '.update_state' 'updated slot '"${SLOT_NEXT}"' to '"${OS_IMAGE}"
  report_info "cuos:update:restart" "Update requires reboot. Rebooting"
  echo "Rebooting ..."

  sync
  reboot
elif [[ "${DOCKER_EXIT_CODE}" = "102" ]]; then
  echo "No new image version available."
  report_info "cuos:update:not_needed" "The system is up-to-date"

elif [[ "${DOCKER_EXIT_CODE}" = "101" ]]; then
  echo "Not enough free disk space available"
  report_info "cuos:update:no_space" "Not enough free disk space available"
else
  state '.update_state' "update of slot ${SLOT_NEXT} to ${OS_IMAGE} failed"
  report_err "cuos:update:failed" "Update failed. Exit code ${DOCKER_EXIT_CODE}"
fi

exit "${DOCKER_EXIT_CODE}"
