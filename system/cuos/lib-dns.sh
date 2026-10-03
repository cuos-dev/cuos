#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib-dns.sh - ask one particular DNS server for a name, in plain bash.
#
# getent goes through the system resolver and cannot be pointed at a server,
# so it cannot tell "this server is silent" from "this name does not exist". A
# DNS client (dig, kdig, drill) could, at the cost of a package and its CVEs in
# every image; one A query and the response code of the reply are all that is
# needed here, and bash's /dev/udp is enough for that.

DNS_TIMEOUT="${DNS_TIMEOUT:-5}"

# dns_packet NAME: the printf format of an A query for NAME, id 0x4e43, with
# recursion desired. `%` and `\` in a label are escaped, so a name can never act
# as a printf directive.
dns_packet() {
  local qname="" label
  local -a labels
  IFS=. read -ra labels <<<"${1%.}"
  for label in "${labels[@]}"; do
    qname+="$(printf '\\x%02x' "${#label}")"
    label="${label//\\/\\\\}"
    qname+="${label//%/%%}"
  done
  printf '%s' "\\x4e\\x43\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00${qname}\\x00\\x00\\x01\\x00\\x01"
}

# dns_query SERVER NAME: sends the query to SERVER:53 and prints the reply as hex
# bytes, nothing if none came. `dd count=1` reads exactly one datagram, where
# `head -c` would wait for more.
dns_query() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  timeout "${DNS_TIMEOUT}" bash -c \
    'exec 3<>"/dev/udp/$0/53" || exit 2; printf "$1" >&3; dd bs=4096 count=1 <&3 2>/dev/null | od -An -tx1 -v' \
    "$1" "$(dns_packet "$2")" 2>/dev/null
}

# dns_rcode HEX: the response code of a reply as printed by dns_query - NOERROR,
# NXDOMAIN, SERVFAIL, REFUSED, ... - or NOANSWER for nothing, or for anything
# that is not the reply to our query.
dns_rcode() {
  local -a bytes
  read -ra bytes <<<"${1//$'\n'/ }"
  if (( ${#bytes[@]} < 12 )) || [[ "${bytes[0],,}" != "4e" || "${bytes[1],,}" != "43" ]] ||
    (( (16#${bytes[2]} & 0x80) == 0 )); then
    echo "NOANSWER"
    return
  fi
  case "$((16#${bytes[3]} & 15))" in
    0) echo "NOERROR" ;;
    1) echo "FORMERR" ;;
    2) echo "SERVFAIL" ;;
    3) echo "NXDOMAIN" ;;
    4) echo "NOTIMP" ;;
    5) echo "REFUSED" ;;
    *) echo "RCODE$((16#${bytes[3]} & 15))" ;;
  esac
}
