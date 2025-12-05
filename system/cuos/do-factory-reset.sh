#!/bin/bash

# shellcheck disable=SC2046

echo "Stopping docker"
docker stop $(docker ps -aq) 2>/dev/null
docker rm $(docker ps -aq) 2>/dev/null
docker volume rm $(docker volume ls -q) 2>/dev/null
docker network prune -f
docker system prune -f

sync

echo "Cleaning up @data"
rm -f /data/* 2>/dev/null
for dir in /data/*/; do
  if [[ -d "$dir" && "$dir" != "/data/dhcp/" ]]; then
    echo "Cleaning inside $dir..."
    rm -Rf "${dir:?}"/{*,.*}
  fi
done

rm /etc/hostname

sync

/sbin/reboot
