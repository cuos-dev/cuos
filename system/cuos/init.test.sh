#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# mocks:
systemd-detect-virt() {
  echo "test"
}
systemctl() {
  :
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-test.sh"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/init.sh"

expect "mask_to_prefix cdr" \
  "25" \
  mask_to_prefix "25"

expect "mask_to_prefix 16" "16" mask_to_prefix "255.255.0.0"
expect "mask_to_prefix 17" "17" mask_to_prefix "255.255.128.0"
expect "mask_to_prefix 18" "18" mask_to_prefix "255.255.192.0"
expect "mask_to_prefix 19" "19" mask_to_prefix "255.255.224.0"
expect "mask_to_prefix 20" "20" mask_to_prefix "255.255.240.0"
expect "mask_to_prefix 21" "21" mask_to_prefix "255.255.248.0"
expect "mask_to_prefix 22" "22" mask_to_prefix "255.255.252.0"
expect "mask_to_prefix 23" "23" mask_to_prefix "255.255.254.0"
expect "mask_to_prefix 24" "24" mask_to_prefix "255.255.255.0"
expect "mask_to_prefix 25" "25" mask_to_prefix "255.255.255.128"
expect "mask_to_prefix 26" "26" mask_to_prefix "255.255.255.192"
expect "mask_to_prefix 27" "27" mask_to_prefix "255.255.255.224"
expect "mask_to_prefix 28" "28" mask_to_prefix "255.255.255.240"
expect "mask_to_prefix 29" "29" mask_to_prefix "255.255.255.248"
expect "mask_to_prefix 30" "30" mask_to_prefix "255.255.255.252"
expect "mask_to_prefix 31" "31" mask_to_prefix "255.255.255.254"
expect "mask_to_prefix 32" "32" mask_to_prefix "255.255.255.255"

expect "mask_to_prefix invalid" "" mask_to_prefix "255.255.252.128"

export CONFIG_PATH="${SCRIPT_DIR}/init.test.system.json"
export T_FILE_DOCKER_DAEMON="/dev/stdout"

expect "configure_docker" \
'{
  "log-driver": "journald",
  "log-opts": {
    "tag": "{{.Name}}"
  },
  "storage-driver": "overlay2",
  "data-root": "/data/docker",
  "default-address-pools": [
    {
      "base": "192.168.128.0/20",
      "size": 26
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
}' \
  configure_docker

dpkg-reconfigure() {
  :
}
setupcon() {
  :
}

export T_FILE_KEYBOARD="/dev/stdout"
expect \
  "configure_keyboard" \
  '# Managed by cuos/init.sh
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT="intl"
XKBOPTIONS=""
BACKSPACE="guess"' \
  configure_keyboard

main_mock() {
  echo "RESULT123"
}

expect \
  "main --reinit command" \
  "RESULT123" \
  main --reinit main_mock 2>/dev/null

export T_FILE_INTERFACES_NEW=/dev/stdout
export T_FILE_INTERFACES=/dev/stdout
export T_DIR_SYS_CLASS_NET="${SCRIPT_DIR}/init.test.sys_class_net"
expect \
  "configure_network: auto" \
  $'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n    metric 100\n\nauto eth1\niface eth1 inet manual\n    metric 200' \
  configure_network

export CONFIG_PATH="${SCRIPT_DIR}/init.test.system2.json"
expect \
  "configure_network 2: eth0: 155.7, eth1: dhcp" \
  $'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet static\n    address 192.168.155.7\n    netmask 255.255.255.128\n    gateway 192.168.155.1\n    dns-nameservers 192.168.155.1 192.168.155.2\n    ntp-servers 192.168.155.1 192.168.155.2\n    metric 100\n    up ip route add 192.168.77.0/24 via 192.168.155.1 dev eth0\n    down ip route del 192.168.77.0/24 via 192.168.155.1 dev eth0\n\nauto eth1\niface eth1 inet dhcp\n    metric 200\n\nallow-hotplug /e*/1=ethhotplug2\niface ethhotplug2 inet static\n    address 192.168.172.7\n    netmask 255.255.255.128\n    gateway 192.168.172.1\n    dns-nameservers 192.168.172.1 192.168.172.2\n    ntp-servers 192.168.172.1 192.168.172.2\n    metric 300' \
  configure_network

export CONFIG_PATH="${SCRIPT_DIR}/init.test.system3.json"
expect \
  "configure_network 3: eth0: 172.7, eth1: 173.7" \
  $'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet static\n    address 192.168.172.7\n    netmask 255.255.255.128\n    gateway 192.168.172.1\n    dns-nameservers 192.168.172.1 192.168.172.2\n    ntp-servers 192.168.172.1 192.168.172.2\n    metric 100\n\nauto eth1\niface eth1 inet static\n    address 192.168.173.7\n    netmask 255.255.255.0\n    gateway 192.168.173.1\n    dns-nameservers 192.168.173.1 192.168.173.2\n    ntp-servers 192.168.173.1 192.168.173.2\n    metric 200\n\nallow-hotplug /e*/1=ethhotplug0\niface ethhotplug0 inet static\n    address 192.168.155.7\n    netmask 255.255.255.128\n    gateway 192.168.155.1\n    dns-nameservers 192.168.155.1 192.168.155.2\n    ntp-servers 192.168.155.1 192.168.155.2\n    metric 300\n\nallow-hotplug /e*/2=ethhotplug1\niface ethhotplug1 inet dhcp\n    metric 400' \
  configure_network

export CONFIG_PATH="${SCRIPT_DIR}/init.test.system4.json"
expect \
  "configure_network 4: eth0: 172.7, eth1: 155.7" \
  $'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet static\n    address 192.168.172.7\n    netmask 255.255.255.128\n    gateway 192.168.172.1\n    dns-nameservers 192.168.172.1 192.168.172.2\n    ntp-servers 192.168.172.1 192.168.172.2\n    metric 100\n\nauto eth1\niface eth1 inet static\n    address 192.168.155.7\n    netmask 255.255.255.128\n    gateway 192.168.155.1\n    dns-nameservers 192.168.155.1 192.168.155.2\n    ntp-servers 192.168.155.1 192.168.155.2\n    metric 200\n\nallow-hotplug /e*/1=ethhotplug1\niface ethhotplug1 inet dhcp\n    metric 300' \
  configure_network

export CONFIG_PATH="${SCRIPT_DIR}/init.test.system5.json"
expect \
  "configure_network: no config found" \
  $'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n    metric 100\n\nauto eth1\niface eth1 inet manual\n    metric 200\n\nallow-hotplug mac/a1:b2:c3:d4:e5:f6=ethhotplug0\niface ethhotplug0 inet static\n    address 192.168.155.7\n    netmask 255.255.255.128\n    gateway 192.168.155.1\n    dns-nameservers 192.168.155.1 192.168.155.2\n    ntp-servers 192.168.155.1 192.168.155.2\n    metric 300\n\nallow-hotplug eth8\niface eth8 inet static\n    address 192.168.172.7\n    netmask 255.255.255.128\n    gateway 192.168.172.1\n    dns-nameservers 192.168.172.1 192.168.172.2\n    ntp-servers 192.168.172.1 192.168.172.2\n    metric 400' \
  configure_network

# empty dir
export T_DIR_SYS_CLASS_NET="${SCRIPT_DIR}/init.test.sys_class_net/eth0"
export CONFIG_PATH="${SCRIPT_DIR}/init.test.system.json"
# TODO: Test no interfaces, no config
expect \
  "configure_network: auto" \
  $'auto lo\niface lo inet loopback\n\nallow-hotplug /e*/1=eth\niface eth inet dhcp\n    metric 100' \
  configure_network



export T_FILE_UDEV_RULES_NEW=/dev/stdout
export T_FILE_UDEV_RULES=/dev/stdout

export CONFIG_PATH="${SCRIPT_DIR}/init.test.system6.json"
expect \
  "configure_udev: no config found" \
  $'# Managed automatically\n\nSUBSYSTEM=="tty", ATTRS{serial}=="A50285BI", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0660", TAG+="iot", SYMLINK+="zigbee"\nSUBSYSTEM=="sound", ATTRS{idVendor}=="0499", ATTRS{idProduct}=="1503", MODE="0660", TAG+="audio", SYMLINK+="midi-keyboard"\nSUBSYSTEM=="hidraw", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="c216", MODE="0660", TAG+="input", SYMLINK+="gamepad"\nSUBSYSTEM=="block", ATTRS{serial}=="4C530001230101118392", MODE="0660", TAG+="storage", SYMLINK+="backup-disk"\nSUBSYSTEM=="net", ATTR{address}=="02:11:22:33:44:55", MODE="0660", SYMLINK+="usbip-nic"' \
  configure_udev

summary
