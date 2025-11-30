#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

export TEST=1

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
  $'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n    metric 100\n\niface eth1 inet manual' \
  configure_network

export CONFIG_PATH="${SCRIPT_DIR}/init.test.system2.json"
expect \
  "configure_network 2: eth0: 155.7, eth1: dhcp" \
  $'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet static\n    address 192.168.155.7\n    netmask 255.255.255.128\n    gateway 192.168.155.1\n    dns-nameservers 192.168.155.1 192.168.155.2\n    ntp-servers 192.168.155.1 192.168.155.2\n\nauto eth1\niface eth1 inet dhcp\n    metric 20' \
  configure_network

export CONFIG_PATH="${SCRIPT_DIR}/init.test.system3.json"
expect \
  "configure_network 3: eth0: 172.7, eth1: 173.7" \
  $'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet static\n    address 192.168.172.7\n    netmask 255.255.255.128\n    gateway 192.168.172.1\n    dns-nameservers 192.168.172.1 192.168.172.2\n    ntp-servers 192.168.172.1 192.168.172.2\n\nauto eth1\niface eth1 inet static\n    address 192.168.173.7\n    netmask 255.255.255.0\n    gateway 192.168.173.1\n    dns-nameservers 192.168.173.1 192.168.173.2\n    ntp-servers 192.168.173.1 192.168.173.2' \
  configure_network

export CONFIG_PATH="${SCRIPT_DIR}/init.test.system4.json"
expect \
  "configure_network 4: eth0: 172.7, eth1: 155.7" \
  $'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet static\n    address 192.168.172.7\n    netmask 255.255.255.128\n    gateway 192.168.172.1\n    dns-nameservers 192.168.172.1 192.168.172.2\n    ntp-servers 192.168.172.1 192.168.172.2\n\nauto eth1\niface eth1 inet static\n    address 192.168.155.7\n    netmask 255.255.255.128\n    gateway 192.168.155.1\n    dns-nameservers 192.168.155.1 192.168.155.2\n    ntp-servers 192.168.155.1 192.168.155.2' \
  configure_network

export CONFIG_PATH="${SCRIPT_DIR}/init.test.system5.json"
expect \
  "configure_network: no config found" \
  $'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n    metric 100\n\niface eth1 inet manual' \
  configure_network

summary
