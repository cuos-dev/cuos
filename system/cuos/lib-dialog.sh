#!/bin/bash

export DIALOGRC="${SCRIPT_DIR}/dialog.rc"

VIRT_TYPE="$(systemd-detect-virt)"
if [[ "${VIRT_TYPE}" == "lxc" ]]; then
  exit 0
fi

cuos() {
  [[ -n "${TEST:-}" ]] && return
  "${SCRIPT_DIR}/api.sh" "$@"
}
export -f cuos

CUOS_VERSION="$(cuos version)"
CUOS_VERSION="${CUOS_VERSION/*\//}"

term() {
  if [[ -n "${TEST:-}" ]]; then "$@"; return; fi
  TERM=linux "$@" >/dev/tty42 </dev/tty42
}
term_all() {
  if [[ -n "${TEST:-}" ]]; then "$@"; return; fi
  TERM=linux "$@" >/dev/tty42 2>/dev/tty42 </dev/tty42
}
term_output() {
  if [[ -n "${TEST:-}" ]]; then "$@"; return; fi
  TERM=linux "$@" >/dev/tty42
}

cuos_dialog() {
  dialog \
    --colors \
    --no-trim \
    --no-collapse \
    --erase-on-exit \
    --cursor-off-label \
    --cr-wrap \
    --backtitle "Version: ${CUOS_VERSION}" \
    "$@"
}


change_vt() {
  #alternative: TERM=linux setsid -w openvt -s -e -w -- dialog --clear --yesno Hi 6 40
  if [[ -z "${TEST:-}" && -z "${DIALOG_SUB:-}" ]]; then
    export DIALOG_SUB=1

    VT_OLD="$(fgconsole)"
    chvt 42

    # shellcheck disable=SC2317
    function finish {
      chvt "${VT_OLD}"
      deallocvt 42
    }
    trap finish EXIT
  fi
}


fmenu() {
  term cuos_dialog \
    --clear \
    --no-cancel \
    --cancel-label "Back" \
    --no-hot-list \
    --no-tags \
    --title "$1" \
    --cancel-label "Back" \
    --menu "$2" "${3:-15}" "${4:-72}" "${5:-8}" \
    "${@:6}" \
    3>&1 1>&2 2>&3
}
msg() {
  term cuos_dialog \
    --title "${2:-Info}" \
    --msgbox "$1" "${3:-9}" "${4:-70}"
}
input() {
  term cuos_dialog \
    --title "${3:-Input}" \
    --inputbox "$1" "${4:-9}" "${5:-70}" "${2:-}" \
    3>&1 1>&2 2>&3
}
prgbox(){
  term cuos_dialog \
    --title "${2:-}" \
    --scrollbar \
    --prgbox logs "$1" "${3:-22}" "${4:-90}"
}
pwbox() {
  term cuos_dialog \
    --title "${2:-Password}" \
    --insecure \
    --passwordbox "$1" "${3:-9}" "${4:-70}" 3>&1 1>&2 2>&3
}

api_stream() {
  # Stream API output in prgbox
  # Usage: api_stream <title> <action> [args...]
  local title="$1"; shift
  prgbox "$*" "$title" 22 90
}

api_stream_size() {
  # Stream API output in prgbox
  # Usage: api_stream <title> <h> <w> <action> [args...]
  local title="$1"; shift
  local h="$1"; shift
  local w="$1"; shift
  prgbox "$*" "$title" "$h" "$w"
}

yesno() {
  term cuos_dialog \
    --title "${2:-Confirm}" \
    --yesno "$1" "${3:-9}" "${4:-70}"
}

valid_hostname() {
  local h="$1"
  [[ -n "$h" && ${#h} -le 253 ]] || return 1
  IFS='.' read -ra labels <<< "$h"
  [[ ${#labels[@]} -ge 1 ]] || return 1
  for lbl in "${labels[@]}"; do
    [[ ${#lbl} -ge 1 && ${#lbl} -le 63 ]] || return 1
    [[ "$lbl" =~ ^[A-Za-z0-9-]+$ ]] || return 1
  done
  return 0
}

valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for n in $a $b $c $d; do
    (( n >= 0 && n <= 255 )) || return 1
  done
  return 0
}



if [[ -n "${TEST:-}" && "$(uname)" = "Darwin" ]]; then
  sed() {
    gsed "$@"
  }
fi
