# SPDX-License-Identifier: Apache-2.0
# QEMU for boot-in-qemu.sh. Build and run from the repository root:
#
#   docker build -t cuos-qemu-test -f image-factory/test/Dockerfile image-factory/test
#   docker run --rm -i --device /dev/kvm -v ./output:/output cuos-qemu-test \
#     bios /output/NAME.img 4G /output/NAME.boot-bios
FROM debian:13.7-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    jq netpbm ovmf qemu-system-x86 qemu-utils socat \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY boot-in-qemu.sh /boot-in-qemu.sh
ENTRYPOINT ["/boot-in-qemu.sh"]
