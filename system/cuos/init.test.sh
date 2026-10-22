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

T_FILE_PID1_ENVIRON="$(mktemp)"
export T_FILE_PID1_ENVIRON
printf 'container=docker\0CUOS_IMAGE=ghcr.io/cuos-dev/cuos-system-lxc:v1\0CUOS_IMAGE_DIGEST=sha256:abc\0' \
  >"${T_FILE_PID1_ENVIRON}"
expect "container_env: image" "ghcr.io/cuos-dev/cuos-system-lxc:v1" container_env CUOS_IMAGE
expect "container_env: digest" "sha256:abc" container_env CUOS_IMAGE_DIGEST
expect "container_env: a prefix is not the name" "" container_env CUOS_IMAGE_DIG
expect "container_env: absent" "" container_env MISSING
rm -f "${T_FILE_PID1_ENVIRON}"
expect "container_env: no environ" "" container_env CUOS_IMAGE
unset T_FILE_PID1_ENVIRON

T_FILE_ETC_HOSTS="$(mktemp)"
export T_FILE_ETC_HOSTS
hosts_line() {
  write_etc_hosts "$1" && grep "^$2" "${T_FILE_ETC_HOSTS}"
}
expect "write_etc_hosts: localhost" "$(printf '127.0.0.1\tlocalhost')" hosts_line edge02 127.0.0.1
expect "write_etc_hosts: own name" "$(printf '127.0.1.1\tedge02')" hosts_line edge02 127.0.1.1
expect "write_etc_hosts: fqdn and short name" "$(printf '127.0.1.1\tedge02.example.com edge02')" \
  hosts_line edge02.example.com 127.0.1.1
VIRT_TYPE_SAVED="${VIRT_TYPE}"
VIRT_TYPE=lxc
echo "10.0.0.1 from-pve" >"${T_FILE_ETC_HOSTS}"
expect "write_etc_hosts: lxc leaves the file alone" "10.0.0.1 from-pve" hosts_line edge02 10.0.0.1
: >"${T_FILE_ETC_HOSTS}"
expect "write_etc_hosts: lxc leaves an empty file alone" "" hosts_line edge02 127.0.1.1
VIRT_TYPE="${VIRT_TYPE_SAVED}"
rm -f "${T_FILE_ETC_HOSTS}"
unset T_FILE_ETC_HOSTS

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

# The resolvers of the docker inside a docker container.
dns_of() {
  T_FILE_DOCKER_DAEMON="/dev/stdout" configure_docker | jq -c '[.dns, .bip]'
}
# Called from configure_docker, which shellcheck does not follow.
# shellcheck disable=SC2317,SC2329
iptables() {
  case "$*" in
    "-t nat -S DOCKER_OUTPUT")
      echo "-A DOCKER_OUTPUT -d 127.0.0.11/32 -p tcp -m tcp --dport 53 -j DNAT --to-destination 127.0.0.11:35059"
      echo "-A DOCKER_OUTPUT -d 127.0.0.11/32 -p udp -m udp --dport 53 -j DNAT --to-destination 127.0.0.11:49749" ;;
    "-t nat -C "*) return 1 ;;
    *) echo "iptables $*" >>"${IPTABLES_LOG}" ;;
  esac
}
# shellcheck disable=SC2317,SC2329
sysctl() {
  :
}
IPTABLES_LOG="$(mktemp)"
export T_FILE_RESOLV_CONF
T_FILE_RESOLV_CONF="$(mktemp)"
CONFIG_PATH_SAVED="${CONFIG_PATH}"
CONFIG_PATH="$(mktemp)"
VIRT_TYPE_SAVED="${VIRT_TYPE}"

echo "nameserver 127.0.0.11" >"${T_FILE_RESOLV_CONF}"
echo '{"docker_net_space": "10.235.224.0/20"}' >"${CONFIG_PATH}"
expect "configure_docker: no dns outside a docker container" '[null,null]' dns_of

VIRT_TYPE=docker
expect "configure_docker: docker0 forwarded to the embedded resolver" \
  '[["10.235.224.1"],"10.235.224.1/26"]' dns_of
expect "configure_docker: ... for udp and tcp, on the ports docker picked" \
  "iptables -t nat -I PREROUTING -d 10.235.224.1 -p udp --dport 53 -j DNAT --to-destination 127.0.0.11:49749
iptables -t nat -I PREROUTING -d 10.235.224.1 -p tcp --dport 53 -j DNAT --to-destination 127.0.0.11:35059" \
  cat "${IPTABLES_LOG}"

echo '{}' >"${CONFIG_PATH}"
expect "configure_docker: in a docker container the /20 before the default" \
  '[["10.235.224.1"],"10.235.224.1/26"]' dns_of
VIRT_TYPE=lxc
expect "configure_docker: elsewhere the default" \
  '"10.235.240.0/20"' eval 'T_FILE_DOCKER_DAEMON=/dev/stdout configure_docker | jq -c ".\"default-address-pools\"[0].base"'
VIRT_TYPE=docker

echo '{"network": [{"dns-server": ["10.0.0.53", "10.0.0.54"]}, {"dns-server": "10.0.0.54 10.0.0.55"}]}' >"${CONFIG_PATH}"
expect "configure_docker: the dns-servers of the configuration, each once" \
  '[["10.0.0.53","10.0.0.54","10.0.0.55"],null]' dns_of

echo "nameserver 10.0.2.3" >"${T_FILE_RESOLV_CONF}"
echo '{}' >"${CONFIG_PATH}"
expect "configure_docker: a resolver of its own is docker's to use" '[null,null]' dns_of

VIRT_TYPE="${VIRT_TYPE_SAVED}"
rm -f "${CONFIG_PATH}" "${T_FILE_RESOLV_CONF}" "${IPTABLES_LOG}"
CONFIG_PATH="${CONFIG_PATH_SAVED}"
unset T_FILE_RESOLV_CONF -f iptables sysctl

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

NTP_TMP="$(mktemp -d)"
export T_FILE_TIMESYNCD="${NTP_TMP}/timesyncd.conf.d/cuos.conf"
ntp_conf() {
  configure_ntp
  cat "${T_FILE_TIMESYNCD}" 2>/dev/null || echo "(none)"
}
export CONFIG_PATH="${SCRIPT_DIR}/init.test.system2.json"
expect "configure_ntp: all entries, in order" \
  $'# Managed by cuos/init.sh\n[Time]\nNTP=192.168.155.1 192.168.155.2 192.168.172.1 192.168.172.2' \
  ntp_conf
echo '{"network": [{"ntp-server": "a.example b.example"}, {"ntp-server": ["b.example", "c.example"]}]}' >"${NTP_TMP}/system.json"
export CONFIG_PATH="${NTP_TMP}/system.json"
expect "configure_ntp: a string, and duplicates once" \
  $'# Managed by cuos/init.sh\n[Time]\nNTP=a.example b.example c.example' \
  ntp_conf
echo '{"network": [{"dhcp": true}]}' >"${NTP_TMP}/system.json"
expect "configure_ntp: none configured removes the drop-in" "(none)" ntp_conf
echo '{}' >"${NTP_TMP}/system.json"
expect "configure_ntp: no network at all" "(none)" ntp_conf
rm -rf "${NTP_TMP}"


# First start: provisioning is the remote layer, cloud-init the local one.
LAYERS_TMP="$(mktemp -d)"
(
  export LAYER_DIR="${LAYERS_TMP}"
  LOCAL_LAYER="${LAYERS_TMP}/system_A.local.json"
  export LAYER_LOCK="${LAYERS_TMP}/lock"
  export T_FILE_SLOT="${LAYERS_TMP}/active_slot"
  export CONFIG_PATH="${LAYERS_TMP}/system_A.json"
  echo "A" >"${T_FILE_SLOT}"

  config_first_layers \
    '{"os_image": "x", "hostname": "from-the-image", "keyboard_layout": "de"}' \
    '{"hostname": "from-cloud-init", "keyboard_layout": "de"}'
  echo "$(jq -c . "${LAYERS_TMP}/system_A.remote.json")"
  echo "$(jq -c . "${LOCAL_LAYER}")"
  echo "$(jq -c . "${CONFIG_PATH}")"
) >"${LAYERS_TMP}/out" 2>/dev/null
expect "config_first_layers: provisioning is remote" \
  '{"os_image":"x","hostname":"from-the-image","keyboard_layout":"de"}' \
  sed -n 1p "${LAYERS_TMP}/out"
expect "config_first_layers: cloud-init is local, without what remote has anyway" \
  '{"hostname":"from-cloud-init"}' sed -n 2p "${LAYERS_TMP}/out"
expect "config_first_layers: cloud-init wins" \
  '{"os_image":"x","hostname":"from-cloud-init","keyboard_layout":"de"}' \
  sed -n 3p "${LAYERS_TMP}/out"
rm -rf "${LAYERS_TMP}"

summary
