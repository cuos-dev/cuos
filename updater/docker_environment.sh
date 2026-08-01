#!/bin/bash

set -x

raise() {
	local code="${1:-1}"
	shift
	echo "Error: $*" >&2
	exit "${code}"
}

# shellcheck disable=SC2329 disable=SC2317
cleanup() {
	if [[ -n "${DOCKERD_PID:-}" ]]; then
		kill "${DOCKERD_PID}" || true
		wait "${DOCKERD_PID}" || true
	fi
	umount -R "${TARGET_ROOT}" 2>/dev/null || true
	umount -R "${TARGET_BOOT}" 2>/dev/null || true
}
trap cleanup EXIT


if [[ "${INSTALLIMAGE}" != "true" ]]; then
	update-ca-certificates
fi

export TARGET_DEVICE="${TARGET_DEVICE:-"/dev/sda"}"
TARGET_BOOT_PARTITION="${TARGET_BOOT_PARTITION:-"LABEL=boot"}"
TARGET_ROOT_PARTITION="${TARGET_ROOT_PARTITION:-"LABEL=system"}"
export TARGET_BOOT="${TARGET_BOOT:-"/mnt/boot"}"
export TARGET_ROOT="${TARGET_ROOT:-"/mnt/os"}"
export DOCKER_DIR="${TARGET_ROOT}/docker"

if [[ "${INSTALLGRUB}" = "true" && ! -b "${TARGET_DEVICE}" ]]; then
	echo "No target device found: ${TARGET_DEVICE}"
	raise 90 "No target device found"
fi

# Mount devices
mkdir -p "${TARGET_ROOT}"
mount -t btrfs -o subvol=@os "${TARGET_ROOT_PARTITION}" "${TARGET_ROOT}" \
	|| raise 91 "Could not mount @os subvolume"

mkdir -p "${DOCKER_DIR}"

mkdir -p "${TARGET_BOOT}"
mount -t vfat -o "rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro" "${TARGET_BOOT_PARTITION}" "${TARGET_BOOT}" \
	|| raise 92 "Could not mount boot partition"



#if [[ ! -d "${TARGET_BOOT}/grub" ]]; then
#	echo "No boot partion mounted to ${TARGET_BOOT}"
#	exit 1
#fi


start_dockerd() {

	# Start dockerd and wait until it is ready:
	dockerd \
		--storage-driver btrfs \
		--iptables=false \
		--ip6tables=false \
		--ip-forward=false \
		--ip-masq=false \
		--bridge=none \
		--data-root "${DOCKER_DIR}" &
	DOCKERD_PID="$!"
	echo "Waiting for Docker to be ready..."
	counter=0
	until docker info >/dev/null 2>&1; do
		counter="$((counter + 1))"
		if [[ "${counter}" -gt 100 ]]; then
			raise 93 "Could not start dockerd"
		fi
		sleep 1
		if ! kill -0 "$DOCKERD_PID"; then
			return 1
		fi
	done
	if ! docker info >/dev/null 2>&1; then
		return 1
	fi
	return 0
}

if ! docker info >/dev/null 2>&1; then
	if ! start_dockerd; then
		if ! start_dockerd; then
			if ! start_dockerd; then
				if ! start_dockerd; then
					raise 94 "Could not start dockerd after three trys"
				fi
			fi
		fi
	fi
fi

docker info

echo "disc free:"
df -h  "${DOCKER_DIR}"


SCRIPT="$1"
shift

# Perform task
"${SCRIPT}" "$@"
EXIT_CODE="$?"

if [[ -z "${DOCKERD_PID}" && \
		-d "${TARGET_ROOT}/docker" && \
		-d "${TARGET_ROOT}/system-A" && \
		-d "${TARGET_ROOT}/system-B" ]]; then
	btrfs subvolume delete -R "${TARGET_ROOT}/docker/btrfs/subvolumes"/*
	rm -Rf "${TARGET_ROOT}/docker"
fi

# clean up:
if [[ -n "${DOCKERD_PID}" ]]; then
	sync
	sleep 1
	kill "${DOCKERD_PID}"
	wait "${DOCKERD_PID}"
	DOCKERD_PID=""
fi

sync

umount -R "${TARGET_ROOT}"
umount -R "${TARGET_BOOT}"

exit "${EXIT_CODE}"
