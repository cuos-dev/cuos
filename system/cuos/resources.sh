#!/bin/bash

virt_type="$(systemd-detect-virt)"
disk_total="$(df --output=size -B1 / | tail -1)"
disk_used="$(df --output=used -B1 / | tail -1)"
disk_free="$(df --output=avail -B1 / | tail -1)"

mem_total="$(free -b | awk '/Mem:/ {print $2}')"
mem_used="$(free -b | awk '/Mem:/ {print $3}')"
mem_available="$(free -b | awk '/Mem:/ {print $7}')"

load_average="$(awk '{print $1}' /proc/loadavg)"
cpu_cores="$(nproc)"
if [[ "${virt_type}" = "lxc" ]]; then
  cpu_usage="$(awk '/^some/ {for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]=="avg60"){print a[2]; exit}}}' /sys/fs/cgroup/cpu.pressure)"
else
  cpu_usage="$(awk -v load="$load_average" -v cores="$cpu_cores" 'BEGIN {printf "%.2f", (load * 100) / cores}')"
fi

# Convert bytes to megabytes
to_mb() {
  awk "BEGIN {printf \"%.2f\", $1 / 1024 / 1024}"
}

network="$(ip -o -4 addr show | awk '$2 ~ /^e/ {print $2, $4}' | while read -r iface ip; do echo "{\"interface\": \"$iface\", \"ip\": \"$ip\"}"; done | jq -s .)"

default_route="$(ip route | awk '/^default/ {print $3}' | head -n1)"
#dns_servers="$(systemd-resolve --status | awk '/DNS Servers:/ {print $3}' | jq -R . | jq -s .)"
dns_servers="$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | jq -R . | jq -s .)"
ntp_servers="$(timedatectl show-timesync --property=Server --value 2>/dev/null | jq -R . | jq -s .)"
routes="$(ip route | jq -R . | jq -s .)"

ntp_active="$(timedatectl show-timesync --property=ServiceActive --value 2>/dev/null)"
ntp_synced="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)"




jq -n \
  --arg virt_type "${virt_type}" \
  --arg disk_total "$(to_mb "$disk_total")" \
  --arg disk_used "$(to_mb "$disk_used")" \
  --arg disk_free "$(to_mb "$disk_free")" \
  --arg mem_total "$(to_mb "$mem_total")" \
  --arg mem_used "$(to_mb "$mem_used")" \
  --arg mem_available "$(to_mb "$mem_available")" \
  --arg cpu_cores "$cpu_cores" \
  --arg cpu_usage "$cpu_usage" \
  --argjson network "$network" \
  --arg default_route "$default_route" \
  --argjson dns_servers "$dns_servers" \
  --argjson ntp_servers "$ntp_servers" \
  --argjson routes "$routes" \
  --arg ntp_active "$ntp_active" \
  --arg ntp_synced "$ntp_synced" \
  '{
    virt_type: $virt_type,
    disk_total_mb: ($disk_total | tonumber),
    disk_used_mb: ($disk_used | tonumber),
    disk_free_mb: ($disk_free | tonumber),
    mem_total_mb: ($mem_total | tonumber),
    mem_used_mb: ($mem_used | tonumber),
    mem_available_mb: ($mem_available | tonumber),
    cpu_cores: ($cpu_cores | tonumber),
    cpu_usage: ($cpu_usage | tonumber),
    network: $network,
    default_route_ip: $default_route,
    dns_servers: $dns_servers,
    ntp_servers: $ntp_servers,
    routes: $routes,
    ntp_service_active: ($ntp_active == "yes"),
    ntp_synchronized: ($ntp_synced == "yes"),
  }'

