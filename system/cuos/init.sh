#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

export CONFIG_PATH="/system.json"
VIRT_TYPE="$(systemd-detect-virt)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

ensure_docker_config_json() {
  mkdir -p /data/root/
  rm -Rf /root
  ln -sf /data/root /root

  mkdir -p /data/.docker
  ln -sf /data/.docker /root/.docker
  rmdir /root/.docker/config.json 2>/dev/null && \
    echo "Warning: deleted config.json as dir"
  if [[ ! -f "/root/.docker/config.json" ]]; then
    echo "{}" >"/root/.docker/config.json"
  fi
}

ensure_system_config() {
  # Exec first-run if not yet started. E.g. for testing in docker containers.
  if [[ ! -f "/etc/partition_mode" ]]; then
    "${SCRIPT_DIR}/first-run.sh" "A" "unknown" "unknown"
  fi

  if [[ -f "${CONFIG_PATH}" ]]; then
    return
  fi
  if [[ "${VIRT_TYPE}" == "lxc" || "${VIRT_TYPE}" == "docker" ]]; then
    cat "/system_init.json" >"${CONFIG_PATH}"
  else
    mkdir -p "/mnt/boot"
    mount -o ro -t vfat LABEL=boot "/mnt/boot"
    if [[ -f "/mnt/boot/system.json" ]]; then
      report_info "cuos:init:system-json" "Found system.json for system configuration"
      if ! jq . "/mnt/boot/system.json" >/dev/null 2>&1; then
        report_alert "cuos:init:invalid_system_json" "Provided system.json file is invalid. System will reboot in 30sec"
        "${SCRIPT_DIR}/dialog-failed.sh" "Provided system.json file is invalid"
        sync
        /sbin/reboot
      fi
      cat "/mnt/boot/system.json" >"${CONFIG_PATH}"
    else
      cat "${SCRIPT_DIR}/system-default.json" >"${CONFIG_PATH}"
    fi

    # Grab system.json from installer image
    mkdir -p "/mnt/installer"
    mount -o ro LABEL=CUOS "/mnt/installer/"
    if [[ -f "/mnt/installer/system.json" ]]; then
      report_info "cuos:init:system-json-installer" "Found system.json on Installer, merging with system.json from system"
      if ! NEW_CONFIG="$(jq -s '.[0] + .[1]' \
        "${CONFIG_PATH}" "/mnt/installer/system.json")"; then

        report_alert "cuos:init:invalid_installer_system_json" "Provided system.json on Installer is invalid. System will reboot in 30sec"
        "${SCRIPT_DIR}/dialog-failed.sh" "Provided system.json file on Installer is invalid"
        sync
        /sbin/reboot

      fi
      echo "${NEW_CONFIG}" >"${CONFIG_PATH}"
    fi
    umount "/mnt/installer"

    # Grab Cloud Init data from boot dir
    umount "/mnt/boot"
    if [[ -f "/mnt/boot/user-data" ]]; then
      report_info "cuos:init:cloud-init" "Found Cloud Init user-data on boot, merging with system.json"
      if ! NEW_CONFIG="$("${SCRIPT_DIR}/cloud-init-to-system-json.sh" "/mnt/boot/user-data" "/mnt/boot/network-config" | \
        jq -s '.[0] + .[1]' \
        "${CONFIG_PATH}" -)"; then

        report_alert "cuos:init:invalid_cloud_init" "Provided cloud-init file is invalid. System will reboot in 30sec"
        "${SCRIPT_DIR}/dialog-failed.sh" "Provided cloud-init file is invalid"
        sync
        /sbin/reboot

      fi
      echo "${NEW_CONFIG}" >"${CONFIG_PATH}"
    fi

    # Grab Cloud Init data if available
    mkdir -p "/mnt/cidata"
    mount -o ro LABEL=cidata "/mnt/cidata/"
    if [[ -f "/mnt/cidata/user-data" ]]; then
      report_info "cuos:init:cloud-init" "Found Cloud Init user-data, merging with system.json"
      if ! NEW_CONFIG="$("${SCRIPT_DIR}/cloud-init-to-system-json.sh" "/mnt/cidata/user-data" "/mnt/cidata/network-config" | \
        jq -s '.[0] + .[1]' \
        "${CONFIG_PATH}" -)"; then

        report_alert "cuos:init:invalid_cloud_init" "Provided cloud-init file is invalid. System will reboot in 30sec"
        "${SCRIPT_DIR}/dialog-failed.sh" "Provided cloud-init file is invalid"
        sync
        /sbin/reboot

      fi
      echo "${NEW_CONFIG}" >"${CONFIG_PATH}"
    fi
    umount "/mnt/cidata"

    if ! check_schema_system_json; then
      report_alert "cuos:init:invalid_system_json" "Provided system.json file is invalid. System will reboot in 30sec"
      "${SCRIPT_DIR}/dialog-failed.sh" "Provided system.json file is invalid"
      sync
      /sbin/reboot
    fi
  fi
}

check_schema_system_json() {
  jv "${SCRIPT_DIR}/system-schema.json" "/system.json"
}

prepare_data_volume() {
  systemd-machine-id-setup
  mkdir -p /data/{docker,containerd,dhcp,log,shieldor,.docker}
  mkdir -p /data/log/journal
  chattr -R +C /data/log/journal
  chown -R root:systemd-journal /data/log/journal
  chmod 2755 /data/log/journal
  journalctl --flush
  if [[ ! -f /data/log/lastlog ]]; then
    touch /data/log/lastlog
    chgrp utmp /data/log/lastlog
    chmod 664 /data/log/lastlog
  fi
}

set_hostname() {
  OLD_HOSTNAME="$(cat /etc/hostname 2>/dev/null)"

  SYSTEM_HOSTNAME="$(jq_config '.hostname // empty')"
  if [[ -z "${SYSTEM_HOSTNAME}" && -z "${OLD_HOSTNAME}" ]]; then
      local r1 r2
      r1=$(printf "%02X" $(( RANDOM % 256 )))
      r2=$(printf "%02X" $(( RANDOM % 256 )))
      SYSTEM_HOSTNAME="device-${r1}${r2}"
      jq_replace \
        --arg hn "${SYSTEM_HOSTNAME}" \
        '.hostname = $hn' \
        "${CONFIG_PATH}"
      hostname "$SYSTEM_HOSTNAME"
  elif [[ -n "${SYSTEM_HOSTNAME}" ]]; then
    echo "Setting hostname to $SYSTEM_HOSTNAME"
    echo "$SYSTEM_HOSTNAME" > "/etc/hostname"
    hostname "$SYSTEM_HOSTNAME"
  elif [[ -n "${OLD_HOSTNAME}" ]]; then
      jq_replace \
        --arg hn "${OLD_HOSTNAME}" \
        '.hostname = $hn' \
        "${CONFIG_PATH}"
  fi
  if [[ -n "${REINIT:-}" && "${OLD_HOSTNAME}" != "${SYSTEM_HOSTNAME}" ]]; then
    systemctl restart networking
  fi
}

# Helper to convert dotted netmask to prefix length (e.g. 255.255.255.0 -> 24)
mask_to_prefix() {
  local m="$1"
  if [ -z "$m" ] || [ "$m" == "null" ]; then
    echo ""
    return
  fi
  # If already numeric return
  if [[ "$m" =~ ^[0-9]+$ ]]; then
    echo "$m"
    return
  fi
  # Validate dotted mask
  IFS='.' read -r o1 o2 o3 o4 <<< "$m"
  if [[ -z "$o1" || -z "$o2" || -z "$o3" || -z "$o4" ]]; then
    echo ""
    return
  fi
  local -i bits=0
  for oct in "$o1" "$o2" "$o3" "$o4"; do
    if ! [[ "$oct" =~ ^[0-9]+$ ]] || [ "$oct" -lt 0 ] || [ "$oct" -gt 255 ]; then
      echo ""
      return
    fi
    # convert to binary and count bits
    local bin
    bin=$(printf '%08d' "$(bc <<< "obase=2;$oct")" 2>/dev/null || true)
    # fallback if bc missing: use printf + awk (POSIX-friendly)
    if [ -z "$bin" ] || [ "$bin" = "00000000" ]; then
      # portable conversion
      bin=$(printf '%08d' "$(echo "obase=2;$oct" | bc)" 2>/dev/null || printf '%08d' "$oct")
    fi
    # Count ones
    local ones
    ones=$(echo -n "$bin" | tr -cd '1' | wc -c)
    bits=$((bits + ones))
  done
  echo "$bits"
}

configure_network() {
  local interfaces_file="${T_FILE_INTERFACES:-"/etc/network/interfaces"}"
  local interfaces_file_new="${T_FILE_INTERFACES_NEW:-"${interfaces_file}.new"}"

  if [[ "${VIRT_TYPE}" == "lxc" || "${VIRT_TYPE}" == "docker" ]]; then
    # For lxc the network is configured from outside
    return
  fi

  # Gather all non-lo, non-docker0 interfaces and sort them alphabetically
  shopt -s nullglob
  declare -a interfaces=()
  declare -A interfaces_mac=()

  local netdir="${T_DIR_SYS_CLASS_NET:-/sys/class/net}"

  # only ethernet interfaces, so not lo, docker0, wlan, bonds, br, veth, etc.
  for interface in "$netdir"/e*; do
    local name
    name="$(basename "$interface")"
    interfaces+=("$name")
    if [[ -r "$interface/address" ]]; then
      mac=$(<"$interface/address")
      interfaces_mac["$name"]=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
    else
      interfaces_mac["$name"]=""
    fi
  done


  # Read network config array from system.json using jq_config
  local configs_length
  configs_length="$(jq_config '.network | length')"

  declare -A used_json=()            # json_index → 1 when already assigned
  declare -A iface_to_json=()        # interface name → json_index
  declare -a remaining_json=()       # indices that are still free (preserve order)
  declare -a pending_ifaces=()       # interfaces that did NOT match name/MAC

  for ((i=0; i<${#interfaces[@]}; i++)); do
    local iface="${interfaces[$i]}"
    local match_idx=-1

    for ((j=0; j<configs_length; j++)); do
      (( used_json[$j] )) && continue   # already taken

      local entry entry_name entry_mac
      entry=$(jq_config -r ".network[$j]")
      entry_name=$(echo "$entry" | jq -r '.name // empty')
      entry_mac=$(echo "$entry" | jq -r '."mac-address" // empty' | tr '[:upper:]' '[:lower:]')

      if [[ -n "$entry_mac" && "$entry_mac" == "${interfaces_mac[$iface]}" ]]; then
        match_idx=$j; break
      elif [[ -z "$entry_mac" && -n "$entry_name" && "$entry_name" == "$iface" ]]; then
        match_idx=$j; break
      fi
    done

    if (( match_idx != -1 )); then
      used_json[$match_idx]=1
      # store the association for later stanza generation
      iface_to_json["$iface"]=$match_idx
    else
      # remember that this iface still needs a config (positional fallback)
      pending_ifaces+=("$iface")
    fi
  done

  # collect the indices that were not used
  for ((j=0; j<configs_length; j++)); do
    entry=$(jq_config -r ".network[$j]")
    entry_name=$(echo "$entry" | jq -r '.name // empty')
    entry_mac=$(echo "$entry" | jq -r '."mac-address" // empty' | tr '[:upper:]' '[:lower:]')

    if [[ -z "$entry_mac" && -z "$entry_name" ]]; then
      (( used_json[$j] )) || remaining_json+=("$j")
    fi
  done

  # assign them in order
  for ((k=0; k<${#pending_ifaces[@]}; k++)); do
    local iface="${pending_ifaces[$k]}"
    local idx="${remaining_json[$k]:-}"   # may be empty if JSON shorter
    [[ -n "${idx}" ]] && iface_to_json["$iface"]=$idx
  done

  {
    echo "auto lo"
    echo "iface lo inet loopback"
    echo

    # Configure eAch interface with corresponding config if present
    for ((i=0; i<${#interfaces[@]}; i++)); do
      local iface="${interfaces[$i]}"
      local metric=$((100 * (i+1)))
      local json_idx="${iface_to_json[$iface]:-}"

      # No JSON entry at all → original defaults (first iface DHCP, rest manual)
      if [[ -z "$json_idx" ]]; then
        if [[ -z "${!used_json[*]}" && "$i" == "0" ]]; then
          echo "auto $iface"
          echo "iface $iface inet dhcp"
          echo "    metric $metric"
          echo
        else
          echo "iface $iface inet manual"
          echo
        fi
        continue
      fi

      # Extract config for this interface
      local config
      config=$(jq_config -r ".network[$json_idx]")
      local dhcp
      dhcp=$(echo "$config" | jq -r '.dhcp // empty')
      local ip
      ip=$(echo "$config" | jq -r '."ip-address" // empty')
      local mask
      mask=$(echo "$config" | jq -r '."network-mask" // empty')
      local gw
      gw=$(echo "$config" | jq -r '.gateway // empty')
      local dns
      dns=$(echo "$config" | jq -r '
        if (."dns-server" | type == "array") then
          ."dns-server" | join(" ")
        else
          ."dns-server" // empty
        end')
      local ntp
      ntp=$(echo "$config" | jq -r '
        if (."ntp-server" | type == "array") then
          ."ntp-server" | join(" ")
        else
          ."ntp-server" // empty
        end')
      metric="$(echo "$config" | jq -r '.metric // empty')"
      metric="${metric:-"$((10 * (json_idx+1)))"}"
      if [ -z "$dhcp" ] && [ -z "$ip" ] && [ -z "$mask" ]; then
        # No config for this interface, skip it
        echo "iface $iface inet manual"
        echo
        continue
      fi
      if [ "$dhcp" = "true" ]; then
        # DHCP configuration with metric
        echo "auto $iface"
        echo "iface $iface inet dhcp"
        echo "    metric $metric"
        echo
      else
        # Static configuration
        echo "auto $iface"
        echo "iface $iface inet static"
        [ -n "$ip" ] && echo "    address $ip"
        [ -n "$mask" ] && echo "    netmask $mask"
        [ -n "$gw" ] && echo "    gateway $gw"
        [ -n "$dns" ] && echo "    dns-nameservers $dns"
        [ -n "$ntp" ] && echo "    ntp-servers $ntp"
        echo
      fi
      # Static routes
      if echo "$config" | jq -e 'has("routes")' >/dev/null 2>&1; then
        echo "$config" | jq -r '
          .routes // empty |
          (if type=="array" then .[] else . end) |
          (.network // "") as $d |
          (.gateway // "") as $g |
          (.netmask // "") as $m |
          [$d, $g, $m] | @tsv' |
        while IFS=$'\t' read -r RDEST RGW RMASK; do
          if [ -z "$RDEST" ] || [ -z "$RGW" ]; then
            echo "IGNORE: invalid route with empty destination or gateway" >&2
            continue
          fi
          PREFIX=$(mask_to_prefix "$RMASK")
          RDEST="$RDEST${PREFIX:+"/$PREFIX"}"
          echo "    up ip route add $RDEST via $RGW dev $iface"
          echo "    down ip route del $RDEST via $RGW dev $iface"
        done
      fi
    done
  } > "${interfaces_file_new}"

  if [[ -n "${TEST}" ]]; then return; fi

  if [[ -n "${REINIT:-}" && "$(sha256sum "${interfaces_file}" | cut -d ' ' -f1)" != "$(sha256sum "${interfaces_file_new}" | cut -d ' ' -f1)" ]]; then
    systemctl stop networking
    mv "${interfaces_file_new}" "${interfaces_file}"
    systemctl start networking
  else
    mv "${interfaces_file_new}" "${interfaces_file}"
  fi

}

configure_keyboard() {
  # For lxc we do not configure the keyboard
  if [[ "${VIRT_TYPE}" == "lxc" || "${VIRT_TYPE}" == "docker" ]]; then
    return
  fi
  local keyboard_config_file="${T_FILE_KEYBOARD:-"/etc/default/keyboard"}"

  local model
  model=$(jq_config -r '.keyboard_model // "pc105"')
  local layout
  layout=$(jq_config -r '.keyboard_layout // "us"')
  local variant
  variant=$(jq_config -r '.keyboard_variant // "AUTODETECT"')

  if [[ "${variant}" == "AUTODETECT" ]]; then
    variant=""
    if [[ "${layout}" == "us" ]]; then
      variant="intl"
    fi
    if [[ "${layout}" == "de" ]]; then
      variant="nodeadkeys"
    fi
    if [[ "${layout}" == "fr" ]]; then
      variant="oss"
    fi
  fi

  cat > "${keyboard_config_file}" <<EOF
# Managed by cuos/init.sh
XKBMODEL="$model"
XKBLAYOUT="$layout"
XKBVARIANT="$variant"
XKBOPTIONS=""
BACKSPACE="guess"
EOF

  DEBIAN_FRONTEND=noninteractive \
    dpkg-reconfigure -f noninteractive keyboard-configuration || true
  setupcon || true
}

set_root_password() {
  # Add ssh keys:
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  jq -r '.["os_root_authorized_keys"][]?' "/system.json" >/root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys

  local root_password
  root_password="$(jq_config -r '.os_root_password // empty')"

  if [[ -z "${root_password}" ]]; then
    usermod -L root
    return
  fi

  # Check if password looks like a hash (contains typical hash delimiters or is too long for a plain password)
  # Common hash formats: $1$ (MD5), $2a/$2y/$2b (bcrypt), $5$ (SHA-256), $6$ (SHA-512)
  if [[ "${root_password}" =~ ^\$[0-9a-z]+\$ ]] || [[ ${#root_password} -gt 50 ]]; then
    # Treat as hash - use chpasswd with -e flag for encrypted passwords
    echo "root:${root_password}" | chpasswd -e
  else
    # Treat as plain password - use chpasswd without -e flag
    echo "root:${root_password}" | chpasswd
  fi

  usermod -U root

  report_info "cuos:init:root_access" "Root access is enabled"
}

create_ssh_hostkey() {
  local SSH_PERSIST_DIR="/data/ssh-hostkeys"
  local SSH_CONFIG_DIR="/etc/ssh"

  mkdir -p "${SSH_PERSIST_DIR}"
  mkdir -p "${SSH_CONFIG_DIR}"
  chmod 700 "${SSH_CONFIG_DIR}"

  shopt -s nullglob
  local persisted_keys=("${SSH_PERSIST_DIR}"/ssh_host_*_key)

  if [ ${#persisted_keys[@]} -gt 0 ]; then
    # Restore keys from persistent storage
    report_info "cuos:init:ssh_hostkeys" "Restoring SSH host keys from ${SSH_PERSIST_DIR}"
    cp "${SSH_PERSIST_DIR}"/ssh_host_*_key "${SSH_CONFIG_DIR}/" 2>/dev/null || true
    cp "${SSH_PERSIST_DIR}"/ssh_host_*_key.pub "${SSH_CONFIG_DIR}/" 2>/dev/null || true
    chmod 600 "${SSH_CONFIG_DIR}"/ssh_host_*_key
    chmod 644 "${SSH_CONFIG_DIR}"/ssh_host_*_key.pub
  else
    # Generate new keys
    report_info "cuos:init:ssh_hostkeys" "Generating SSH host keys"
    ssh-keygen -A

    # Persist the newly generated keys
    report_info "cuos:init:ssh_hostkeys" "Persisting SSH host keys to ${SSH_PERSIST_DIR}"
    cp "${SSH_CONFIG_DIR}"/ssh_host_*_key "${SSH_PERSIST_DIR}/" 2>/dev/null || true
    cp "${SSH_CONFIG_DIR}"/ssh_host_*_key.pub "${SSH_PERSIST_DIR}/" 2>/dev/null || true
    chmod 600 "${SSH_PERSIST_DIR}"/ssh_host_*_key
    chmod 644 "${SSH_PERSIST_DIR}"/ssh_host_*_key.pub
  fi
}

configure_ssh_server() {
  local ssh_enabled
  ssh_enabled="$(jq_config -r '.os_ssh_server // false')"

  local ssh_enabled_before="true"
  [[ -f "/etc/ssh/sshd_not_to_be_run" ]] && ssh_enabled_before="false"
  if [[ "${ssh_enabled}" == "true" ]]; then
    report_info "cuos:init:ssh_server" "Start SSH server"
    rm -f /etc/ssh/sshd_not_to_be_run
    iptables -I INPUT -p tcp --dport 4222 -j ACCEPT 2>/dev/null || true
  else
    touch /etc/ssh/sshd_not_to_be_run
    iptables -D INPUT -p tcp --dport 4222 -j ACCEPT 2>/dev/null || true
  fi
  if [[ -n "${REINIT:-}" && "${ssh_enabled}" != "${ssh_enabled_before}" ]]; then
    systemctl restart ssh.service
  fi
}

calculate_bip() {
  local docker_net_space="$1"
  local docker_target_size="$2"

  # Extract base IP and prefix
  local base_ip="${docker_net_space%/*}"
  local prefix="${docker_net_space#*/}"

  # Convert IP to integer
  IFS=. read -r o1 o2 o3 o4 <<< "$base_ip"
  local base_int=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))

  # Calculate number of addresses in original and target subnet
  local orig_size=$(( 32 - prefix ))
  local target_size=$(( 32 - docker_target_size ))
  local orig_count=$(( 1 << orig_size ))
  local target_count=$(( 1 << target_size ))

  # Calculate last subnet start address
  local last_start=$(( base_int + orig_count - target_count ))

  # Convert back to dotted decimal
  local o1=$(( (last_start >> 24) & 255 ))
  local o2=$(( (last_start >> 16) & 255 ))
  local o3=$(( (last_start >> 8) & 255 ))
  local o4=$(( last_start & 255 ))

  echo "$o1.$o2.$o3.$o4/${docker_target_size}"
}

configure_docker() {
  local file_docker_daemon="${T_FILE_DOCKER_DAEMON:-"/etc/docker/daemon.json"}"
  local docker_net_space
  docker_net_space="$(jq -r '.docker_net_space // "10.235.240.0/20"' "${CONFIG_PATH}")"
  local docker_net_space_size
  docker_net_space_size="$(jq -r '.docker_net_space_size // 26' "${CONFIG_PATH}")"
  # /20 with /26 networks: 60 networks a 62 hosts

  local docker_bip_size
  docker_bip_size="$(jq -r '.docker_bip_size // 24' "${CONFIG_PATH}")"
  local bip
  bip="$(jq -r '.docker_bip // empty' "${CONFIG_PATH}")"
  bip="${bip:-"$(calculate_bip "${docker_net_space}" "${docker_bip_size}")"}"
  # 1 network a 254 hosts
  jq -n \
    --arg docker_bip "${bip}" \
    --arg docker_net_space "${docker_net_space}" \
    --arg docker_net_space_size "${docker_net_space_size}" \
    '{
      "log-driver": "journald",
      "log-opts": {
        "tag": "{{.Name}}"
      },
      "storage-driver": "overlay2",
      "data-root": "/data/docker",
      "bip": $docker_bip,
      "default-address-pools": [
        {
          "base": $docker_net_space,
          "size": $docker_net_space_size | tonumber
        }
      ],
      "max-concurrent-downloads": 3,
      "max-concurrent-uploads": 3,
      "no-new-privileges": true,
      "live-restore": true,
      "userland-proxy": false,
      "default-ulimits": {
        "nofile": {
          "Hard": 20000,
          "Name": "nofile",
          "Soft": 20000
        }
      },
      "seccomp-profile": "/etc/docker/seccomp-default.json"
  }' >"${file_docker_daemon}"
}

# Import custom CA certificates from system.json (if present)
import_custom_ca_certs() {
  # Extract CA certs from system.json (should be a list of PEM strings or a single PEM string)
  CA_CERTS=$(jq_config -r '.custom_ca_certs // empty')
  if [ -z "$CA_CERTS" ] || [ "$CA_CERTS" = "null" ]; then
    return
  fi

  CERT_DIR="/usr/local/share/ca-certificates/custom"
  mkdir -p "$CERT_DIR"

  # If it's a string, treat as single cert; if array, iterate
  TYPE=$(jq_config -r 'if (.custom_ca_certs | type) then .custom_ca_certs | type else "null" end')
  if [ "$TYPE" = "array" ]; then
    COUNT=$(jq_config -r '.custom_ca_certs | length')
    for ((j=0; j<COUNT; j++)); do
      jq_config -r ".custom_ca_certs[$j]" > "$CERT_DIR/custom_ca_cert_$j.crt"
    done
  elif [ "$TYPE" = "string" ]; then
    jq_config -r '.custom_ca_certs' > "$CERT_DIR/custom_ca_cert_0.crt"
  fi

  # Update CA certificates (Debian/Ubuntu)
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates
  # For Alpine
  elif command -v update-ca-certificates >/dev/null 2>&1 && [ -d /etc/ssl/certs ]; then
    update-ca-certificates
  # For RedHat/CentOS
  elif command -v update-ca-trust >/dev/null 2>&1; then
    update-ca-trust extract
  fi
}

create_swap_and_resize_fs() {
  if [[ "${VIRT_TYPE}" == "lxc" || "${VIRT_TYPE}" == "docker" ]]; then
    # For lxc we do not manage disks or swap
    return
  fi
  # --- Btrfs Root & Swap ---
  SWAP_SUBVOL="@swap"
  SWAP_MOUNTPOINT="/swap"
  SWAPFILE="$SWAP_MOUNTPOINT/swapfile"
  SWAP_SIZE_GB="$(jq_config ".swap_size // empty")"
  ROOT_MOUNT="/"
  ROOT_DEV=$(findmnt -n -o SOURCE --target "$ROOT_MOUNT")

  # If it's a Btrfs subvolume, resolve the actual device
  if [[ "$ROOT_DEV" == */@* || "$ROOT_DEV" == */subvol=* ]]; then
    ROOT_DEV=$(findmnt -n -o SOURCE -T "$ROOT_MOUNT" | sed 's/\[.*\]//')
  fi

  if [[ "$ROOT_DEV" =~ \/dev\/mapper\/ ]]; then
    ROOT_PART=$(lsblk -no PKNAME "$ROOT_DEV" | head -n1)
    ROOT_PART="/dev/$ROOT_PART"
  else
    ROOT_PART="$ROOT_DEV"
  fi

  # Extract Partition NUmber
  if [[ "$ROOT_PART" =~ [^0-9]*([0-9]+)$ ]]; then
    PART_NUM="${BASH_REMATCH[1]}"
  else
    PART_NUM=""
  fi
  DISK=$(lsblk -no PKNAME "$ROOT_PART" | head -n1)
  DISK="/dev/$DISK"
  if [ -n "$PART_NUM" ]; then
    echo "Growing partition $DISK partition number $PART_NUM"
    growpart "$DISK" "$PART_NUM" || true
  fi


  btrfs filesystem resize max "$ROOT_MOUNT" || true

  if ! mountpoint -q "$SWAP_MOUNTPOINT"; then
    mkdir -p "$SWAP_MOUNTPOINT"
    mount -o "compress=no,noatime,subvol=$SWAP_SUBVOL" "$ROOT_DEV" "$SWAP_MOUNTPOINT"
  fi

  if [[ -z "${SWAP_SIZE_GB}" ]]; then
    SWAP_SIZE_GB=8
    TARGET_SIZE="$((SWAP_SIZE_GB*1024*1024*1024))"
    FS_SIZE="$(df --output=size -B1 "$(dirname "$SWAPFILE")" | tail -n1)"
    MAX_SIZE="$((FS_SIZE / 4 / 1024 / 1024 * 1024 * 1024))"
    if [ "${TARGET_SIZE}" -gt "${MAX_SIZE}" ]; then
      TARGET_SIZE="${MAX_SIZE}"
    fi
  else
    TARGET_SIZE="$((SWAP_SIZE_GB*1024*1024*1024))"
  fi

  RECREATE_SWAPFILE=false
  if [ ! -f "$SWAPFILE" ]; then
    RECREATE_SWAPFILE=true
  elif [ "$(stat -c%s "$SWAPFILE")" -lt "${TARGET_SIZE}" ]; then
    RECREATE_SWAPFILE=true
  fi

  if $RECREATE_SWAPFILE; then

    # Get available space in bytes on the filesystem containing the swap file
    AVAIL_BYTES="$(df --output=avail -B1 "$(dirname "$SWAPFILE")" | tail -n1)"

    # Check if available space is at least 1.5x the desired swap size (for safety)
    REQUIRED_BYTES=$((TARGET_SIZE * 3 / 2))

    if [ "$AVAIL_BYTES" -ge "$REQUIRED_BYTES" ]; then
      swapoff "$SWAPFILE" 2>/dev/null || true
      rm -f "$SWAPFILE"
      chattr +C "$SWAP_MOUNTPOINT"

      if [[ "${TARGET_SIZE}" == "0" ]]; then return; fi

      dd if=/dev/zero of="$SWAPFILE" bs=1M count="$((TARGET_SIZE/1024/1024))" status=progress
      chmod 600 "$SWAPFILE"
      mkswap "$SWAPFILE"

    fi
  elif [[ -n "${REINIT:-}" ]]; then
    return
  fi
  if [[ -f "${SWAPFILE}" ]]; then
    swapon "$SWAPFILE"
  fi
}

main() {
  set -x

  if [[ "${1:-}" = "--reinit" ]]; then
    export REINIT=1

    if [[ -n "${2:-}" && "$(type -t "${2}")" == "function" ]]; then
      "${2}"
      exit "$?"
    fi
  else
    report_info "cuos:init:start" "System startup"
    state jq '.start_date = (now | todate)'
  fi

  prepare_data_volume

  ensure_docker_config_json

  ensure_system_config

  set_hostname

  configure_network

  import_custom_ca_certs

  configure_keyboard

  set_root_password

  create_ssh_hostkey

  configure_ssh_server

  configure_docker

  create_swap_and_resize_fs

  exit 0
}

if [[ -f "${SCRIPT_DIR}/custom-init.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/custom-init.sh"
fi

# Execute main only if script is run, not sourced
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
