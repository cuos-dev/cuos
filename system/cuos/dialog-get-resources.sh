#!/usr/bin/env bash
# Real system resources report (no API, no installed-state)
# Safe: read-only, uses common tools and /proc
# Prints a structured report to stdout.
#
# Optional: call check_resources_direct_dialog to show in dialog.

set -Euo pipefail

# --- helpers ---------------------------------------------------------

EXCLUDE_IFACES_REGEX="${EXCLUDE_IFACES_REGEX:-^(docker0|docker.*|br-.*|veth.*)$}"

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

fmt_secs() {
  # format seconds to d h m s
  local s="${1:-0}" d h m
  d=$(( s/86400 )); s=$(( s%86400 ))
  h=$(( s/3600 ));  s=$(( s%3600 ))
  m=$(( s/60 ));    s=$(( s%60 ))
  if (( d > 0 )); then printf "%dd %02dh %02dm %02ds" "$d" "$h" "$m" "$s"
  elif (( h > 0 )); then printf "%dh %02dm %02ds" "$h" "$m" "$s"
  elif (( m > 0 )); then printf "%dm %02ds" "$m" "$s"
  else printf "%ds" "$s"; fi
}

kv_from_meminfo() {
  # print value in kB (numeric) for key
  local key="$1"
  awk -v K="$key" '$1==K":"{print $2}' /proc/meminfo 2>/dev/null
}

cpu_model() {
  awk -F: '/^model name[ \t]*:/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null
}

cpu_mhz_avg() {
  awk -F: '/^cpu MHz[ \t]*:/{sum+=$2; n++} END{if(n>0){printf "%.0f\n", sum/n}}' /proc/cpuinfo 2>/dev/null
}

cpu_cores_count() {
  if cmd_exists nproc; then nproc
  else awk -F: '/^processor[ \t]*:/{c++} END{print c+0}' /proc/cpuinfo 2>/dev/null
  fi
}

loadavg_line() {
  if [[ -r /proc/loadavg ]]; then
    awk '{print $1" "$2" "$3" (1/5/15 min)"}' /proc/loadavg
  else
    if cmd_exists uptime; then uptime | sed 's/^.*load average: //'
    else echo "n/a"
    fi
  fi
}

root_df_line() {
  df -h -T / 2>/dev/null | awk 'NR==1 || NR==2'
}

df_summary() {
  # Exclude pseudo filesystems; show top few
  df -h -T -x tmpfs -x devtmpfs -x overlay 2>/dev/null | awk 'NR==1 || NR<=8'
}

list_dns() {
  if [[ -f /etc/resolv.conf ]]; then
    awk '/^nameserver[ \t]+/{print $2}' /etc/resolv.conf | sed 's/^/ - /'
  fi
}

ip_addrs_brief() {
  if cmd_exists ip; then
    ip -br addr show 2>/dev/null | awk -v R="$EXCLUDE_IFACES_REGEX" '$1 !~ R'
  else
    echo "ip command not available."
  fi
}

ip_links_brief() {
  if cmd_exists ip; then
    ip -br link show 2>/dev/null | awk -v R="$EXCLUDE_IFACES_REGEX" '$1 !~ R'
  else
    echo "ip command not available."
  fi
}

show_route() {
  if cmd_exists ip; then
    ip route show 2>/dev/null
  fi
}

os_pretty() {
  if cmd_exists hostnamectl; then
    hostnamectl 2>/dev/null | sed -n '1,8p'
  elif [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    echo "Operating System: ${PRETTY_NAME:-unknown}"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
  else
    echo "Kernel: $(uname -srmo 2>/dev/null || uname -a)"
  fi
}

uptime_secs() {
  awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0
}

top_cpu_governor() {
  # best-effort; may not exist in VMs/containers
  local g
  g=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
  [[ -n "$g" ]] && echo "$g" || echo "n/a"
}

# --- main report -----------------------------------------------------

get_resources() {
  # Time and host
  local now tz
  now="$(date '+%F %T' 2>/dev/null || date)"
  tz="$(date '+%Z (%z)' 2>/dev/null || echo "")"

  # System section
  echo "System Information"
  echo "------------------"
  echo "Hostname: $(hostname 2>/dev/null || echo n/a)"
  os_pretty
  echo "Time: $now $tz"
  local up; up="$(uptime_secs)"
  echo "Uptime: $(fmt_secs "${up:-0}")"
  echo

  # CPU section
  local cores model mhz gov load
  cores="$(cpu_cores_count)"
  model="$(cpu_model)"; [[ -z "$model" ]] && model="n/a"
  mhz="$(cpu_mhz_avg)"; [[ -z "$mhz" ]] && mhz="n/a"
  gov="$(top_cpu_governor)"
  load="$(loadavg_line)"
  echo "CPU"
  echo "---"
  echo "Model: $model"
  echo "Cores: ${cores:-n/a}"
  echo "Avg Frequency (MHz): ${mhz}"
  echo "Governor: ${gov}"
  echo "Load Average: ${load}"
  echo

  # Memory section (from /proc/meminfo)
  local mt ma st sf bu ca
  mt="$(kv_from_meminfo MemTotal)"
  ma="$(kv_from_meminfo MemAvailable)"
  st="$(kv_from_meminfo SwapTotal)"
  sf="$(kv_from_meminfo SwapFree)"
  bu="$(kv_from_meminfo Buffers)"
  ca="$(kv_from_meminfo Cached)"

  # Convert kB to human MiB/GB approximations
  _kb_to_mib() { awk -v k="${1:-0}" 'BEGIN{printf "%.1f", k/1024}'; }
  _kb_to_gib() { awk -v k="${1:-0}" 'BEGIN{printf "%.2f", k/1048576}'; }

  local used pct
  if [[ -n "$mt" && -n "$ma" ]]; then
    used=$(( mt - ma ))
    pct=$(awk -v u="$used" -v t="$mt" 'BEGIN{ if(t>0) printf "%.1f", (u*100.0)/t; else print "n/a"}')
  fi

  echo "Memory"
  echo "------"
  if [[ -n "$mt" ]]; then
    echo "Total: $(_kb_to_gib "$mt") GiB"
    echo "Available: $(_kb_to_gib "${ma:-0}") GiB"
    echo "Used (approx = Total-Available): $(_kb_to_gib "${used:-0}") GiB (${pct:-n/a}%)"
    echo "Buffers/Cache: $(_kb_to_mib "${bu:-0}") MiB / $(_kb_to_mib "${ca:-0}") MiB"
  else
    echo "Meminfo not available."
  fi
  echo "Swap Total: $(_kb_to_gib "${st:-0}") GiB"
  echo "Swap Free:  $(_kb_to_gib "${sf:-0}") GiB"
  echo

  # Disk section
  echo "Disk Usage"
  echo "----------"
  echo "(Root filesystem)"
  root_df_line
  echo
  echo "(Top filesystems)"
  df_summary
  echo

  # Network section
  echo "Network"
  echo "-------"
  echo "(Interfaces - brief)"
  ip_links_brief
  echo
  echo "(Addresses - brief)"
  ip_addrs_brief
  echo
  echo "(Routes)"
  show_route
  echo
  echo "(DNS from /etc/resolv.conf)"
  list_dns
  echo

}

if [[ -f "${SCRIPT_DIR}/custom-dialog.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/custom-dialog.sh"
fi

get_resources
