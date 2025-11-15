#!/bin/bash

set -uo pipefail

get_keyboard() {
  if [[ -n "${TEST:-}" ]]; then echo "us"; return; fi
  jq_config -r '.keyboard_layout // "us"'
}

choose_keyboard() {
  local layout
  layout="$(get_keyboard)"

  local layouts
  layouts=( "US us" "UK gb" "German de" "French fr" "Spanish es" "Italian it" "Portuguese pt" "Swiss ch" "Russian ru" "Japanese jp" )

  local ITEMS=()
  for e in "${layouts[@]}"; do
    label="${e%% *}"
    code="${e##* }"
    ITEMS+=("$code" "$label")
  done

  layout="$(fmenu \
    "Keyboard Layout" \
    "Select console keyboard layout" \
    20 55 7 \
    "${ITEMS[@]}")" || return 0

  if [[ -n "${TEST:-}" ]]; then return; fi

  jq_replace \
    --arg layout "${layout}" \
    '.keyboard_layout = $layout' \
    "${CONFIG_PATH}" || return 1

  "${SCRIPT_DIR}/init.sh" --reinit configure_keyboard
}

