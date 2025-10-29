#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-dialog.sh"

dialog_reports_header() {
  cat <<EOF

## Operating System started successfully.

Host: $(hostname)
Start Time:  $(jq -r '.start_date | sub("T"; " ") | sub("Z"; " UTC")' /data/state.json)
Last Update: $(jq -r '.last_update_date | sub("T"; " ") | sub("Z"; " UTC")' /data/state.json)

## Reports

EOF

}

if [[ -f "${SCRIPT_DIR}/custom-dialog.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/custom-dialog.sh"
fi

change_vt

# open subshell for own trap
(
  # shellcheck disable=SC2317
  cleanup() {
    [[ -n "${tmpfile}" ]] && rm -f "$tmpfile"
  }
  trap cleanup EXIT

  tmpfile=$(mktemp)
  dialog_reports_header >"$tmpfile"

  journalctl \
    --identifier=cuos \
    --merge \
    --follow \
    --lines=10 \
    --boot=all \
    --no-pager \
    --output=json | jq --unbuffered -r '
    . as $e |
      (if ($e.MESSAGE | test("^cuos:init:start")) then "\n" else "" end) +
      (($e.__REALTIME_TIMESTAMP | tonumber) / 1000000 | strflocaltime("%Y-%m-%d %H:%M:%S")) +
      " " +
      (["[emerg] ","[alert] "," [crit] "," [err]  ","[warning]","[notice]"," [info] ","[debug] "][$e.PRIORITY | tonumber]) +
      " " +
      $e.MESSAGE | sub("^cuos:[a-z:_-]+ "; "")
  ' >> "$tmpfile" &
  JOURNAL_PID=$!

  term cuos_dialog \
    --exit-label "Intervention: Start configuration (hit enter)" \
    --tailbox "$tmpfile" 40 100
  EXIT_CODE_DIALOG="$?"

  kill "$JOURNAL_PID"
  rm -f "$tmpfile"

  if [[ "${EXIT_CODE_DIALOG}" == "0" ]]; then
    "${SCRIPT_DIR}/dialog-maintenance.sh"
    term dialog --clear
    sleep 1
  else
    sleep 5
  fi
)

exec "$0"
