#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-dns.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-test.sh"

# The packet as the server would receive it, in hex.
packet_hex() {
  # shellcheck disable=SC2059 # the format is the packet
  printf "$(dns_packet "$1")" | od -An -tx1 -v | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'
}

HEADER="4e 43 01 00 00 01 00 00 00 00 00 00"
expect "packet: header, labels, type A, class IN" \
  "${HEADER} 03 61 62 63 07 65 78 61 6d 70 6c 65 03 63 6f 6d 00 00 01 00 01" \
  packet_hex "abc.example.com"
expect "packet: a trailing dot is the same name" \
  "$(packet_hex "abc.example.com")" packet_hex "abc.example.com."
expect "packet: % and \\ stay literal" \
  "${HEADER} 03 61 25 62 01 5c 00 00 01 00 01" packet_hex 'a%b.\'

# Replies: id 4e43, QR set, the low nibble of byte 4 is the response code.
reply() {
  printf '4e 43 81 %s 00 01 00 00 00 00 00 00\n' "$1"
}
expect "rcode: NOERROR" "NOERROR" dns_rcode "$(reply 80)"
expect "rcode: NXDOMAIN" "NXDOMAIN" dns_rcode "$(reply 83)"
expect "rcode: SERVFAIL" "SERVFAIL" dns_rcode "$(reply 82)"
expect "rcode: REFUSED" "REFUSED" dns_rcode "$(reply 85)"
expect "rcode: an unnamed code" "RCODE9" dns_rcode "$(reply 89)"
expect "rcode: split over lines, as od prints it" "NXDOMAIN" \
  dns_rcode " 4e 43 81 83 00 01 00 00
 00 00 00 00"
expect "rcode: nothing" "NOANSWER" dns_rcode ""
expect "rcode: too short" "NOANSWER" dns_rcode "4e 43 81 80"
expect "rcode: another id" "NOANSWER" dns_rcode "12 34 81 80 00 01 00 00 00 00 00 00"
expect "rcode: a query, not a reply" "NOANSWER" dns_rcode "4e 43 01 00 00 01 00 00 00 00 00 00"

summary
