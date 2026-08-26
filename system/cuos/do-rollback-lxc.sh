#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

set -x

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

CURRENT_SLOT="$(cat "/etc/active_slot" 2>/dev/null || echo "A")"
SLOT="A"
if [[ "${CURRENT_SLOT}" == "A" ]]; then
    SLOT="B"
fi

REASON="$1"
"${SCRIPT_DIR}/dialog.sh" "CRITICAL: Perfoming Rollback to slot ${SLOT}: ${REASON}"

# set update state: Rollback because of ${REASON}"
state '.state' 'rollback'
state jq '.last_update_date = (now | todate)'
state '.update_state' "rollback to slot ${SLOT} (${REASON})"

rm -Rf /swaproot
cp -R "${SCRIPT_DIR}/lxc-swaproot/" /swaproot/ \
	|| raise "Failed to copy swaproot scripts"
cp /bin/busybox /swaproot/ \
	|| raise "Failed to copy busybox"

mv /sbin/init /sbin/init-old
cat <<EOF >/sbin/init
#!/swaproot/busybox sh

/swaproot/busybox sh /swaproot/swap_rollback.sh
cd /
exec /sbin/init
EOF
chmod a+x /sbin/init

sync

echo "Rebooting ..."
reboot
