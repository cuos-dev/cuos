#!/bin/bash

set -x
set -o pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"


CURRENT_SLOT="$(cat "/etc/active_slot" 2>/dev/null || echo "A")"
SLOT="A"
if [[ "${CURRENT_SLOT}" == "A" ]]; then
    SLOT="B"
fi

export CONFIG_PATH="/system_next.json"

LXC_IMAGE="$(image_url "lxc")" || \
  action_on_failure "cuos:updater:lxc_image_not_defined" "LXC image not defined"
LXC_IMAGE_DIGEST="$(jq -r '.lxc_image_digest // empty' "${CONFIG_PATH}")"

IMAGE_VERSION="${LXC_IMAGE}"
IMAGE_VERSION_STRING="${LXC_IMAGE}@${LXC_IMAGE_DIGEST}"

if [[ "${IMAGE_VERSION_STRING}" == "$(cat /etc/image)" ]]; then
	echo "No new image version available. Exiting."
	exit 2
fi

state jq '.last_update_check = (now | todate)'

"${SCRIPT_DIR}/utils-docker-login.sh" || raise "Docker login failed"

docker image pull "${IMAGE_VERSION}" || raise "Faild to fetch image"
NEW_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE_VERSION}" 2>/dev/null | cut -d '@' -f 2)
if [[ -n "${LXC_IMAGE_DIGEST}" && "${LXC_IMAGE_DIGEST}" != "${NEW_DIGEST}" ]]; then
	echo "Image digest mismatch: ${LXC_IMAGE_DIGEST} != ${NEW_DIGEST}"
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

chroot /next /usr/local/cuos/first-run.sh "${SLOT}" "${IMAGE_VERSION}" "${NEW_DIGEST}" \
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
state '.state' 'updating'
state jq '.last_update_date = (now | todate)'
state '.update_state' 'updated slot '"${SLOT}"' to '"${LXC_IMAGE}"
sync
echo "Rebooting ..."
reboot

