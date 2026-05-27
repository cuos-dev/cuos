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
  raise 41 "LXC image not defined"
LXC_IMAGE_DIGEST="$(jq -r '.lxc_image_digest // empty' "${CONFIG_PATH}")"

IMAGE_VERSION="${LXC_IMAGE}"
IMAGE_VERSION_STRING="${LXC_IMAGE}@${LXC_IMAGE_DIGEST}"

if [[ "${IMAGE_VERSION_STRING}" == "$(cat /etc/image)" ]]; then
  report_info "cuos:update:not_needed" "The system is up-to-date"
  raise_info 22 "No new image version available. Exiting."
fi

AVAIL_BYTES=$(df -B1 "/" | awk 'NR==2 {print $4}')
REQUIRED_BYTES=$((2 * 1024 * 1024 * 1024))
if [ "$AVAIL_BYTES" -le "$REQUIRED_BYTES" ]; then
  report_info "cuos:update:no_space" "Not enough free disk space available"
  raise 21 "Not enough free space in ${TARGET_ROOT} (required: >2GB, available: $((AVAIL_BYTES/1024/1024)) MB). Aborting update." >&2
fi

state jq '.last_update_check = (now | todate)'

"${SCRIPT_DIR}/utils-docker-login.sh" || raise 42 "Docker login failed"

docker image pull "${IMAGE_VERSION}" || raise 43 "Faild to fetch image"
NEW_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE_VERSION}" 2>/dev/null | cut -d '@' -f 2)
if [[ -n "${LXC_IMAGE_DIGEST}" && "${LXC_IMAGE_DIGEST}" != "${NEW_DIGEST}" ]]; then
  raise 30 "Image digest mismatch: ${LXC_IMAGE_DIGEST} != ${NEW_DIGEST}"
fi

if [[ "${IMAGE_VERSION}@${NEW_DIGEST}" == "$(cat /etc/image)" ]]; then
  report_info "cuos:update:not_needed" "The system is up-to-date"
  raise_info 22 "No new image version available (post). Exiting."
fi

rm -Rf /next /prev
mkdir -p /next

CONTAINER="$(docker create "${IMAGE_VERSION}")"
if ! docker export "${CONTAINER}" | (cd /next && tar xf -); then
  raise 44 "Failed to export the container"
fi
docker rm "${CONTAINER}" \
  || raise 45 "Failed to remove the container"

cd /next || exit 127
rm -Rf .dockerenv sys dev proc data
cd / || exit 127

chroot /next /usr/local/cuos/first-run.sh "${SLOT}" "${IMAGE_VERSION}" "${NEW_DIGEST}" \
  || raise 46 "Failed to run first-run script in container"

if [[ -d "/next${SCRIPT_DIR}/lxc-swaproot/" ]]; then
  cp -R "/next${SCRIPT_DIR}/lxc-swaproot/" /swaproot/ \
    || raise 47 "Failed to copy swaproot scripts"
else
  cp -R "${SCRIPT_DIR}/lxc-swaproot/" /swaproot/ \
    || raise 48 "Failed to copy swaproot scripts"
fi
if [[ -f "/next/bin/busybox" ]]; then
  cp /next/bin/busybox /swaproot/ \
    || raise 49 "Failed to copy busybox"
else
  cp /bin/busybox /swaproot/ \
    || raise 50 "Failed to copy busybox"
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

