#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

cd /etc/systemd/system/ || exit 127
ln -sf "${SCRIPT_DIR}"/cuos-init.service || exit 1
ln -sf "${SCRIPT_DIR}"/cuos-api.service || exit 1
ln -sf "${SCRIPT_DIR}"/cuos-api.socket || exit 1
ln -sf "${SCRIPT_DIR}"/cuos-app.service || exit 1

ln -sf "${SCRIPT_DIR}"/api.sh /usr/bin/cuos || exit 1

systemctl enable cuos-init.service cuos-api.socket cuos-app.service \
  || exit 1
