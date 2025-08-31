#!/bin/bash

set -uo pipefail

# --- Hostname und Netzwerk ---
HOSTNAME_FILE="/etc/hostname"
INTERFACES_FILE="/etc/network/interfaces"
export CONFIG_PATH="/system.json"
VIRT_TYPE="$(systemd-detect-virt)"

raise() {
	echo "Error: $*"
	exit 1
}

raise_okay() {
	echo "Error: $*"
	exit 0
}

jq_config() {
	jq -r "$@" "${CONFIG_PATH}"
}

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
	if [[ "${VIRT_TYPE}" = "lxc" ]]; then
		cat "${SCRIPT_DIR}/system_default.json" >"${CONFIG_PATH}"
	else
		mkdir -p "/mnt/boot"
		mount -o ro -t vfat LABEL=boot "/mnt/boot"
		if [[ -f "/mnt/boot/system.json" ]]; then
			if ! jq . "/mnt/boot/system.json" >/dev/null 2>&1; then
				"${SCRIPT_DIR}/dialog.sh" "Provided system.json file is invalid. System will reboot in 30sec"
				sleep 10
				"${SCRIPT_DIR}/dialog.sh" "Provided system.json file is invalid. System will reboot in 20sec"
				sleep 10
				"${SCRIPT_DIR}/dialog.sh" "Provided system.json file is invalid. System will reboot in 10sec"
				sleep 10
				"${SCRIPT_DIR}/dialog.sh" "Provided system.json file is invalid. System will reboot now"
				/sbin/reboot
			fi
			cat "/mnt/boot/system.json" >"${CONFIG_PATH}"
		else
			cat "${SCRIPT_DIR}/system_default.json" >"${CONFIG_PATH}"
		fi
		umount "/mnt/boot"

		# Grab Cloud Init data if available
		mkdir -p "/mnt/cidata"
		mount -o ro LABEL=cidata "/mnt/cidata/"
		if [[ -f "/mnt/cidata/user-data" ]]; then
			echo "Found Cloud Init user-data, merging with system.json"
			NEW_CONFIG="$("${SCRIPT_DIR}/cloud-init-to-system-json.sh" "/mnt/cidata/user-data" /dev/stdout | \
				jq -s '.[0] * .[1]' \
				"${CONFIG_PATH}" -)"
			echo "${NEW_CONFIG}" >"${CONFIG_PATH}"
		fi
		umount "/mnt/cidata"
	fi
}

prepare_data_volume() {
	mkdir -p /data/{docker,containerd,dhcp,log,shieldor,.docker}
	mkdir -p /data/log/journal
	chown -R root:systemd-journal /data/log/journal
	chmod 2755 /data/log/journal
	journalctl --flush
}

set_hostname() {
	SYSTEM_HOSTNAME="$(jq_config '.hostname // empty')"
	if [[ -n "${SYSTEM_HOSTNAME}" ]]; then
		echo "Setting hostname to $SYSTEM_HOSTNAME"
		echo "$SYSTEM_HOSTNAME" > "$HOSTNAME_FILE"
		hostname "$SYSTEM_HOSTNAME"
	fi
}

configure_network() {
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
	} > "${INTERFACES_FILE}.new"

  if [[ -n "${REINIT:-}" && "$(sha256sum "${INTERFACES_FILE}" | cut -d ' ' -f1)" != "$(sha256sum "${INTERFACES_FILE}.new" | cut -d ' ' -f1)" ]]; then
		systemctl stop networking
		mv "${INTERFACES_FILE}.new" "${INTERFACES_FILE}"
		systemctl start networking
	else
		mv "${INTERFACES_FILE}.new" "${INTERFACES_FILE}"
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
	SWAP_SIZE_GB="$(jq_config ".swap_size // 8")"
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
		mount -o subvol=$SWAP_SUBVOL "$ROOT_DEV" "$SWAP_MOUNTPOINT"
	fi

	RECREATE_SWAPFILE=false
	if [ ! -f "$SWAPFILE" ]; then
		RECREATE_SWAPFILE=true
	elif [ "$(stat -c%s "$SWAPFILE")" -lt $((SWAP_SIZE_GB*1024*1024*1024)) ]; then
		RECREATE_SWAPFILE=true
	fi

	if $RECREATE_SWAPFILE; then

		# Get available space in bytes on the filesystem containing the swap file
		AVAIL_BYTES=$(df --output=avail -B1 "$(dirname "$SWAPFILE")" | tail -n1)

		# Check if available space is at least 1.5x the desired swap size (for safety)
		REQUIRED_BYTES=$((SWAP_SIZE_GB * 1024 * 1024 * 1024 * 3 / 2))

		if [ "$AVAIL_BYTES" -ge "$REQUIRED_BYTES" ]; then
			swapoff "$SWAPFILE" 2>/dev/null || true
			rm -f "$SWAPFILE"
			chattr +C "$SWAP_MOUNTPOINT"
			dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAP_SIZE_GB*1024)) status=progress
			chmod 600 "$SWAPFILE"
			mkswap "$SWAPFILE"

			FSTAB_SWAP_MOUNT="LABEL=system  $SWAP_MOUNTPOINT btrfs subvol=$SWAP_SUBVOL 0 0"
			FSTAB_SWAPFILE="$SWAPFILE none swap sw 0 0"

			if ! grep -q "$FSTAB_SWAP_MOUNT" /etc/fstab; then
				echo "$FSTAB_SWAP_MOUNT" >> /etc/fstab
			fi
			if ! grep -q "$FSTAB_SWAPFILE" /etc/fstab; then
				echo "$FSTAB_SWAPFILE" >> /etc/fstab
			fi
			echo "Swap file created at $SWAPFILE with size ${SWAP_SIZE_GB}GB"

			swapon "$SWAPFILE"
		fi
	fi
}
