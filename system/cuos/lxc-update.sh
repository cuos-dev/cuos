#!/bin/bash

set -x
set -o pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

CURRENT_PARTITION="$(cat "/etc/partition_mode" 2>/dev/null || echo "A")"
PARTITION="A"
if [[ "${CURRENT_PARTITION}" == "A" ]]; then
    PARTITION="B"
fi

raise() {
	echo "Error: $*" >&2
	exit 1
}

export CONFIG_PATH="/system_next.json"

UPDATE_REGISTRY="$(jq -r '.update_registry' "${CONFIG_PATH}")"
OS_IMAGE="$(jq -r '.os_image_lxc' "${CONFIG_PATH}")"
OS_VERSION="$(jq -r '.os_image_lxc_version // "latest"' "${CONFIG_PATH}")"
OS_DIGEST="$(jq -r '.os_image_lxc_digest // empty' "${CONFIG_PATH}")"

IMAGE_VERSION="${UPDATE_REGISTRY}${OS_IMAGE}:${OS_VERSION}"
IMAGE_VERSION_STRING="${UPDATE_REGISTRY}${OS_IMAGE}:${OS_VERSION}@${OS_DIGEST}"

if [[ "${IMAGE_VERSION_STRING}" == "$(cat /etc/image)" ]]; then
	echo "No new image version available. Exiting."
	exit 2
fi

"${SCRIPT_DIR}/state.sh" jq '.last_update_check = (now | todate)'

"${SCRIPT_DIR}/docker-login.sh" || raise "Docker login failed"

docker image pull "${IMAGE_VERSION}" || raise "Faild to fetch image"
NEW_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE_VERSION}" 2>/dev/null | cut -d '@' -f 2)
if [[ -n "${OS_IMAGE_DIGEST}" && "${OS_IMAGE_DIGEST}" != "${NEW_DIGEST}" ]]; then
	echo "Image digest mismatch: ${OS_IMAGE_DIGEST} != ${NEW_DIGEST}"
	exit 1
fi

if [[ "${IMAGE_VERSION}@${NEW_DIGEST}" == "$(cat /etc/image)" ]]; then
	echo "No new image version available (post). Exiting."
	exit 2
fi

rm -Rf /next /prev
mkdir -p /next

CONTAINER="$(docker create "${IMAGE_VERSION}")"
if ! docker export "${CONTAINER}" | (cd /next && tar xf -); then
	raise "Failed to export the container"
fi
docker rm "${CONTAINER}" \
	|| raise "Failed to remove the container"

cd /next || exit 127
rm -Rf .dockerenv sys dev proc data
cd / || exit 127

chroot /next /usr/local/cuos/first-run.sh "${PARTITION}" "${IMAGE_VERSION}" "${NEW_DIGEST}" \
	|| raise "Failed to run first-run script in container"

if [[ -d "/next${SCRIPT_DIR}/lxc-swaproot/" ]]; then
	cp -R "/next${SCRIPT_DIR}/lxc-swaproot/" /swaproot/ \
		|| raise "Failed to copy swaproot scripts"
else
	cp -R "${SCRIPT_DIR}/lxc-swaproot/" /swaproot/ \
		|| raise "Failed to copy swaproot scripts"
fi
if [[ -f "/next/bin/busybox" ]]; then
	cp /next/bin/busybox /swaproot/ \
		|| raise "Failed to copy busybox"
else
	cp /bin/busybox /swaproot/ \
		|| raise "Failed to copy busybox"
fi

mv /sbin/init /sbin/init-old
cat <<EOF >/sbin/init
#!/swaproot/busybox sh

/swaproot/busybox sh /swaproot/swap_update.sh
cd /
exec /sbin/init
EOF
chmod a+x /sbin/init


touch "/data/run-update"
"${SCRIPT_DIR}/state.sh" '.state' 'updating'
"${SCRIPT_DIR}/state.sh" jq '.last_update_date = (now | todate)'
"${SCRIPT_DIR}/state.sh" '.update_state' 'updated partition '"${PARTITION}"' to '"${OS_IMAGE}:${OS_VERSION}"
sync
echo "Rebooting ..."
reboot

