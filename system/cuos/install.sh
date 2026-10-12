#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# Boot backend to activate: grub, rpi or lxc (lxc has no kernel install)
TYPE="$1"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

ln -sf "${SCRIPT_DIR}/cuos-init.service" /etc/systemd/system/ || exit 1
ln -sf "${SCRIPT_DIR}/cuos-api@.service" /etc/systemd/system/ || exit 1
ln -sf "${SCRIPT_DIR}/cuos-api.socket" /etc/systemd/system/ || exit 1
ln -sf "${SCRIPT_DIR}/cuos-app-init.service" /etc/systemd/system/ || exit 1

ln -sf "${SCRIPT_DIR}"/api.sh /usr/bin/cuos || exit 1

if [[ -f "${SCRIPT_DIR}/install-kernel-${TYPE}.sh" ]]; then
  mv "${SCRIPT_DIR}/install-kernel-${TYPE}.sh" "${SCRIPT_DIR}/install-kernel.sh" || exit 1
  mv "${SCRIPT_DIR}/install-kernel-${TYPE}-rollback.sh" "${SCRIPT_DIR}/install-kernel-rollback.sh" || exit 1
fi

systemctl enable cuos-init.service cuos-api.socket cuos-app-init.service \
  || exit 1

# The image is replaced as a whole, never upgraded by apt, and holds no ext4 on
# LVM for e2scrub to check.
systemctl mask apt-daily.timer apt-daily-upgrade.timer dpkg-db-backup.timer \
  e2scrub_all.timer || exit 1

