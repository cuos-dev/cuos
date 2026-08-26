#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

rm raspberrypi-archive.gpg
#invalid:
#curl -fsSL https://archive.raspberrypi.org/debian/raspberrypi.gpg.key | gpg --dearmor -o raspberrypi-archive.gpg

curl -fsSL --output raspberrypi-archive.gpg "https://github.com/raspberrypi/rpi-image-gen/raw/refs/heads/master/keydir/raspberrypi-archive-keyring.gpg"
