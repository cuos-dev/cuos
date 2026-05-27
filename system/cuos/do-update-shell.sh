#!/bin/bash

set -x

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

UPDATE_IMAGE="$(image_url "updater")" || \
  raise "Updater image not defined"
UPDATE_IMAGE_DIGEST="$(jq -r '.updater_image_digest // empty' "${CONFIG_PATH}")"

"${SCRIPT_DIR}/utils-docker-login.sh" || raise "Docker login failed"

docker image pull "${UPDATE_IMAGE}" || raise "Faild to fetch image"
NEW_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${UPDATE_IMAGE}" 2>/dev/null | cut -d '@' -f 2)
if [[ -n "${UPDATE_IMAGE_DIGEST}" && "${UPDATE_IMAGE_DIGEST}" != "${NEW_DIGEST}" ]]; then
	raise "Image digest mismatch: ${UPDATE_IMAGE_DIGEST} != ${NEW_DIGEST}"
fi

# Get Root Disk:
ROOT_DEV="$(findmnt -n -o SOURCE -T "/" | sed 's/\[.*\]//')"
ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_DEV" | head -n1)"

touch "/root/.docker/config.json"
docker run --rm -it \
	--pull=never \
	--log-driver=journald \
	--privileged \
	--device "${ROOT_DISK}" \
	-v "/root/.docker/config.json:/root/.docker/config.json:ro" \
	-v "/usr/local/share/ca-certificates/custom:/usr/local/share/ca-certificates/custom:ro" \
	-v "/etc/image:/etc/image:ro" \
	-e "TARGET_DEVICE=${ROOT_DISK}" \
	--entrypoint "/usr/local/updater/shell.sh" \
	"${UPDATE_IMAGE}"

DOCKER_EXIT_CODE="$?"

echo "Exit Code: ${DOCKER_EXIT_CODE}"

docker network rm cuos-internet

exit "${DOCKER_EXIT_CODE}"
