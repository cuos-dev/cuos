#!/bin/bash

set -x

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

raise() {
	echo "Error: $*" >&2
	exit 1
}

export CONFIG_PATH="/system.json"

UPDATE_IMAGE="$(image_url "updater")" || \
  action_on_failure "cuos:updater:image_not_defined" "Updater image not defined"
UPDATE_IMAGE_DIGEST="$(jq -r '.updater_image_digest // empty' "${CONFIG_PATH}")"

OS_IMAGE="$(image_url "os")" || \
  action_on_failure "cuos:updater:os_image_not_defined" "OS image not defined"
OS_DIGEST="$(jq -r '.os_image_digest // empty' "${CONFIG_PATH}")"

IMAGE_VERSION_STRING="${OS_IMAGE}@${OS_DIGEST}"

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

docker network rm cuos-internet
docker network create \
	--driver=bridge \
	--opt com.docker.network.bridge.enable_icc=false \
	--opt com.docker.network.bridge.enable_ip_masquerade=true \
	cuos-internet

touch "/root/.docker/config.json"
docker run --rm -it \
	--pull=never \
	--network=cuos-internet \
	--privileged \
	--device "${ROOT_DISK}" \
	-v "/root/.docker/config.json:/root/.docker/config.json:ro" \
	-v "/usr/local/share/ca-certificates/custom:/usr/local/share/ca-certificates/custom:ro" \
	-v "/etc/image:/etc/image:ro" \
	-e "TARGET_DEVICE=${ROOT_DISK}" \
	--name dockerboot-updater-container \
	--entrypoint "/usr/local/updater/shell.sh" \
	"${UPDATE_IMAGE}"

DOCKER_EXIT_CODE="$?"

echo "Exit Code: ${DOCKER_EXIT_CODE}"

docker network rm cuos-internet

exit "${DOCKER_EXIT_CODE}"
