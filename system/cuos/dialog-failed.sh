#!/bin/bash

set -x

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

export DIALOGRC="${SCRIPT_DIR}/dialog.rc"
VIRT_TYPE="$(systemd-detect-virt)"

term() {
	TERM=linux "$@" >/dev/tty1 </dev/tty1
}

LEVEL_logger="err"
LEVEL="ERROR"
if [[ "$1" == "CRITICAL" ]]; then
	LEVEL_logger="crit"
	LEVEL="CRITICAL"
	shift

fi
MESSAGE="$1"

logger -t cuos -p "${LEVEL_logger}" "${MESSAGE}"


jq -nc \
	--arg msg "${MESSAGE}" \
	--arg level "${LEVEL}" \
	'{"date": (now | todate), "level": $level, "message": $msg}' >>/data/reports.json
if [ "$(wc -l < /data/reports.json)" -gt 1000 ]; then
	tail -n 1000 /data/reports.json > /data/reports.json.cut && \
	mv /data/reports.json.cut /data/reports.json
fi

if [[ "${VIRT_TYPE}" = "lxc" ]]; then
	# Dont show dialogs for lxc
	exit 0
fi

DISPLAY_MESSAGE="$(date)

${MESSAGE}"

DIALOG_MESSAGE="$(echo "${DISPLAY_MESSAGE}" | sed ':a;N;$!ba;s/\n/\\n/g')"

term dialog --title "Message" --infobox "$DIALOG_MESSAGE" 20 55

