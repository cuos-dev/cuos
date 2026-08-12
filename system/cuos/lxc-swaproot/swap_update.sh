#!/swaproot/busybox sh

dirs="bin boot etc home lib lib64 media mnt opt root run sbin srv tmp usr var system.json system_next.json"
# shellcheck disable=SC2123
PATH="/swaproot"

if [ -d "/next" ]; then
  busybox mkdir -p /prev
  cd / || exit 127
  for dir in $dirs; do
    busybox mv -f "$dir" /prev/
  done
  busybox ls -l /
  cd /next || exit 127
  for dir in $dirs; do
    busybox mv -f "$dir" /
  done
  busybox rmdir /next
  busybox cp /prev/etc/hostname /prev/etc/hosts /prev/etc/resolv.conf /etc/
  busybox cp /prev/etc/network/interfaces /etc/network/
fi
