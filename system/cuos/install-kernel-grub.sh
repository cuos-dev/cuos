#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

set -x

SLOT="$1"
# from exports:
# TARGET_BOOT
# TARGET_DEVICE

# Copy latest kernel and initrd to boot slot
kernel=$(find "${ROOT}"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -n1) \
  || raise 108 "Faild to detect kernel file"
initrd=$(find "${ROOT}"/boot/initrd.img-* 2>/dev/null | sort -V | tail -n1) \
  || raise 109 "Faild to detect initrd file"

if [[ -z "${kernel}" ]]; then
  raise 110 "No matching kernel file found."
fi
if [[ -z "${initrd}" ]]; then
  raise 111 "No matching initrd file found."
fi

filename_kernel="${SLOT}_$(basename "${kernel}")"
filename_initrd="${SLOT}_$(basename "${initrd}")"

cp "${kernel}" "${TARGET_BOOT}/${filename_kernel}" \
  || raise 113 "Failed to copy kernel"
cp "${initrd}" "${TARGET_BOOT}/${filename_initrd}" \
  || raise 114 "Failed to copy initrd"


# The boot loader itself is written by image-factory, into the image file. An
# older factory hands in a block device and expects this script to do it.
if [[ "${INSTALLIMAGE:-}" = "true" && -b "${TARGET_DEVICE:-}" ]]; then
  raise 122 "This system image does not install GRUB itself. Build it with an
       image factory that reads the dev.cuos.boot label."
fi

mkdir -p "${TARGET_BOOT}/grub" || raise 125 "Failed to configure grub"

version="$(basename "${kernel}" | sed 's/vmlinuz-//')"

# Generate GRUB entry
SLOT_NAME="${PRODUCT_NAME} Slot ${SLOT} - Linux $version"
( cat <<EOF > "${TARGET_BOOT}/${SLOT}_grub.cfg"
menuentry '${SLOT_NAME}' --unrestricted {
    insmod gzio
    insmod part_gpt
    insmod fat
    insmod btrfs

    search --no-floppy --label boot --set=root

    linux /${filename_kernel} root=LABEL=system rootfstype=btrfs rootflags=subvol=${CONTAINER_ROOTFS} ro loglevel=3 noresume apparmor=1
    initrd /${filename_initrd}
}

EOF
) || raise 124 "Failed to configure grub (slot)"


(
  {
    cat <<EOF
set timeout=1
load_video
set gfxpayload=keep

set superusers="root"
# No user set, so no authentication possible
#password root password

EOF
    cat "${TARGET_BOOT}"/{A,B}_grub.cfg 2>/dev/null

    echo "set default='${SLOT_NAME}'"
  } > "${TARGET_BOOT}/grub/grub.cfg"
) || raise 125 "Failed to configure grub"

echo "GRUB configuration updated for kernel version $version."

