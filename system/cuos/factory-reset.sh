#!/bin/bash

# shellcheck disable=SC2046

echo "Stopping docker"
docker stop $(docker ps -aq) 2>/dev/null
docker rm $(docker ps -aq) 2>/dev/null
docker volume rm $(docker volume ls -q) 2>/dev/null
docker network prune -f
docker system prune -f

sync

systemctl stop cuos-app docker docker.socket


echo "Cleaning up @data"
for dir in /data/*/; do
  if [[ -d "$dir" && "$dir" != "/data/dhcp/" ]]; then
    echo "Cleaning inside $dir..."
    rm -Rf "${dir:?}"/{*,.*}
  fi
done

sync

/sbin/reboot
