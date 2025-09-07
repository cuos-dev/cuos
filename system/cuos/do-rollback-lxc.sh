#!/bin/bash

set -x

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

CURRENT_PARTITION="$(cat "/etc/partition_mode" 2>/dev/null || echo "A")"
PARTITION="A"
if [[ "${CURRENT_PARTITION}" == "A" ]]; then
    PARTITION="B"
fi

REASON="$1"
"${SCRIPT_DIR}/dialog.sh" "CRITICAL: Perfoming Rollback to partition ${PARTITION}: ${REASON}"

# set update state: Rollback because of ${REASON}"
state '.state' 'rollback'
state jq '.last_update_date = (now | todate)'
state '.update_state' "rollback to partition ${PARTITION} (${REASON})"


cp -R "${SCRIPT_DIR}/lxc-swaproot/" /swaproot/ \
	|| raise "Failed to copy swaproot scripts"
cp /bin/busybox /swaproot/ \
	|| raise "Failed to copy busybox"

mv /sbin/init /sbin/init-old
cat <<EOF >/sbin/init
#!/swaproot/busybox sh

/swaproot/swap_rollback.sh
cd /
exec /sbin/init
EOF
chmod a+x /sbin/init

sync

echo "Rebooting ..."
reboot
