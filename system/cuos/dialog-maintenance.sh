#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-dialog.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dialog-keyboard.sh"


maintenance_menu() {
  while true; do
    local ipaddress
    ipaddress="$(ip -4 addr show | awk '/inet/ && !/127.0.0.1/ {print $2}' | head -n1)"
    ipaddress="${ipaddress:-"Offline"}"
    local choice
    choice="$(fmenu \
      "System Maintenance" \
      "\nSelect an option:\n " \
      20 55 7 \
      "host" "Change Hostname: $(hostname -s)" \
      "net" "Configure Network${ipaddress:+": ${ipaddress}"}" \
      - " " \
      "act" "System Actions" \
      "diag" "Diagnostics" \
      - " " \
      "exit" "\Z5Exit Menu\Z0")" || return 1
    #"pass" "Change Admin Password"
    case "$choice" in
      host)
        "${SCRIPT_DIR}/dialog-edit-network.sh" hostname ;;
      net)
        "${SCRIPT_DIR}/dialog-edit-network.sh" network ;;
      act)  system_actions_menu ;;
      diag) diagnostics_menu ;;
      exit|"") break ;;
    esac
  done
}

install_menu() {
  local extra
  extra=()
  if [[ "${1:-}" =~ ^.*admin.*$ ]]; then
    extra+=("pass" "Change Administrator Password")
  fi
  while true; do
    local ipaddress
    ipaddress="$(ip -4 addr show | awk '/inet/ && !/127.0.0.1/ {print $2}' | head -n1)"
    ipaddress="${ipaddress:-"Offline"}"
    local choice
    choice="$(fmenu \
      "System Installation" \
      "\nSelect an option:\n " \
      20 55 7 \
      "${extra[@]+"${extra[@]}"}" \
      "host" "Change Hostname: $(hostname -s)" \
      "net" "Configure Network${ipaddress:+": ${ipaddress}"}" \
      - " " \
      "act" "System Actions" \
      "diag" "Diagnostics" \
      - " " \
      "exit" "\Z5Continue Installation\Z0")" || return 1
    case "$choice" in
      check) system_qualification_dialog ;;
      net)
        "${SCRIPT_DIR}/dialog-edit-network.sh" network ;;
      host)
        "${SCRIPT_DIR}/dialog-edit-network.sh" hostname ;;
      pass) change_admin_password ;;
      act)  system_actions_menu_installation ;;
      diag) diagnostics_menu ;;
      exit|"") break ;;
    esac
  done
}


hash_admin_password() {
  local password="$1"
  local saltlen=8
  local salt
  salt="$(head -c "$saltlen" /dev/urandom)"

  local pwhash
  pwhash="$(printf "%s" "$password" | cat - <(printf "%s" "$salt") | openssl dgst -sha1 -binary)"

  local ssha
  ssha="$(printf "%s%s" "$pwhash" "$salt" | base64)"

  echo "{SSHA}$ssha"
}

change_admin_password() {
  local p1 p2
  while true; do
    p1="$(pwbox "Enter a new password (Beware the keyboard layout):" "Administrator Password" 10 70)" || return 1
    p2="$(pwbox "Confirm password:" "Administrator Password" 10 70)" || return 1
    if [[ "$p1" != "$p2" ]]; then
      msg "Passwords do not match. Please try again." "Password"
      continue
    fi
    if [[ ${#p1} -lt 8 ]]; then
      msg "Password too short. Minimum 8 characters." "Password"
      continue
    fi
    (
      set +x
      jq_replace \
        --arg password "$(hash_admin_password "$p1")" \
        '.system_admin_password = $password' \
        "${CONFIG_PATH}"
    )
    msg "Administrator password set." "Password"
    return 0
  done
}

system_actions_menu() {
  while true; do
    local choice
    choice="$(fmenu "System Actions" "Select an action:" 17 72 10 \
      "reboot" "Reboot System" \
      "shutdown" "Shutdown System" \
      - " " \
      "update" "Trigger System Update" \
      "rollback" "Rollback Last Update (OS only)" \
      "expand" "Expand Filesystem" \
      "factory" "Factory Reset" \
      - " " \
      "back" "\Z5Back\Z0")" || return 1
    case "$choice" in
      reboot) system_reboot ;;
      shutdown) system_shutdown ;;
      update) system_update ;;
      rollback) system_rollback ;;
      expand) system_expand_fs ;;
      factory) system_factory_reset ;;
      back|"") return 0 ;;
    esac
  done
}

system_actions_menu_installation() {
  while true; do
    local choice
    choice="$(fmenu "System Actions" "Select an action:" 17 72 10 \
      "shutdown" "Shutdown System" \
      "update" "Trigger System Update" \
      "expand" "Expand Filesystem" \
      - " " \
      "back" "\Z5Back\Z0")" || return 1
    case "$choice" in
      shutdown) system_shutdown ;;
      update) system_update ;;
      expand) system_expand_fs ;;
      back|"") return 0 ;;
    esac
  done
}

system_reboot() {
  if yesno "Are you sure you want to reboot now?" "Reboot" 8 52; then
    cuos reboot
  fi
}
system_shutdown() {
  if yesno "Are you sure you want to shutdown now?" "Shutdown" 8 52; then
    cuos shutdown
  fi
}

system_update() {
  if ! yesno "Trigger system update?\n\nThis may take several minutes to complete and the system may reboot automatically." "System Update" 11 70; then
    return
  fi
  api_stream "Applying System Update" cuos trigger-update
}

system_rollback() {
  if ! yesno "Rollback last update of the operating system?\n\nThe system will boot into the previous slot. User data will not be affected" "Rollback" 11 72; then
    return
  fi
  api_stream "Preparing Rollback" cuos rollback
}

system_expand_fs() {
  api_stream "Expand file system" cuos patch
}

system_factory_reset() {
  local confirm
  confirm=$(DIALOGRC="${SCRIPT_DIR}/dialog-red.rc" term cuos_dialog --title "Factory Reset" --inputbox "This will reset the system to factory defaults.\nAll configuration and local data will be lost.\n\nType RESET to confirm." 13 72 3>&1 1>&2 2>&3) || return 1
  if [[ "$confirm" != "RESET" ]]; then msg "Confirmation text mismatch. Aborted." "Factory Reset"; return 1; fi
  api_stream "Factory Reset" cuos factory-reset
}

diagnostics_menu() {
  while true; do
    local choice
    choice="$(fmenu "Diagnostics" "Choose a diagnostic tool:" 17 72 10 \
      "resources" "View System Resources" \
      "clogs" "View CuOS Logs" \
      "logs" "View System Logs" \
      - " " \
      "ping" "Tool: Ping Test" \
      "dns" "Tool: DNS Resolution Test" \
      "docker" "Tool: docker ps" \
      "expert" " " \
      "back" "\Z5Back\Z0")" || return 1
    case "$choice" in
      resources) check_resources ;;
      clogs) term_all cuos_logs ;;
      logs) term_all view_logs ;;
      docker) api_stream_size "docker ps" 30 120 docker ps ;;
      ping) diagnostics_ping ;;
      dns) diagnostics_dns ;;
      "expert") expert ;;
      back|"") return 0 ;;
    esac
  done
}

check_resources() {
  local resources
  resources="$("${SCRIPT_DIR}/dialog-get-resources.sh" 2>&1)"
  msg "${resources}" "System Resources" 40 120
}

cuos_logs() {
  (
    echo -e "\033[1;36m[ Log View - Press 'Q' to quit the view ]\033[0m";
    SYSTEMD_COLORS=true journalctl \
      --identifier=cuos \
      --priority="emerg..info" \
      --lines=2000 \
      --output=short \
      --no-hostname \
      --no-pager
  ) | \
    LESSSECURE=1 less \
      --header=1,0 \
      -R \
      +G
}

view_logs() {
  (
    echo -e "\033[1;36m[ Log View - Press 'Q' to quit the view ]\033[0m";
    SYSTEMD_COLORS=true journalctl \
      --priority="emerg..info" \
      --lines=10000 \
      --output=short \
      --no-hostname \
      --no-pager
  ) | \
    LESSSECURE=1 less \
      --header=1,0 \
      -R \
      +G
}

diagnostics_ping() {
  local tgt
  tgt="$(input "Enter target to ping:" "8.8.8.8" "Ping Test" 9 60)" || return 1
  valid_ipv4 "$tgt" || valid_hostname "$tgt" || { msg "Invalid IP address or hostname"; return 1; }
  api_stream "Ping" ping -c 4 "$tgt"
}
diagnostics_dns() {
  local hn
  hn="$(input "Enter hostname to resolve:" "cuos.dev" "DNS Test" 9 60)" || return 1
  valid_hostname "$hn" || { msg "Invalid hostname"; return 1; }
  api_stream "DNS resolve" "getent ahosts $hn && echo DNS resolution successful. || echo DNS resolution failed."
}

expert() {
  local console_expert_password
  console_expert_password="$(jq_config '.console_expert_password')"
  console_expert_password="${console_expert_password:-"CuOS"}"
  local confirm
  confirm=$(DIALOGRC="${SCRIPT_DIR}/dialog-red.rc" term cuos_dialog --title "Expert Settings" --insecure --passwordbox "You found the hidden expert settings.\nOnly continue, when you know what you are doing." 13 72 3>&1 1>&2 2>&3) || return 1
  if [[ "$confirm" != "${console_expert_password}" ]]; then msg "Aborted." "Expert Settings"; return 1; fi
  cp "/system.json" /tmp/edit-system.json
  chown nobody:nogroup /tmp/edit-system.json
  term_all sudo -u nobody rvim /tmp/edit-system.json
  if ! jq . /tmp/edit-system.json >/dev/null 2>&1; then
    term msg "Invalid JSON"
  elif ! check_config < /tmp/edit-system.json; then
    term msg "Invalid Configuration"
  else
    cat /tmp/edit-system.json >/system.json
    api_stream "Applying system.json" cuos patch
  fi
  rm -f /tmp/edit-system.json
}


if [[ -f "${SCRIPT_DIR}/custom-dialog.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/custom-dialog.sh"
fi


if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  true
elif [[ "${1:-}" == "--install" ]]; then
  change_vt
  shift
  install_menu "$@"
  sleep 1
elif [[ -n "${1:-}" && "$(type -t "${1}")" == "function" ]]; then
  "${@}"
  exit "$?"
else
  change_vt
  maintenance_menu "$@"
fi

