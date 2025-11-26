#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-dialog.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dialog-keyboard.sh"

CONFIG_PATH="${CONFIG_PATH:-"/system.json"}"
if [[ -n "${TEST:-}" ]]; then
  CONFIG_PATH="system.json"
fi


# Load initial config into a variable
CONFIG_JSON="$(cat "$CONFIG_PATH" || echo '{}')"
CONFIG_NEW="{}"

# --- Validation functions ---
is_valid_hostname() {
  [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9\.-]+$ ]]
}

is_valid_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && \
  for octet in $(echo "$1" | tr '.' ' '); do
    [[ "$octet" -ge 0 && "$octet" -le 255 ]] || return 1
  done
}

is_valid_ips() {
  [[ -z "$1" ]] && return 1
  for ip in $1; do
    is_valid_ip "${ip}" || return 1
  done
  return 0
}

is_valid_name_or_ip() {
  is_valid_hostname "$@" || is_valid_ip "$@"
}

is_valid_names_or_ips() {
  [[ -z "$1" ]] && return 1
  for ip in $1; do
    is_valid_name_or_ip "${ip}" || return 1
  done
  return 0
}

edit() {
  local field="$1"
  local displayname="$2"
  local check_function="$3"

  local value
  value="$(echo "$CONFIG_JSON" | jq -r "${field} // \"\"")"
  while true; do
    if ! value="$(input \
        "${displayname}: " \
        "${value}" \
        "Network configuration" \
        9 60)"; then
      return 1
    fi
    if [[ -z "${check_function}" ]] || "${check_function}" "${value}"; then
      CONFIG_NEW="$(echo "${CONFIG_NEW}" | jq --arg val "${value}" "${field}"' = $val')"
      CONFIG_JSON="$(echo "${CONFIG_JSON}" | jq --arg val "${value}" "${field}"' = $val')"
      return 0
    fi
    term cuos_dialog --no-cancel --msgbox "Invalid format. Please try again." 8 40
  done
}

question() {
  local field="$1"
  local displayname="$2"
  local default="${3:-''}"

  local value
  value="$(echo "$CONFIG_JSON" | jq -r "${field}")"
  if [[ "${value}" == "null" ]]; then
    value="${default}"
  fi
  local choise="--clear" # for nop
  if [[ "${value}" != "true" ]]; then
    choise="--defaultno"
  fi
  local newvalue=false
  if term cuos_dialog "${choise}" --yesno "${displayname}" 7 40; then
    newvalue=true
  fi
  CONFIG_NEW="$(echo "$CONFIG_NEW" | jq "${field} = ${newvalue}")"
  CONFIG_JSON="$(echo "$CONFIG_JSON" | jq "${field} = ${newvalue}")"

  [[ "${newvalue}" == "true" ]]
}

confirm_save() {
  if ! term cuos_dialog --clear --yesno "Do you want to save and load the configuration?\n\n${CONFIG_NEW}" 25 50; then
    exit 1
  fi
}

edit_hostname() {
  edit '.hostname' "Hostname (FQDN)" is_valid_hostname || exit 1
}
edit_network() {
  # Number of interfaces
  NUM_IFACES=1

  # Loop through interfaces
  for ((i=0; i<NUM_IFACES; i++)); do
    if ! question '.network['"$i"']["dhcp"]' "Configure network via DHCP?" true; then
      edit '.network['"$i"']["ip-address"]' "IP address" is_valid_ip || exit 1
      edit '.network['"$i"']["network-mask"]' "Network mask" is_valid_ip || exit 1
      edit '.network['"$i"']["gateway"]' "Gateway" is_valid_ip || exit 1
      edit '.network['"$i"']["dns-server"]' "DNS server(s)" is_valid_ips || exit 1
      edit '.network['"$i"']["ntp"]' "NTP server(s)" is_valid_names_or_ips || exit 1
    fi
  done
}

save_configuration() {
  # Save to new config
  echo "${CONFIG_JSON}" >"${CONFIG_PATH}" || exit 1
}

apply_configuration_hostname() {
  if [[ -n "${TEST:-}" ]]; then return; fi
  "${SCRIPT_DIR}/init.sh" --reinit set_hostname
}
apply_configuration_network() {
  if [[ -n "${TEST:-}" ]]; then return; fi
  "${SCRIPT_DIR}/init.sh" --reinit configure_network
}

main_edit_network() {
  edit_network
  confirm_save

  save_configuration
  apply_configuration_network
}
main_edit_hostname() {
  edit_hostname

  save_configuration
  apply_configuration_hostname
}


dialog_edit_network_main() {
  MODE="${1:-""}"

  if [[ "${MODE}" == "hostname" ]]; then
    main_edit_hostname
  elif [[ "${MODE}" == "network" ]]; then
    main_edit_network
  else
    echo "Unknown mode: ${MODE}"
  fi
}

if [[ -f "${SCRIPT_DIR}/custom-dialog.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/custom-dialog.sh"
fi

dialog_edit_network_main "$@"
