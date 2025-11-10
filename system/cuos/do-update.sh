#!/bin/bash

set -x

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

VIRT_TYPE="$(systemd-detect-virt)"
if [[ "${VIRT_TYPE}" == "lxc" || "${VIRT_TYPE}" == "docker" ]]; then
  "${SCRIPT_DIR}/do-update-lxc.sh" "$@"
  exit "$?"
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

PARTITION="$(cat "/etc/partition_mode")"

export CONFIG_PATH="/system_next.json"

UPDATE_IMAGE="$(image_url "updater")" || \
  action_on_failure "cuos:updater:image_not_defined" "Updater image not defined"
UPDATE_IMAGE_DIGEST="$(jq -r '.updater_image_digest // empty' "${CONFIG_PATH}")"

OS_ARCH="$(cat "/etc/cuos-arch" 2>/dev/null || arch)"

OS_IMAGE="$(image_url "${OS_ARCH}" || image_url "os")" || \
  action_on_failure "cuos:updater:os_image_not_defined" "OS image not defined"
OS_DIGEST="$(jq -r --arg arch "${OS_ARCH}" '.[$arch+"_image_digest"] // .os_image_digest // empty' "${CONFIG_PATH}")"

IMAGE_VERSION_STRING="${OS_IMAGE}@${OS_DIGEST}"

if [[ "${IMAGE_VERSION_STRING}" == "$(cat /etc/image)" ]]; then
  echo "No new image version available. Exiting."
  exit 2
fi

state jq '.last_update_check = (now | todate)'

"${SCRIPT_DIR}/utils-docker-login.sh" || raise "Docker login failed"

docker image pull "${UPDATE_IMAGE}" || raise "Faild to fetch image"
NEW_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${UPDATE_IMAGE}" 2>/dev/null | cut -d '@' -f 2)
if [[ -n "${UPDATE_IMAGE_DIGEST}" && "${UPDATE_IMAGE_DIGEST}" != "${NEW_DIGEST}" ]]; then
  echo "Image digest mismatch: ${UPDATE_IMAGE_DIGEST} != ${NEW_DIGEST}"
  exit 1
fi

# Get Root Disk:
ROOT_DEV="$(findmnt -n -o SOURCE -T "/" | sed 's/\[.*\]//')"
ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_DEV" | head -n1)"

touch "/root/.docker/config.json"
docker run --rm \
  --pull=never \
  --log-driver=journald \
  --privileged \
  --device "${ROOT_DISK}" \
  -v "/root/.docker/config.json:/root/.docker/config.json:ro" \
  -v "/usr/local/share/ca-certificates/custom:/usr/local/share/ca-certificates/custom:ro" \
  -v "/etc/image:/etc/image:ro" \
  -e "TARGET_DEVICE=${ROOT_DISK}" \
  -e "OS_ARCH=${OS_ARCH}" \
  "${UPDATE_IMAGE}" \
  "${PARTITION}" "${OS_IMAGE}" "${OS_DIGEST}"

DOCKER_EXIT_CODE="$?"

echo "Exit Code: ${DOCKER_EXIT_CODE}"

PARTITION_NEXT="A"
[[ "${PARTITION}" == "A" ]] && PARTITION_NEXT="B"

if [[ "${DOCKER_EXIT_CODE}" = "0" ]]; then
  touch "/data/run-update"
  state '.state' 'updating'
  state jq '.last_update_date = (now | todate)'
  state '.update_state' 'updated partition '"${PARTITION_NEXT}"' to '"${OS_IMAGE}"
  report_info "cuos:update:restart" "Update requires reboot. Rebooting"
  echo "Rebooting ..."

  sync
  reboot
elif [[ "${DOCKER_EXIT_CODE}" = "2" ]]; then
  echo "No new image version available."
  report_info "cuos:update:not_needed" "No new image version available"
elif [[ "${DOCKER_EXIT_CODE}" = "3" ]]; then
  echo "Not enough free disk space available"
  report_info "cuos:update:no_space" "Not enough free disk space available"
else
  state '.update_state' "update of partition ${PARTITION_NEXT} to ${OS_IMAGE} failed"
  report_err "cuos:update:failed" "Update failed. Exit code ${DOCKER_EXIT_CODE}"
fi

exit "${DOCKER_EXIT_CODE}"
