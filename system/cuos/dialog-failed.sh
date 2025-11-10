#!/bin/bash

set -x

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

export DIALOGRC="${SCRIPT_DIR}/dialog.rc"
VIRT_TYPE="$(systemd-detect-virt)"
if [[ "${VIRT_TYPE}" == "lxc" || "${VIRT_TYPE}" == "docker" ]]; then
  # Dont show dialogs for lxc
  exit 0
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

chvt 43

term() {
  TERM=linux "$@" >/dev/tty43 </dev/tty43
}


MESSAGE="$1"

DISPLAY_MESSAGE="$(date)

${MESSAGE}"

DIALOG_MESSAGE="$(echo "${DISPLAY_MESSAGE}" | sed ':a;N;$!ba;s/\n/\\n/g')"

term dialog --title "Message" --infobox "$DIALOG_MESSAGE. System will reboot in 30sec" 20 55
        sleep 10
term dialog --title "Message" --infobox "$DIALOG_MESSAGE. System will reboot in 20sec" 20 55
        sleep 10
term dialog --title "Message" --infobox "$DIALOG_MESSAGE. System will reboot in 10sec" 20 55
        sleep 10
term dialog --title "Message" --infobox "$DIALOG_MESSAGE. System will reboot now" 20 55

sync
reboot
