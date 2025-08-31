#!/bin/bash

export CONFIG_PATH="/system.json"

jq '{
    "log-level": "info",
    "storage-driver": "overlay2",
    "data-root": "/data/docker",
    "bip": (.docker_bridge_net // "10.235.255.1/24"),
    "default-address-pools": [
            {
                    "base": (.docker_net_space // "10.235.128.0/17"),
                    "size": (.docker_net_space_size // 26) #=64 different CTs
                    # total: 4*128 = 512 networks
            }
    ],
    "no-new-privileges": true,
    "live-restore": true,
    "userland-proxy": false,
    "default-ulimits": {
      "nofile": {
          "Hard": 20000,
          "Name": "nofile",
          "Soft": 20000
      }
    },
    "seccomp-profile": "/etc/docker/seccomp-default.json"
}' "${CONFIG_PATH}" >/etc/docker/daemon.json
