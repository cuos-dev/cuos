#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# netcheck.sh - check the connection to the update registry step by step and
# tell the customer's IT what to fix. Started from the maintenance menu
# (Diagnostics), or as `cuos netcheck`.
#
# Written for a firewall nobody knew about that dropped the TLS handshake by
# server name (SNI): all the update reported was `curl: (35) TLS connect error`.
# Every check prints OK, WARNING or ERROR, and a recommendation for the last
# two; a check whose predecessor failed is SKIPPED instead of failing again.
#
# TLS inspection by the customer is a supported mode - update images are
# verified by digest, not by trusting the TLS connection - so a customer CA is
# a warning, not an error.
#
# The target is the configured update registry, nothing else. The network is
# probed with curl, certificates are read with openssl, and the credentials are
# checked by the docker daemon itself, which is what the update uses. Nothing
# on the system is changed.
#
# Exit code: 0 all ok, 1 at least one warning, 2 at least one error.

set -uo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-dns.sh"

CONFIG_PATH="${CONFIG_PATH:-"/system.json"}"
CUSTOM_CA_DIR="${T_CUSTOM_CA_DIR:-"/usr/local/share/ca-certificates/custom"}"
PUBLIC_CA_DIR="${T_PUBLIC_CA_DIR:-"/usr/share/ca-certificates/mozilla"}"
FILE_VERSION="${T_FILE_VERSION:-"/etc/image"}"
CONNECT_TIMEOUT=5
TLS_TIMEOUT=10

# A server name for the counter-probe that no filter has a reason to block: if
# the server answers it but not the real name, something filters by name.
DUMMY_SNI="example.com"

declare -A TITLE=(
  [gateway]="Router"
  [dns_config]="DNS servers"
  [dns_resolve]="DNS resolution"
  [port]="Port"
  [tls_handshake]="TLS handshake"
  [time]="System time"
  [cert_ca]="Certificate / CA"
  [hostname]="Hostname"
  [tls_connection]="TLS connection"
  [http]="Registry answer"
  [credentials]="Credentials"
)

declare -A STATUS=()
declare -A ROOT=() # for a skipped check: the title of the failure behind it
DETAILS=()
RECOMMENDATIONS=()
ERRORS=0
WARNINGS=0

HOST=""
PORT=""
REG_USER=""
REG_PASS=""
IS_IP=0
TARGET_IP=""
DNS_RCODES=()
TMPD=""
CA_CLASS=""
LEAF=""
CHAIN_COUNT=0
SYS_RC=""
SYS_MSG=""
HTTP_CODE=""
HTTP_TYPE=""

# ------------------------------------------------------------ the outside world
#
# Everything that looks at the machine or the network goes through one of
# these, so the tests can replace them.

is_container() {
  [[ "$(systemd-detect-virt 2>/dev/null)" =~ ^(lxc|docker)$ ]]
}

# One "ADDRESS DEVICE" line per default gateway, IPv4 and IPv6.
default_gateways() {
  { ip -4 route show default; ip -6 route show default; } 2>/dev/null |
    awk '{ for (i = 1; i < NF; i++) { if ($i == "via") gw = $(i + 1); if ($i == "dev") dev = $(i + 1) }
           if (gw != "") print gw, dev; gw = ""; dev = "" }' | sort -u
}

ping_once() {
  local addr="$1" dev="$2"
  if [[ "${addr}" == *:* ]]; then
    [[ "${addr,,}" == fe80:* ]] && addr+="%${dev}"
    ping6 -c 1 -w "${CONNECT_TIMEOUT}" "${addr}" >/dev/null 2>&1
  else
    ping -c 1 -w "${CONNECT_TIMEOUT}" "${addr}" >/dev/null 2>&1
  fi
}

# The neighbour cache state (REACHABLE, STALE, ...) of an address, if any.
neigh_state() {
  ip neigh show "$1" 2>/dev/null | awk '{ print $NF; exit }'
}

nameservers() {
  awk '/^nameserver/ { print $2 }' "${T_RESOLV_CONF:-"/etc/resolv.conf"}" 2>/dev/null
}

has_route() {
  [[ -n "$(ip route get "$1" 2>/dev/null)" ]]
}

# The system resolver, which is also what dockerd asks.
resolve_host() {
  timeout $((CONNECT_TIMEOUT * 2)) getent ahosts "$1" 2>/dev/null
}

# Prints what bash says on failure; the return code is the connect's.
tcp_connect() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  timeout "${CONNECT_TIMEOUT}" bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>&1
}

# curl with its trace (-v) on stderr; whatever -w asks for goes to stdout.
tls_curl() {
  curl -q -sS -v --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${TLS_TIMEOUT}" \
    --proto =https -o /dev/null "$@"
}

ntp_synchronized() {
  timeout "${CONNECT_TIMEOUT}" timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown"
}

now_epoch() {
  date +%s
}

# When this system image was built. Empty if unknown.
build_epoch() {
  stat -c %Y "${FILE_VERSION}" 2>/dev/null
}

# Logs in through the docker daemon, into a throw-away client config so the
# real one is not touched. The password goes in on stdin.
registry_login() {
  DOCKER_CONFIG="${TMPD}/docker" timeout $((TLS_TIMEOUT * 3)) \
    docker login --username "$2" --password-stdin "$1" <<<"$3" 2>&1
}

# ------------------------------------------------------------ pure helpers

# classify_tcp RC MESSAGE -> open | timeout | refused | no_route | failed
classify_tcp() {
  case "$1:$2" in
    0:*) echo "open" ;;
    124:*) echo "timeout" ;;
    *"Connection refused"*) echo "refused" ;;
    *"No route to host"* | *"Network is unreachable"*) echo "no_route" ;;
    *) echo "failed" ;;
  esac
}

# classify_handshake RC, with the curl trace on stdin. Prints one of
# server_hello | close_notify | alert NAME | reset | timeout | connect_failed | eof
#
# Only what came in counts: `(IN), TLS alert`. A fatal alert is a peer that
# speaks TLS and says no. A close_notify, a reset, silence or a bare end of the
# connection where a ServerHello belongs is how a middlebox ends it.
classify_handshake() {
  local rc="$1" trace alert
  trace="$(cat)"
  if grep -q 'TLS handshake, Server hello' <<<"${trace}"; then
    echo "server_hello"
    return
  fi
  alert="$(sed -n 's/^\* .*(IN), TLS alert, \(.*\) ([0-9]*):$/\1/p' <<<"${trace}" | head -n 1)"
  if [[ "${alert}" == "close notify" ]]; then
    echo "close_notify"
  elif [[ -n "${alert}" ]]; then
    echo "alert ${alert}"
  elif grep -q 'Connection reset by peer' <<<"${trace}"; then
    echo "reset"
  elif [[ "${rc}" == "28" ]]; then
    echo "timeout"
  elif ! grep -q 'Client hello' <<<"${trace}"; then
    echo "connect_failed"
  else
    echo "eof"
  fi
}

describe_handshake() {
  case "$1" in
    server_hello) echo "ServerHello received" ;;
    close_notify) echo "aborted (close_notify)" ;;
    alert*) echo "refused (alert: ${1#alert })" ;;
    reset) echo "aborted (connection reset)" ;;
    timeout) echo "no answer (timeout)" ;;
    connect_failed) echo "connection failed" ;;
    *) echo "aborted (connection closed)" ;;
  esac
}

# diagnose_block NO_PQ NO_SNI DUMMY_SNI -> pq_clienthello | sni_block | path_block
# Each argument is the classify_handshake result of that probe.
diagnose_block() {
  if [[ "$1" == "server_hello" ]]; then
    echo "pq_clienthello"
  elif [[ "$2" == "server_hello" || "$3" == "server_hello" ]]; then
    echo "sni_block"
  else
    echo "path_block"
  fi
}

# chain_code RC VERIFY_RESULT MESSAGE -> the OpenSSL verify code of the chain,
# 0 if it is trusted, "aborted" if the probe never got that far. A wrong host
# name also ends in curl error 60, but says nothing about the chain.
chain_code() {
  if [[ "$1" == "0" || "$3" == *"subject name"* || "$3" == *"match target host"* ]]; then
    echo 0
  elif [[ "$1" == "60" && -n "$2" && "$2" != "0" ]]; then
    echo "$2"
  else
    echo "aborted"
  fi
}

# classify_ca PUBLIC_CODE SYSTEM_CODE -> public | customer | time | unknown | other
# The chain was verified twice: against the public CAs only, and against the
# whole system store, which adds custom_ca_certs.
classify_ca() {
  if [[ "$1" == "0" ]]; then
    echo "public"
  elif [[ "$2" == "0" ]]; then
    echo "customer"
  elif [[ "$2" =~ ^(9|10)$ ]]; then
    echo "time"
  elif [[ "$2" =~ ^(2|18|19|20|21)$ ]]; then
    echo "unknown"
  else
    echo "other"
  fi
}

# classify_http CODE CONTENT_TYPE HEADERS -> "STATUS<TAB>DETAIL<TAB>RECOMMENDATION"
classify_http() {
  local code="$1" ctype="${2,,}" headers="$3" location
  location="$(sed -n 's/^[Ll]ocation: *//p' <<<"${headers}" | head -n 1)"
  case "${code}" in
    200)
      if [[ "${ctype}" == *"text/html"* ]]; then
        printf 'warning\tanswered with a web page, not the registry\tA proxy or firewall answers instead of the registry. Check it for a block or login page.\n'
      else
        printf 'ok\tregistry answers (HTTP 200)\t\n'
      fi
      ;;
    401)
      if grep -qi '^www-authenticate:' <<<"${headers}"; then
        printf 'ok\tregistry answers (HTTP 401, asks for credentials)\t\n'
      else
        printf 'warning\tHTTP 401 without a registry challenge\tSomething other than the registry answers - probably a proxy. Allow the device to reach the registry directly.\n'
      fi
      ;;
    3??)
      printf 'warning\tredirected to %s\tA proxy probably redirects to a login or portal page. Allow the device to reach the registry directly.\n' \
        "${location:-another address}"
      ;;
    403) printf 'error\taccess denied (HTTP 403)\tA proxy or firewall in the path probably refuses the request. Allow the registry host for this device.\n' ;;
    404) printf 'error\tno registry at this address (HTTP 404)\tCheck update_registry in the system configuration.\n' ;;
    407) printf 'error\tproxy wants authentication (HTTP 407)\tThe proxy requires credentials the device does not send. Allow the device through the proxy without authentication.\n' ;;
    429) printf 'warning\trate limited (HTTP 429)\tTry again later.\n' ;;
    5??) printf 'error\tserver-side problem (HTTP %s)\tTry again later; contact support if it persists.\n' "${code}" ;;
    *) printf 'error\tunexpected answer (HTTP %s)\tContact support with this output.\n' "${code:-none}" ;;
  esac
}

# classify_login RC OUTPUT -> ok | rejected | denied | failed
classify_login() {
  if [[ "$1" == "0" ]]; then
    echo "ok"
  elif grep -Eqi 'unauthorized|incorrect username or password|\b401\b' <<<"$2"; then
    echo "rejected"
  elif grep -Eqi 'denied|forbidden|\b403\b' <<<"$2"; then
    echo "denied"
  else
    echo "failed"
  fi
}

# An address as it goes in front of ":PORT".
bracket() {
  if [[ "$1" == *:* ]]; then echo "[$1]"; else echo "$1"; fi
}

valid_host() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$1" =~ ^[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*$ ]] && return 0
  [[ ${#1} -le 253 && "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

# Reads the registry the update pulls from - update_registry_proxy before
# update_registry, as image_url in utils.sh does - and its credentials.
load_target() {
  local registry
  registry="$(jq -r '(.update_registry_proxy // .update_registry) // empty' "${CONFIG_PATH}" 2>/dev/null)"
  REG_USER="$(jq -r '.update_registry_user // .update_server_user // ""' "${CONFIG_PATH}" 2>/dev/null)"
  REG_PASS="$(jq -r '.update_registry_password // .update_server_password // ""' "${CONFIG_PATH}" 2>/dev/null)"

  registry="${registry#*://}"
  registry="${registry%%/*}"
  PORT=443
  if [[ "${registry}" =~ ^\[(.*)\](:([0-9]+))?$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    PORT="${BASH_REMATCH[3]:-443}"
  elif [[ "${registry}" =~ ^([^:]*)(:([0-9]+))?$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    PORT="${BASH_REMATCH[3]:-443}"
  else
    HOST="${registry}"
  fi

  if [[ -z "${HOST}" ]]; then
    echo "netcheck: no update_registry in ${CONFIG_PATH}" >&2
    return 1
  fi
  if ! valid_host "${HOST}" || (( 10#${PORT} < 1 || 10#${PORT} > 65535 )); then
    echo "netcheck: invalid update registry: ${registry}" >&2
    return 1
  fi
  [[ "${HOST}" =~ ^[0-9.]+$ || "${HOST}" == *:* ]] && IS_IP=1
  return 0
}

# ------------------------------------------------------------ results

# record ID STATUS DETAIL [RECOMMENDATION]: prints the check with its details
# right away, so the menu shows progress, and keeps the recommendation for the
# end.
record() {
  local id="$1" status="$2" detail="$3" rec="${4:-}" line
  STATUS[${id}]="${status}"
  printf '%-10s%-18s%s\n' "[${status^^}]" "${TITLE[${id}]}" "${detail}"
  for line in "${DETAILS[@]+"${DETAILS[@]}"}"; do
    printf '%28s%s\n' "" "${line}"
  done
  DETAILS=()
  [[ -n "${rec}" ]] && RECOMMENDATIONS+=("${TITLE[${id}]}: ${rec}")
  case "${status}" in
    error) ERRORS=$((ERRORS + 1)) ;;
    warning) WARNINGS=$((WARNINGS + 1)) ;;
  esac
  return 0
}

detail() {
  DETAILS+=("$1")
}

# needs ID DEP...: records ID as skipped, naming the original failure, if a
# dependency failed or was skipped itself.
needs() {
  local id="$1" dep root
  shift
  for dep in "$@"; do
    if [[ "${STATUS[${dep}]:-}" =~ ^(error|skipped)$ ]]; then
      root="${ROOT[${dep}]:-${TITLE[${dep}]}}"
      ROOT[${id}]="${root}"
      record "${id}" skipped "depends on ${root}"
      return 1
    fi
  done
  return 0
}

join() {
  local IFS=","
  echo "$*" | sed 's/,/, /g'
}

# ------------------------------------------------------------ certificates

# split_chain: the PEM blocks of curl's %{certs} on stdin into chain-N.pem,
# leaf first; sets CHAIN_COUNT and LEAF.
split_chain() {
  rm -f "${TMPD}"/chain-*.pem
  awk -v dir="${TMPD}" '
    /-----BEGIN CERTIFICATE-----/ { n++; file = sprintf("%s/chain-%d.pem", dir, n); active = 1 }
    active { print > file }
    /-----END CERTIFICATE-----/ { active = 0; close(file) }
  '
  CHAIN_COUNT="$(find "${TMPD}" -maxdepth 1 -name 'chain-*.pem' | wc -l)"
  LEAF=""
  (( CHAIN_COUNT > 0 )) && LEAF="${TMPD}/chain-1.pem"
  return 0
}

# cert FILE subject|issuer|enddate|fingerprint
cert() {
  case "$2" in
    subject|issuer) openssl x509 -in "$1" -noout "-$2" -nameopt RFC2253 2>/dev/null | sed "s/^$2= *//" ;;
    enddate) openssl x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' ;;
    fingerprint) openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*Fingerprint=//' ;;
  esac
}

describe_cert() {
  detail "$1: $(cert "$2" subject)"
  detail "  SHA-256 $(cert "$2" fingerprint)"
  detail "  valid until $(cert "$2" enddate)"
}

# The public CAs alone, as one bundle; prints its path, nothing if there are none.
public_bundle() {
  local bundle="${TMPD}/public.pem" f
  for f in "${PUBLIC_CA_DIR}"/*.crt; do
    [[ -f "${f}" ]] && cat "${f}"
  done >"${bundle}"
  [[ -s "${bundle}" ]] && echo "${bundle}"
}

# The certificate from custom_ca_certs that FILE is or was issued by, if any.
custom_anchor() {
  local issuer subject f
  issuer="$(cert "$1" issuer)"
  subject="$(cert "$1" subject)"
  for f in "${CUSTOM_CA_DIR}"/*.crt; do
    [[ -f "${f}" ]] || continue
    if [[ "$(cert "${f}" subject)" == "${issuer}" || "$(cert "${f}" subject)" == "${subject}" ]]; then
      echo "${f}"
      return
    fi
  done
}

# ------------------------------------------------------------ the checks

TARGET_URL=""
TARGET_ARGS=()

check_gateway() {
  local gateways=() gw dev reachable=() unreachable=()
  mapfile -t gateways < <(default_gateways)
  if (( ${#gateways[@]} == 0 )); then
    record gateway error "no default route" \
      "Configure a gateway for this device (network settings)."
    return
  fi
  for gw in "${gateways[@]}"; do
    read -r gw dev <<<"${gw}"
    if ping_once "${gw}" "${dev}"; then
      reachable+=("${gw} (${dev})")
    elif [[ "$(neigh_state "${gw}")" =~ ^(REACHABLE|STALE|DELAY|PROBE)$ ]]; then
      reachable+=("${gw} (${dev})")
      detail "${gw}: no answer to ping, but present on the network"
    else
      unreachable+=("${gw} (${dev})")
    fi
  done
  local rec="Check cabling, VLAN and the gateway address; the router may be down."
  if (( ${#unreachable[@]} == 0 )); then
    record gateway ok "$(join "${reachable[@]}")"
  elif (( ${#reachable[@]} > 0 )); then
    record gateway warning "not reachable: $(join "${unreachable[@]}")" "${rec}"
  else
    record gateway error "not reachable: $(join "${unreachable[@]}")" "${rec}"
  fi
}

check_dns_config() {
  if (( IS_IP )); then
    record dns_config skipped "the registry is an IP address"
    return
  fi
  local servers=() server rcode answered=() silent=()
  mapfile -t servers < <(nameservers)
  if (( ${#servers[@]} == 0 )); then
    record dns_config error "no DNS server configured" \
      "Configure DNS servers for this device (network settings)."
    return
  fi
  for server in "${servers[@]}"; do
    if ! has_route "${server}"; then
      silent+=("${server}")
      detail "${server}: no route"
      continue
    fi
    rcode="$(dns_rcode "$(dns_query "${server}" "${HOST}")")"
    if [[ "${rcode}" == "NOANSWER" ]]; then
      silent+=("${server}")
      detail "${server}: no answer"
    else
      answered+=("${server}")
      DNS_RCODES+=("${rcode}")
      detail "${server}: ${rcode}"
    fi
  done
  local rec="Check that the DNS servers are reachable from the device's network and that firewalls allow DNS (UDP/TCP 53) from the device."
  if (( ${#silent[@]} == 0 )); then
    record dns_config ok "$(join "${answered[@]}") answering"
  elif (( ${#answered[@]} > 0 )); then
    record dns_config warning "no answer from $(join "${silent[@]}")" "${rec}"
  else
    record dns_config error "no DNS server answers" "${rec}"
  fi
}

check_dns_resolve() {
  if (( IS_IP )); then
    TARGET_IP="${HOST}"
    record dns_resolve skipped "the registry is an IP address"
    return
  fi
  needs dns_resolve dns_config || return

  local addrs
  addrs="$(resolve_host "${HOST}" | awk '!seen[$1]++ { print $1 }')"
  # IPv4 first, as most networks still prefer it.
  TARGET_IP="$( { grep -v ':' <<<"${addrs}"; grep ':' <<<"${addrs}"; } | grep -m 1 .)"
  if [[ -n "${TARGET_IP}" ]]; then
    record dns_resolve ok "${HOST} -> ${TARGET_IP}"
    return
  fi
  local codes=" ${DNS_RCODES[*]-} "
  if [[ "${codes}" == *" SERVFAIL "* || "${codes}" == *" REFUSED "* ]]; then
    record dns_resolve error "the DNS server refuses or fails to resolve ${HOST}" \
      "The DNS server must resolve public names (recursion or forwarding), ${HOST} included."
  elif [[ "${codes}" == *" NXDOMAIN "* ]]; then
    record dns_resolve error "the DNS server does not know ${HOST}" \
      "The DNS server must resolve public names: forward to the internet, and check split-DNS setups for ${HOST}."
  else
    record dns_resolve error "${HOST} could not be resolved" \
      "Check the DNS servers of this device and that they resolve public names."
  fi
}

check_port() {
  (( IS_IP )) || needs port dns_resolve || return
  local out rc rec="Allow outgoing TCP ${PORT} to ${HOST} in all firewalls in the path."
  out="$(tcp_connect "${TARGET_IP}" "${PORT}")"
  rc=$?
  case "$(classify_tcp "${rc}" "${out}")" in
    open) record port ok "TCP ${PORT} open" ;;
    refused) record port error "TCP ${PORT} rejected (port closed, or firewall REJECT)" "${rec}" ;;
    timeout) record port error "TCP ${PORT}: no answer (firewall DROP)" "${rec}" ;;
    no_route) record port error "TCP ${PORT}: no route to host" "${rec}" ;;
    *) record port error "TCP ${PORT}: connection failed" "${rec}" ;;
  esac
}

# handshake ARGS...: one probe; prints its classify_handshake result.
handshake() {
  local trace rc
  trace="$(tls_curl -k "$@" 2>&1 >/dev/null)"
  rc=$?
  classify_handshake "${rc}" <<<"${trace}"
}

check_tls_handshake() {
  needs tls_handshake port || return

  local main
  main="$(handshake "${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}" "${TARGET_URL}")"
  if [[ "${main}" == "server_hello" ]]; then
    record tls_handshake ok "ServerHello received"
    return
  fi

  # No ServerHello. Ask the same address in three more ways, to find out what
  # in the ClientHello is objected to.
  local ip no_pq no_sni="skipped" dummy="skipped"
  ip="$(bracket "${TARGET_IP}")"
  no_pq="$(handshake --curves X25519 "${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}" "${TARGET_URL}")"
  detail "without post-quantum key share: $(describe_handshake "${no_pq}")"
  # For an IP address no server name is sent anyway.
  if (( ! IS_IP )); then
    no_sni="$(handshake "https://${ip}:${PORT}/v2/")"
    dummy="$(handshake --resolve "${DUMMY_SNI}:${PORT}:${ip}" "https://${DUMMY_SNI}:${PORT}/v2/")"
    detail "without server name (SNI): $(describe_handshake "${no_sni}")"
    detail "with server name ${DUMMY_SNI}: $(describe_handshake "${dummy}")"
  fi

  case "$(diagnose_block "${no_pq}" "${no_sni}" "${dummy}")" in
    pq_clienthello)
      record tls_handshake error "$(describe_handshake "${main}") - the large ClientHello is not accepted" \
        "A firewall or proxy in the path cannot handle the larger TLS ClientHello with a post-quantum key share (X25519MLKEM768). Update the firmware of that device; contact support for a workaround."
      ;;
    sni_block)
      record tls_handshake error "$(describe_handshake "${main}") - blocked by server name" \
        "A firewall or proxy in the path blocks the connection by its server name (SNI). Allow ${HOST} in ALL firewalls and proxies in the path (URL/category filter, application control, TLS inspection rules). Often there is a further firewall (corporate, site, provider) the local contact does not know about."
      ;;
    *)
      if [[ "${main}" == alert* ]]; then
        record tls_handshake error "the server refuses the handshake (${main#alert })" \
          "The server or a proxy in the path refuses the TLS connection. Contact support with this output."
      else
        record tls_handshake error "$(describe_handshake "${main}") - every TLS connection to ${TARGET_IP} is cut" \
          "Something in the path cuts every TLS connection to ${TARGET_IP}:${PORT}, whatever the server name. Allow ${HOST} in all firewalls in the path, including any the local contact may not know about (corporate, site, provider)."
      fi
      ;;
  esac
}

check_time() {
  local now build ntp rec="Configure NTP servers (network settings) and allow NTP (UDP 123) to them. A wrong clock makes certificates look invalid."
  now="$(now_epoch)"
  build="$(build_epoch)"
  if [[ -n "${build}" ]] && (( now < build )); then
    record time error "the clock is before the build date of this system" "${rec}"
  elif is_container; then
    record time info "managed by the host"
  else
    ntp="$(ntp_synchronized)"
    case "${ntp}" in
      yes) record time ok "synchronized (NTP)" ;;
      no) record time warning "not synchronized via NTP" "${rec}" ;;
      *) record time info "NTP state unknown" ;;
    esac
  fi
}

check_cert_ca() {
  needs cert_ca tls_handshake || return

  # The chain as presented, unverified, for reading.
  # Not a pipe: split_chain sets variables.
  split_chain < <(tls_curl -k -w '%{certs}' "${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}" "${TARGET_URL}" 2>/dev/null)

  # The same chain verified against the system store - which holds the public
  # CAs and custom_ca_certs - and against the public CAs alone. The first one
  # is also the full connection, and its answer is the registry's.
  local out sys_code pub_code bundle pub_rc pub_out
  out="$(tls_curl -D "${TMPD}/headers" -w '%{ssl_verify_result}\t%{http_code}\t%{content_type}' \
    "${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}" "${TARGET_URL}" 2>"${TMPD}/trace")"
  SYS_RC=$?
  SYS_MSG="$(grep -m 1 '^curl: (' "${TMPD}/trace")"
  local verify
  IFS=$'\t' read -r verify HTTP_CODE HTTP_TYPE <<<"${out}"
  sys_code="$(chain_code "${SYS_RC}" "${verify}" "${SYS_MSG}")"

  if bundle="$(public_bundle)"; then
    mkdir -p "${TMPD}/none"
    pub_out="$(tls_curl --cacert "${bundle}" --capath "${TMPD}/none" -w '%{ssl_verify_result}' \
      "${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}" "${TARGET_URL}" 2>"${TMPD}/trace-public")"
    pub_rc=$?
    pub_code="$(chain_code "${pub_rc}" "${pub_out}" "$(grep -m 1 '^curl: (' "${TMPD}/trace-public")")"
  else
    pub_code="${sys_code}"
    detail "the list of public CAs is missing: a customer CA cannot be told apart"
  fi

  if [[ "${sys_code}" == "aborted" || "${pub_code}" == "aborted" || -z "${LEAF}" ]]; then
    record cert_ca error "the certificate could not be fetched${SYS_MSG:+: ${SYS_MSG#curl: }}" \
      "The connection broke off although the handshake worked before. Run the check again; if it happens again, contact support with this output."
    return
  fi

  local top="${TMPD}/chain-${CHAIN_COUNT}.pem" anchor
  CA_CLASS="$(classify_ca "${pub_code}" "${sys_code}")"
  case "${CA_CLASS}" in
    public)
      record cert_ca ok "issued by a public CA ($(cert "${top}" issuer | sed -n 's/.*CN=\([^,]*\).*/\1/p'))"
      ;;
    customer)
      anchor="$(custom_anchor "${top}")"
      if [[ -n "${anchor}" ]]; then
        describe_cert "customer CA" "${anchor}"
      else
        detail "customer CA: $(cert "${top}" issuer)"
      fi
      record cert_ca warning "TLS inspection active (supported mode)" \
        "The connection is inspected with a CA of your organisation, which this device trusts. This is supported: update images are verified independently of TLS. Note that the inspection infrastructure sees this traffic, credentials included, in clear text; securing it is your responsibility."
      ;;
    time)
      record cert_ca error "certificate expired or not yet valid" \
        "If the system time is wrong, fix it first (see System time). Otherwise contact support with this output."
      ;;
    unknown)
      describe_cert "topmost certificate" "${top}"
      [[ "$(cert "${top}" issuer)" != "$(cert "${top}" subject)" ]] &&
        detail "  issued by $(cert "${top}" issuer)"
      record cert_ca error "issued by an unknown CA (TLS inspection?)" \
        "The connection is probably inspected by a device whose CA this device does not trust. Two options, both supported:
a) Exempt ${HOST} from TLS inspection.
b) Add the CA certificate of the inspection to custom_ca_certs in the system configuration of the device.
Note: with b) the inspection infrastructure sees this traffic, credentials included, in clear text; securing it is your responsibility."
      ;;
    *)
      record cert_ca error "certificate not accepted${SYS_MSG:+: ${SYS_MSG#curl: }}" \
        "Contact support with this output."
      ;;
  esac
}

check_hostname() {
  needs hostname tls_handshake || return
  if [[ -z "${LEAF}" ]]; then
    ROOT[hostname]="${TITLE[cert_ca]}"
    record hostname skipped "depends on ${TITLE[cert_ca]}"
    return
  fi
  local flag="-checkhost" names
  (( IS_IP )) && flag="-checkip"
  if openssl x509 -in "${LEAF}" -noout "${flag}" "${HOST}" 2>/dev/null | grep -q 'does match'; then
    record hostname ok "certificate is valid for ${HOST}"
    return
  fi
  names="$(openssl x509 -in "${LEAF}" -noout -ext subjectAltName 2>/dev/null | sed -n '2,$p' | tr -d ' \n')"
  detail "certificate is for: ${names:-$(cert "${LEAF}" subject)}"
  local rec="Contact support with this output."
  [[ "${CA_CLASS}" == "customer" ]] &&
    rec="The TLS inspection issues the certificate for the wrong name - check its configuration, or exempt ${HOST} from inspection."
  record hostname error "certificate is not valid for ${HOST}" "${rec}"
}

check_tls_connection() {
  needs tls_connection cert_ca hostname || return
  if [[ "${SYS_RC}" == "0" ]]; then
    record tls_connection ok "established, certificate verified"
  else
    record tls_connection error "${SYS_MSG:-curl failed (${SYS_RC})}" \
      "Contact support with this output."
  fi
}

check_http() {
  needs http tls_connection || return
  local status text rec
  IFS=$'\t' read -r status text rec < <(classify_http "${HTTP_CODE}" "${HTTP_TYPE}" "$(tr -d '\r' <"${TMPD}/headers" 2>/dev/null)")
  record http "${status}" "${text}" "${rec}"
}

check_credentials() {
  if [[ -z "${REG_USER}" || -z "${REG_PASS}" ]]; then
    record credentials info "none configured (anonymous access)"
    return
  fi
  needs credentials http || return
  local out rc
  out="$(registry_login "$(bracket "${HOST}"):${PORT}" "${REG_USER}" "${REG_PASS}")"
  rc=$?
  local rec="Check update_registry_user and update_registry_password in the system configuration, and the licence; contact support."
  case "$(classify_login "${rc}" "${out}")" in
    ok) record credentials ok "accepted" ;;
    rejected) record credentials error "rejected" "${rec}" ;;
    denied) record credentials error "accepted, but access denied" "${rec}" ;;
    *)
      detail "$(grep -m 1 -i 'error' <<<"${out}" | cut -c 1-200)"
      record credentials error "the docker daemon could not log in" \
        "curl reached the registry, docker did not. Docker has its own TLS implementation and proxy settings. Contact support with this output."
      ;;
  esac
}

# ------------------------------------------------------------ the run

main() {
  if (( $# > 0 )); then
    echo "Usage: netcheck.sh - checks the connection to the configured update registry." >&2
    return 2
  fi
  load_target || return 2
  TMPD="$(mktemp -d)"
  trap 'rm -rf "${TMPD}"' EXIT

  printf 'CuOS update connection check - %s:%s\n\n' "${HOST}" "${PORT}"

  check_gateway
  check_dns_config
  check_dns_resolve
  # From here on the connection goes to the address found, so every probe
  # talks to the same server.
  TARGET_URL="https://$(bracket "${HOST}"):${PORT}/v2/"
  TARGET_ARGS=()
  (( IS_IP )) || [[ -z "${TARGET_IP}" ]] || TARGET_ARGS=(--resolve "${HOST}:${PORT}:$(bracket "${TARGET_IP}")")
  check_port
  check_tls_handshake
  check_time
  check_cert_ca
  check_hostname
  check_tls_connection
  check_http
  check_credentials

  local rec
  if (( ${#RECOMMENDATIONS[@]} > 0 )); then
    printf '\nRecommendations\n'
    for rec in "${RECOMMENDATIONS[@]}"; do
      printf '\n%s\n' "${rec}" | fold -s -w 80
    done
  fi
  printf '\nResult: %d error(s), %d warning(s)\n' "${ERRORS}" "${WARNINGS}"
  (( ERRORS > 0 )) && return 2
  (( WARNINGS > 0 )) && return 1
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
  exit $?
fi
