#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

ln -sf "${SCRIPT_DIR}/cuos-init.service" /etc/systemd/system/ || exit 1
ln -sf "${SCRIPT_DIR}/cuos-api@.service" /etc/systemd/system/ || exit 1
ln -sf "${SCRIPT_DIR}/cuos-api.socket" /etc/systemd/system/ || exit 1
ln -sf "${SCRIPT_DIR}/cuos-app-init.service" /etc/systemd/system/ || exit 1

ln -sf "${SCRIPT_DIR}"/api.sh /usr/bin/cuos || exit 1

systemctl enable cuos-init.service cuos-api.socket cuos-app-init.service \
  || exit 1
