#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-dialog.sh"

change_vt

# open subshell for own trap
(
  cleanup() {
    [[ -n "${tmpfile}" ]] && rm -f "$tmpfile"
  }
  trap cleanup EXIT

  tmpfile=$(mktemp)

  journalctl \
    --identifier=cuos \
    --merge \
    --follow \
    --lines=20 \
    --boot=all \
    --no-pager \
    --output=json | jq --unbuffered -r '
    . as $e
    | (($e.__REALTIME_TIMESTAMP | tonumber) / 1000000 | strflocaltime("%Y-%m-%d %H:%M:%S")) + " [" +
      (["emerg","alert","crit","err","warning","notice","info","debug"][$e.PRIORITY | tonumber]) + "] " +
      $e.MESSAGE
  ' > "$tmpfile" &
  JOURNAL_PID=$!

  term cuos_dialog \
    --title "System Reports: $(hostname)" \
    --exit-label "Intervention: Start configuration" \
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
