#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

set -x

export CONFIG_PATH="/system.json"
VIRT_TYPE="$(systemd-detect-virt)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

ensure_docker_config_json() {
  mkdir -p /root/.docker
  rmdir /root/.docker/config.json 2>/dev/null && \
    echo "Warning: deleted config.json as dir"
  if [[ ! -f "/root/.docker/config.json" ]]; then
    echo "{}" >"/root/.docker/config.json"
  fi
}

ensure_system_config() {
  if [[ -f "${CONFIG_PATH}" ]]; then
    return
  fi
  if [[ "${VIRT_TYPE}" == "lxc" ]]; then
    cat "${SCRIPT_DIR}/system-default.json" >"${CONFIG_PATH}"
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
    umount "/mnt/boot"

    # Grab Cloud Init data if available
    mkdir -p "/mnt/cidata"
    mount -o ro LABEL=cidata "/mnt/cidata/"
    if [[ -f "/mnt/cidata/user-data" ]]; then
      report_info "cuos:init:cloud-init" "Found Cloud Init user-data, merging with system.json"
      if ! NEW_CONFIG="$("${SCRIPT_DIR}/cloud-init-to-system-json.sh" "/mnt/cidata/user-data" /dev/stdout | \
        jq -s '.[0] * .[1]' \
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
  # TODO: Check system.json against JSON schema for security
  jv "${SCRIPT_DIR}/system-schema.json" "/system.json"
}

prepare_data_volume() {
  systemd-machine-id-setup
  mkdir -p /data/{docker,containerd,dhcp,log,shieldor,.docker}
  mkdir -p /data/log/journal
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
      local r1 r2 hn
      r1=$(printf "%02X" $(( RANDOM % 256 )))
      r2=$(printf "%02X" $(( RANDOM % 256 )))
      SYSTEM_HOSTNAME="device-${r1}${r2}"
      jq_replace \
        --arg hn "${SYSTEM_HOSTNAME}" \
        '.hostname = $hn'
  fi
  if [[ -n "${SYSTEM_HOSTNAME}" ]]; then
    echo "Setting hostname to $SYSTEM_HOSTNAME"
    echo "$SYSTEM_HOSTNAME" > "/etc/hostname"
    hostname "$SYSTEM_HOSTNAME"
  fi
  if [[ -n "${REINIT:-}" && "${OLD_HOSTNAME}" != "${SYSTEM_HOSTNAME}" ]]; then
    systemctl restart networking
  fi
}

configure_network() {
  local interfaces_file="/etc/network/interfaces"

  if [[ "${VIRT_TYPE}" == "lxc" ]]; then
    # For lxc the network is configured from outside
    return
  fi
  # Gather all non-lo, non-docker0 interfaces and sort them alphabetically
  shopt -s nullglob
  local interfaces=()
  # only ethernet interfaces, so not lo, docker0, wlan, bonds, br, veth, etc.
  for interface in /sys/class/net/e*; do
    local name
    name="$(basename "$interface")"
    interfaces+=("$name")
  done

  # Read network config array from system.json using jq_config
  local configs_length
  configs_length="$(jq_config '.network | length')"

  {
    echo "auto lo"
    echo "iface lo inet loopback"
    echo

    # Configure each interface with corresponding config if present
    for ((i=0; i<${#interfaces[@]}; i++)); do
      local IFACE="${interfaces[$i]}"
      local METRIC
      METRIC=$((100 * (i+1)))
      if [ "$i" -lt "$configs_length" ]; then
        # Extract config for this interface
        local config
        config=$(jq_config -r ".network[$i]")
        local DHCP
        DHCP=$(echo "$config" | jq -r '.dhcp // empty')
        local IP
        IP=$(echo "$config" | jq -r '.ip-address // empty')
        local MASK
        MASK=$(echo "$config" | jq -r '.network-mask // empty')
        local GW
        GW=$(echo "$config" | jq -r '.gateway // empty')
        local DNS
        DNS=$(echo "$config" | jq -r '
          if (.dns-server | type == "array") then
            .dns-server | join(" ")
          else
            .dns-server // empty
          end')
        local NTP
        NTP=$(echo "$config" | jq -r '
          if (.ntp-server | type == "array") then
            .ntp-server | join(" ")
          else
            .ntp-server // empty
          end')
        if [ -z "$DHCP" ] && [ -z "$IP" ] && [ -z "$MASK" ]; then
          # No config for this interface, skip it
          echo "iface $IFACE inet manual"
          echo
          continue
        fi
        if [ "$DHCP" = "true" ]; then
          # DHCP configuration with metric
          echo "auto $IFACE"
          echo "iface $IFACE inet dhcp"
          echo "    metric $METRIC"
          echo
        else
          # Static configuration
          echo "auto $IFACE"
          echo "iface $IFACE inet static"
          [ -n "$IP" ] && echo "    address $IP"
          [ -n "$MASK" ] && echo "    netmask $MASK"
          [ -n "$GW" ] && echo "    gateway $GW"
          [ -n "$DNS" ] && echo "    dns-nameservers $DNS"
          [ -n "$NTP" ] && echo "    ntp-servers $NTP"
          echo
        fi
      elif [ "$i" -eq 0 ]; then
        # No config for the first interface, set to DHCP with metric
        echo "auto $IFACE"
        echo "iface $IFACE inet dhcp"
        echo "    metric $METRIC"
        echo
      else
        # No config for this interface, set to manual
        echo "iface $IFACE inet manual"
        echo
      fi
    done
  } > "${interfaces_file}.new"

  if [[ -n "${REINIT:-}" && "$(sha256sum "${interfaces_file}" | cut -d ' ' -f1)" != "$(sha256sum "${interfaces_file}.new" | cut -d ' ' -f1)" ]]; then
    systemctl stop networking
    mv "${interfaces_file}.new" "${interfaces_file}"
    systemctl start networking
  else
    mv "${interfaces_file}.new" "${interfaces_file}"
  fi

}

create_ssh_hostkey() {
  shopt -s nullglob
  hostkeys=(/etc/ssh/ssh_host_*_key)
  if [ ${#hostkeys[@]} -eq 0 ]; then
    echo "Generating SSH host keys"
    mkdir -p /etc/ssh
    chmod 700 /etc/ssh
    ssh-keygen -A
  fi
}

configure_docker() {
  jq '{
      "log-driver": "journald",
      "log-opts": {
        "tag": "{{.Name}}"
      },
      "storage-driver": "overlay2",
      "data-root": "/data/docker",
      "bip": (.docker_bridge_net // "10.235.255.1/24"),
      "default-address-pools": [
        {
          "base": (.docker_net_space // "10.235.128.0/17"),
          "size": (.docker_net_space_size // 26) #=64 different CTs
          # total: 4*128 = 512 networks
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
  }' "${CONFIG_PATH}" >/etc/docker/daemon.json
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
  if [[ "${VIRT_TYPE}" == "lxc" ]]; then
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


if [[ "${1:-}" = "--reinit" ]]; then
  export REINIT=1

  if [[ -n "${2:-}" && "$(type -t "${2}")" == "function" ]]; then
    exec "${2}"
  fi
else
  report_info "cuos:init:start" "System startup"
fi

prepare_data_volume

ensure_docker_config_json

ensure_system_config

set_hostname

configure_network

import_custom_ca_certs

create_ssh_hostkey

configure_docker

create_swap_and_resize_fs

exit 0
