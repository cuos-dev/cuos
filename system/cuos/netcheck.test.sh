#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# The MOCK_* variables are inputs of the mocked functions, which shellcheck
# cannot see being read.
# shellcheck disable=SC2034

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

export CONFIG_PATH="${TMP}/system.json"
export T_CUSTOM_CA_DIR="${TMP}/custom"
export T_PUBLIC_CA_DIR="${TMP}/public"
export T_FILE_VERSION="${TMP}/image"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/netcheck.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-test.sh"

# ------------------------------------------------------------ fixtures

# A customer CA and a leaf for registry.example.org, made fresh so they never
# expire under the test.
mkdir -p "${T_CUSTOM_CA_DIR}" "${T_PUBLIC_CA_DIR}"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
  -keyout "${TMP}/ca.key" -out "${TMP}/ca.pem" -subj "/O=Example Corp/CN=Example Inspection CA" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "${TMP}/leaf.key" -out "${TMP}/leaf.csr" -subj "/CN=registry.example.org" 2>/dev/null
openssl x509 -req -in "${TMP}/leaf.csr" -CA "${TMP}/ca.pem" -CAkey "${TMP}/ca.key" -days 1 \
  -extfile <(echo "subjectAltName=DNS:registry.example.org") -out "${TMP}/leaf.pem" 2>/dev/null
cp "${TMP}/ca.pem" "${T_CUSTOM_CA_DIR}/custom_ca_cert_0.crt"
cp "${TMP}/ca.pem" "${T_PUBLIC_CA_DIR}/some-public-ca.crt"

# curl -v traces as curl 8.14 with OpenSSL 3.5 prints them, cut to the lines
# that matter. Captured against a local server and a middlebox simulating each
# case.
TRACE_OK="* Connected to registry.example.org (192.0.2.10) port 443
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384 / X25519MLKEM768 / id-ecPublicKey
* TLSv1.3 (IN), TLS alert, close notify (256):"
TRACE_CLOSE_NOTIFY="* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS alert, close notify (256):
* TLS connect error: error:00000000:lib(0)::reason(0)
* OpenSSL SSL_connect: SSL_ERROR_ZERO_RETURN in connection to registry.example.org:443
curl: (35) TLS connect error: error:00000000:lib(0)::reason(0)"
TRACE_ALERT="* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS alert, handshake failure (552):
* TLS connect error: error:0A000410:SSL routines::ssl/tls alert handshake failure"
TRACE_RESET="* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* Recv failure: Connection reset by peer
* OpenSSL SSL_connect: Connection reset by peer in connection to registry.example.org:443"
TRACE_EOF="* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (OUT), TLS alert, decode error (562):
* TLS connect error: error:0A000126:SSL routines::unexpected eof while reading"
TRACE_TIMEOUT="* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* Operation timed out after 10002 milliseconds with 0 bytes received"
TRACE_REFUSED="* Failed to connect to 192.0.2.10 port 443 after 0 ms: Could not connect to server"

# ------------------------------------------------------------ pure helpers

expect "tcp: open" "open" classify_tcp 0 ""
expect "tcp: timeout" "timeout" classify_tcp 124 ""
expect "tcp: refused" "refused" classify_tcp 1 "bash: connect: Connection refused"
expect "tcp: no route" "no_route" classify_tcp 1 "bash: connect: No route to host"
expect "tcp: unreachable" "no_route" classify_tcp 1 "bash: connect: Network is unreachable"
expect "tcp: anything else" "failed" classify_tcp 1 "bash: something"

handshake_of() {
  classify_handshake "$1" <<<"$2"
}
expect "handshake: ServerHello, even with a close_notify after it" "server_hello" handshake_of 0 "${TRACE_OK}"
expect "handshake: close_notify before ServerHello" "close_notify" handshake_of 35 "${TRACE_CLOSE_NOTIFY}"
expect "handshake: a fatal alert" "alert handshake failure" handshake_of 35 "${TRACE_ALERT}"
expect "handshake: reset" "reset" handshake_of 35 "${TRACE_RESET}"
expect "handshake: our own alert does not count" "eof" handshake_of 35 "${TRACE_EOF}"
expect "handshake: timeout" "timeout" handshake_of 28 "${TRACE_TIMEOUT}"
expect "handshake: no connection" "connect_failed" handshake_of 7 "${TRACE_REFUSED}"

expect "block: only without PQ key share" "pq_clienthello" diagnose_block server_hello close_notify close_notify
expect "block: without SNI" "sni_block" diagnose_block close_notify server_hello close_notify
expect "block: neutral SNI" "sni_block" diagnose_block close_notify close_notify server_hello
expect "block: nothing gets through" "path_block" diagnose_block reset reset reset
expect "block: IP address, SNI probes skipped" "path_block" diagnose_block reset skipped skipped

expect "chain: trusted" "0" chain_code 0 0 ""
expect "chain: unknown issuer" "20" chain_code 60 20 "curl: (60) SSL certificate problem: unable to get local issuer certificate"
expect "chain: a wrong name is not a chain problem" "0" chain_code 60 1 "curl: (60) SSL: no alternative certificate subject name matches target hostname 'x'"
expect "chain: aborted" "aborted" chain_code 35 0 "curl: (35) TLS connect error"

expect "ca: public" "public" classify_ca 0 0
expect "ca: customer (custom_ca_certs)" "customer" classify_ca 20 0
expect "ca: unknown" "unknown" classify_ca 20 20
expect "ca: self-signed, unknown" "unknown" classify_ca 19 19
expect "ca: expired" "time" classify_ca 10 10
expect "ca: something else" "other" classify_ca 7 7

http_status() {
  classify_http "$@" | cut -f1-2
}
CHALLENGE='WWW-Authenticate: Bearer realm="https://registry.example.org/token"'
expect "http: 200" $'ok\tregistry answers (HTTP 200)' http_status 200 "application/json" ""
expect "http: 401 with a challenge" $'ok\tregistry answers (HTTP 401, asks for credentials)' http_status 401 "" "${CHALLENGE}"
expect "http: 401 without a challenge" "warning" eval 'classify_http 401 "" "" | cut -f1'
expect "http: a web page" "warning" eval 'classify_http 200 "text/html; charset=utf-8" "" | cut -f1'
expect "http: redirect names the target" $'warning\tredirected to https://portal.example/login' http_status 302 "" "Location: https://portal.example/login"
expect "http: 403" "error" eval 'classify_http 403 "" "" | cut -f1'
expect "http: 407" $'error\tproxy wants authentication (HTTP 407)' http_status 407 "" ""
expect "http: 503" $'error\tserver-side problem (HTTP 503)' http_status 503 "" ""
expect "http: every result has a recommendation unless ok" "" \
  eval 'for c in 302 403 404 407 429 500 418 ""; do classify_http "$c" "" "" | awk -F"\t" "\$3 == \"\""; done'

expect "login: ok" "ok" classify_login 0 "Login Succeeded"
expect "login: rejected" "rejected" classify_login 1 'Error response from daemon: Get "https://r/v2/": unauthorized: incorrect username or password'
expect "login: denied" "denied" classify_login 1 "Error response from daemon: denied: access forbidden"
expect "login: connection" "failed" classify_login 1 'Error response from daemon: Get "https://r/v2/": net/http: TLS handshake timeout'

target_of() {
  echo "$1" >"${CONFIG_PATH}"
  HOST="" PORT="" IS_IP=0
  load_target 2>/dev/null || { echo "invalid"; return; }
  echo "${HOST} ${PORT} ${IS_IP}"
}
expect "target: name" "registry.example.org 443 0" target_of '{"update_registry": "registry.example.org"}'
expect "target: path and scheme dropped" "registry.example.org 443 0" target_of '{"update_registry": "https://registry.example.org/cuos/"}'
expect "target: port" "registry.example.org 5000 0" target_of '{"update_registry": "registry.example.org:5000/cuos"}'
expect "target: proxy wins, as in image_url" "mirror.example.net 443 0" \
  target_of '{"update_registry": "registry.example.org", "update_registry_proxy": "mirror.example.net/cuos"}'
expect "target: IPv4" "192.0.2.10 443 1" target_of '{"update_registry": "192.0.2.10/cuos"}'
expect "target: IPv6 with port" "2001:db8::1 8443 1" target_of '{"update_registry": "[2001:db8::1]:8443"}'
expect "target: none" "invalid" target_of '{}'
expect "target: not a host name" "invalid" target_of '{"update_registry": "bad;name"}'
expect "target: port out of range" "invalid" target_of '{"update_registry": "registry.example.org:70000"}'

# ------------------------------------------------------------ the whole run
#
# Every function that looks outward is replaced. tls_curl answers by what it
# is asked: the handshake probes (-k) from MOCK_TLS, the chain (%{certs}) from
# the fixtures, the verification against the public CAs (--cacert) and against
# the system store from MOCK_PUB and MOCK_SYS.

default_gateways() { [[ -n "${MOCK_GATEWAY}" ]] && echo "${MOCK_GATEWAY} eth0"; return 0; }
ping_once() { [[ "${MOCK_PING}" == "yes" ]]; }
neigh_state() { echo "FAILED"; }
nameservers() { [[ -n "${MOCK_NAMESERVER}" ]] && echo "${MOCK_NAMESERVER}"; return 0; }
has_route() { return 0; }
dns_query() { [[ -n "${MOCK_DNS_REPLY}" ]] && echo "${MOCK_DNS_REPLY}"; return 0; }
resolve_host() { [[ -n "${MOCK_RESOLVE}" ]] && echo "${MOCK_RESOLVE} STREAM registry.example.org"; return 0; }
tcp_connect() { [[ "${MOCK_PORT}" == "open" ]] && return 0; echo "bash: connect: Connection refused"; return 1; }
is_container() { return 1; }
ntp_synchronized() { echo "${MOCK_NTP}"; }
now_epoch() { echo "${MOCK_NOW}"; }
build_epoch() { echo "1700000000"; }
registry_login() { echo "${MOCK_LOGIN_OUT}"; return "${MOCK_LOGIN_RC}"; }

declare -A MOCK_TLS=()
tls_curl() {
  local args=" $* " probe="main" kind rc
  if [[ "${args}" == *" -k "* && "${args}" == *"%{certs}"* ]]; then
    cat "${TMP}/leaf.pem" "${TMP}/ca.pem"
    return 0
  fi
  if [[ "${args}" == *" -k "* ]]; then
    [[ "${args}" == *"--curves X25519"* ]] && probe="no_pq"
    [[ "${args}" == *"https://192.0.2.10"* ]] && probe="no_sni"
    [[ "${args}" == *"https://example.com"* ]] && probe="dummy"
    kind="${MOCK_TLS[${probe}]:-${MOCK_TLS[main]}}"
    case "${kind}" in
      ok) echo "${TRACE_OK}" >&2; rc=0 ;;
      close_notify) echo "${TRACE_CLOSE_NOTIFY}" >&2; rc=35 ;;
      alert) echo "${TRACE_ALERT}" >&2; rc=35 ;;
      reset) echo "${TRACE_RESET}" >&2; rc=35 ;;
    esac
    return "${rc}"
  fi
  local verify rc msg
  if [[ "${args}" == *" --cacert "* ]]; then
    read -r rc verify <<<"${MOCK_PUB}"
    printf '%s' "${verify}"
  else
    read -r rc verify <<<"${MOCK_SYS}"
    local headers
    headers="$(sed -n 's/.* -D \([^ ]*\) .*/\1/p' <<<"${args}")"
    printf '%s\r\n' "HTTP/1.1 ${MOCK_HTTP}" "${CHALLENGE}" >"${headers}"
    printf '%s\t%s\t%s' "${verify}" "${MOCK_HTTP}" "application/json"
  fi
  case "${verify}" in
    0) msg="" ;;
    1) msg="curl: (60) SSL: no alternative certificate subject name matches target hostname 'registry.example.org'" ;;
    *) msg="curl: (60) SSL certificate problem: unable to get local issuer certificate" ;;
  esac
  [[ -n "${msg}" ]] && echo "${msg}" >&2
  return "${rc}"
}

# A healthy network with a public CA; each scenario changes what it needs.
reset_mocks() {
  echo '{"update_registry": "registry.example.org/cuos", "update_registry_user": "u", "update_registry_password": "s3cr3t-pw"}' >"${CONFIG_PATH}"
  MOCK_GATEWAY="192.0.2.1"
  MOCK_PING="yes"
  MOCK_NAMESERVER="192.0.2.53"
  MOCK_DNS_REPLY="4e 43 81 80 00 01 00 01 00 00 00 00"
  MOCK_RESOLVE="192.0.2.10"
  MOCK_PORT="open"
  MOCK_TLS=([main]=ok)
  MOCK_NTP="yes"
  MOCK_NOW="1800000000"
  MOCK_PUB="0 0"
  MOCK_SYS="0 0"
  MOCK_HTTP="401"
  MOCK_LOGIN_OUT="Login Succeeded"
  MOCK_LOGIN_RC=0
}

# Runs the check in a subshell, as it sets global state; leaves the output in
# OUT and the exit code in RC.
run() {
  OUT="$( (main) )"
  RC=$?
}

# line TITLE: the status column of that check, e.g. "[OK]".
line() {
  grep -E "^\[[A-Z]+\] +$1 " <<<"${OUT}" | awk '{ print $1 }'
}
has() {
  grep -qF -- "$1" <<<"${OUT}" && echo yes || echo no
}

reset_mocks
run
expect "all ok: exit code" "0" echo "${RC}"
expect "all ok: no recommendations" "no" has "Recommendations"
expect "all ok: public CA" "[OK]" line "Certificate / CA"
expect "all ok: credentials checked by docker" "[OK]" line "Credentials"
expect "all ok: target in the header" "yes" has "CuOS update connection check - registry.example.org:443"
expect "usage: no arguments taken" "2" eval '(main --json 2>/dev/null); echo $?'

reset_mocks
MOCK_TLS=([main]=close_notify [dummy]=ok)
run
expect "SNI block: exit code" "2" echo "${RC}"
expect "SNI block: the handshake" "[ERROR]" line "TLS handshake"
expect "SNI block: named" "yes" has "blocked by server name"
expect "SNI block: all firewalls" "yes" has "in ALL firewalls and proxies"
expect "SNI block: the certificate is skipped" "[SKIPPED]" line "Certificate / CA"
expect "SNI block: the skip names the cause" "yes" has "Credentials       depends on TLS handshake"
expect "SNI block: time is still checked" "[OK]" line "System time"

reset_mocks
MOCK_TLS=([main]=close_notify [no_pq]=ok)
run
expect "PQ ClientHello: named" "yes" has "the large ClientHello is not accepted"
expect "PQ ClientHello: firmware" "yes" has "Update the firmware"

reset_mocks
MOCK_TLS=([main]=reset)
run
expect "path block: named" "yes" has "every TLS connection to 192.0.2.10 is cut"

reset_mocks
MOCK_TLS=([main]=alert)
run
expect "fatal alert: a refusal, not a middlebox" "yes" has "the server refuses the handshake (handshake failure)"

reset_mocks
MOCK_PUB="60 20"
run
expect "customer CA: exit code" "1" echo "${RC}"
expect "customer CA: warning" "[WARNING]" line "Certificate / CA"
expect "customer CA: supported mode" "yes" has "TLS inspection active (supported mode)"
expect "customer CA: subject" "yes" has "customer CA: CN=Example Inspection CA,O=Example Corp"
expect "customer CA: fingerprint" "yes" has "SHA-256 $(openssl x509 -in "${TMP}/ca.pem" -noout -fingerprint -sha256 | sed 's/^.*=//')"
expect "customer CA: expiry" "yes" has "valid until $(openssl x509 -in "${TMP}/ca.pem" -noout -enddate | sed 's/^notAfter=//')"
expect "customer CA: clear text" "yes" has "in clear text"
expect "customer CA: the rest goes on" "[OK]" line "Credentials"

reset_mocks
MOCK_PUB="60 20"
MOCK_SYS="60 20"
run
expect "unknown CA: error" "[ERROR]" line "Certificate / CA"
expect "unknown CA: option a" "yes" has "a) Exempt registry.example.org from TLS inspection."
expect "unknown CA: option b, the vendor" "yes" has "vendor of the device to include it in its image"
expect "unknown CA: option b, custom_ca_certs" "yes" has "add it to custom_ca_certs"
expect "unknown CA: the hostname is still checked" "[OK]" line "Hostname"
expect "unknown CA: the connection is skipped" "[SKIPPED]" line "TLS connection"

reset_mocks
MOCK_SYS="60 1"
MOCK_PUB="60 1"
echo '{"update_registry": "other.example.org"}' >"${CONFIG_PATH}"
run
expect "wrong name: the CA is fine" "[OK]" line "Certificate / CA"
expect "wrong name: hostname" "[ERROR]" line "Hostname"
expect "wrong name: what the certificate is for" "yes" has "certificate is for: DNS:registry.example.org"

reset_mocks
rm "${T_PUBLIC_CA_DIR}"/*.crt
run
expect "no public CA list: not a customer CA" "[OK]" line "Certificate / CA"
expect "no public CA list: said" "yes" has "the list of public CAs is missing"
cp "${TMP}/ca.pem" "${T_PUBLIC_CA_DIR}/some-public-ca.crt"

reset_mocks
MOCK_NAMESERVER=""
run
expect "no DNS server: error" "[ERROR]" line "DNS servers"
expect "no DNS server: resolution skipped" "[SKIPPED]" line "DNS resolution"
expect "no DNS server: the chain names the cause" "yes" has "Credentials       depends on DNS servers"

reset_mocks
MOCK_DNS_REPLY="4e 43 81 83 00 01 00 00 00 00 00 00"
MOCK_RESOLVE=""
run
expect "NXDOMAIN: told apart" "yes" has "the DNS server does not know registry.example.org"

reset_mocks
echo '{"update_registry": "192.0.2.10/cuos"}' >"${CONFIG_PATH}"
MOCK_TLS=([main]=close_notify)
run
expect "IP registry: DNS skipped" "[SKIPPED]" line "DNS servers"
expect "IP registry: the port is checked" "[OK]" line "Port"
expect "IP registry: no SNI probes" "no" has "with server name example.com"
expect "IP registry: no credentials" "[INFO]" line "Credentials"

reset_mocks
MOCK_PORT="closed"
run
expect "port closed: error" "yes" has "TCP 443 rejected"

reset_mocks
MOCK_GATEWAY=""
run
expect "no default route: error" "[ERROR]" line "Router"
expect "no default route: DNS is still tried" "[OK]" line "DNS servers"

reset_mocks
MOCK_PING="no"
run
expect "router silent: error" "yes" has "not reachable: 192.0.2.1 (eth0)"

reset_mocks
MOCK_NOW="1600000000"
run
expect "clock before the build: error" "yes" has "the clock is before the build date"
reset_mocks
MOCK_NTP="no"
run
expect "no NTP: warning" "[WARNING]" line "System time"

reset_mocks
MOCK_LOGIN_RC=1
MOCK_LOGIN_OUT='Error response from daemon: Get "https://registry.example.org/v2/": unauthorized: incorrect username or password'
run
expect "credentials rejected" "yes" has "[ERROR]   Credentials       rejected"
expect "credentials: the password never shows" "no" has "s3cr3t-pw"

reset_mocks
MOCK_HTTP="407"
run
expect "proxy auth: error" "[ERROR]" line "Registry answer"
expect "proxy auth: credentials skipped" "[SKIPPED]" line "Credentials"

summary
