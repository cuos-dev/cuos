#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

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
# The charset is the kernel's own. A vfat mount that names one the running
# kernel has no NLS table for is refused outright ("IO charset ... not found"),
# and which tables a kernel carries is not something this script can know: the
# Armbian sunxi64 kernel of the Orange Pi Zero 3 has no nls_ascii. The boot
# partition holds ASCII names only, so nothing here depends on the choice.
mount -t vfat -o "rw,relatime,fmask=0022,dmask=0022,shortname=mixed,errors=remount-ro" "${TARGET_BOOT_PARTITION}" "${TARGET_BOOT}" \
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

# The host's daemon, if the caller handed one in. /var/run/docker.sock is left
# alone so that start_dockerd below can bind it; the plain path is still
# honoured, because image-factory and any system older than this updater mount
# the socket there.
CUOS_DOCKER_SOCKET="${CUOS_DOCKER_SOCKET:-"/run/cuos-docker.sock"}"
if [[ -S "${CUOS_DOCKER_SOCKET}" ]]; then
	export DOCKER_HOST="unix://${CUOS_DOCKER_SOCKET}"
fi

if ! docker info >/dev/null 2>&1; then
	# A socket that does not answer must not keep the client from reaching the
	# dockerd started below, which listens on the default path.
	unset DOCKER_HOST
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
