#!/bin/bash

set -x

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

VIRT_TYPE="$(systemd-detect-virt)"
if [[ "${VIRT_TYPE}" = "lxc" ]]; then
	"${SCRIPT_DIR}/lxc-update.sh" "$@"
	exit "$?"
fi

PARTITION="$(cat "/etc/partition_mode")"

raise() {
	echo "Error: $*" >&2
	exit 1
}

export CONFIG_PATH="/system_next.json"

UPDATE_REGISTRY="$(jq -r '.update_registry' "${CONFIG_PATH}")"
UPDATE_IMAGE_NAME="$(jq -r '.updater_image' "${CONFIG_PATH}")"
UPDATE_IMAGE_VERSION="$(jq -r '.updater_image_version // "latest"' "${CONFIG_PATH}")"
UPDATE_IMAGE="${UPDATE_REGISTRY}${UPDATE_IMAGE_NAME}:${UPDATE_IMAGE_VERSION}"
UPDATE_IMAGE_DIGEST="$(jq -r '.updater_image_digest // empty' "${CONFIG_PATH}")"
OS_IMAGE="$(jq -r '.os_image' "${CONFIG_PATH}")"
OS_VERSION="$(jq -r '.os_image_version // "latest"' "${CONFIG_PATH}")"
OS_DIGEST="$(jq -r '.os_image_digest // empty' "${CONFIG_PATH}")"


IMAGE_VERSION_STRING="${UPDATE_REGISTRY}${OS_IMAGE}:${OS_VERSION}@${OS_DIGEST}"

if [[ "${IMAGE_VERSION_STRING}" == "$(cat /etc/image)" ]]; then
	echo "No new image version available. Exiting."
	exit 2
fi

"${SCRIPT_DIR}/state.sh" jq '.last_update_check = (now | todate)'

"${SCRIPT_DIR}/docker-login.sh" || raise "Docker login failed"

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
	--network=host \
	--privileged \
	--device "${ROOT_DISK}" \
	-v "/root/.docker/config.json:/root/.docker/config.json:ro" \
	-v "/usr/local/share/ca-certificates/custom:/usr/local/share/ca-certificates/custom:ro" \
	-v "/etc/image:/etc/image:ro" \
	-e "TARGET_DEVICE=${ROOT_DISK}" \
	--name dockerboot-updater-container \
	"${UPDATE_IMAGE}" \
	"${PARTITION}" "${UPDATE_REGISTRY}${OS_IMAGE}:${OS_VERSION}" "${OS_DIGEST}"

DOCKER_EXIT_CODE="$?"

echo "Exit Code: ${DOCKER_EXIT_CODE}"

if [[ "${DOCKER_EXIT_CODE}" = "0" ]]; then
	PARTITION_NEXT="A"
	[[ "${PARTITION}" == "A" ]] && PARTITION_NEXT="B"
	touch "/data/run-update"
	"${SCRIPT_DIR}/state.sh" '.state' 'updating'
	"${SCRIPT_DIR}/state.sh" jq '.last_update_date = (now | todate)'
	"${SCRIPT_DIR}/state.sh" '.update_state' 'updated partition '"${PARTITION_NEXT}"' to '"${OS_IMAGE}:${OS_VERSION}"
	sync
	echo "Rebooting ..."
	reboot
elif [[ "${DOCKER_EXIT_CODE}" = "2" ]]; then
	echo "No new image version available."
else
	"${SCRIPT_DIR}/state.sh" '.update_state' "update of partition ${PARTITION_NEXT} to ${OS_IMAGE}:${OS_VERSION} failed"
	logger -t cuos -p "err" "Error: Update failed. Exit code ${DOCKER_EXIT_CODE}"
fi

exit "${DOCKER_EXIT_CODE}"
