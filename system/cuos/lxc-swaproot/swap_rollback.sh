#!/swaproot/busybox sh
# SPDX-License-Identifier: Apache-2.0

dirs="bin boot etc home lib lib64 media mnt opt root run sbin srv tmp usr var system.json system_next.json"
# shellcheck disable=SC2123
PATH="/swaproot"

if [ -d "/prev" ]; then
  busybox mkdir -p /next
  cd / || exit 127
  for dir in $dirs; do
    busybox mv "$dir" /next/
    busybox mv /next/sbin/init-old /next/sbin/init
  done
  busybox ls -l /
  cd /prev || exit 127
  for dir in $dirs; do
    busybox mv "$dir" /
  done
  busybox rmdir /prev
  busybox mv /sbin/init-old /sbin/init
fi
