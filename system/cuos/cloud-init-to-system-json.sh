#!/bin/bash

# Input: cloud-init YAML file
INPUT_FILE="$1"
# Output: System JSON
OUTPUT_FILE="$2"

if [[ -z "${INPUT_FILE}" ]]; then
	echo "Input file not found."
	exit 2
fi
if [[ -z "${OUTPUT_FILE}" ]]; then
	echo "Output file not found."
	exit 2
fi

yq '.ntp.servers as $ntp | . * {
  hostname: .hostname,
  network: (
    .network.config // [] | map({
      "dhcp": .dhcp4,
      "ip-address": (if .addresses and (.addresses | length > 0) then (.addresses[0] | split("/")[0]) else null end),
      "network-mask": (if .addresses and (.addresses | length > 0) then
        (
          (.addresses[0] | split("/")[1]) as $cidr |
          {
            "0": "0.0.0.0", "1": "128.0.0.0", "2": "192.0.0.0", "3": "224.0.0.0",
            "4": "240.0.0.0", "5": "248.0.0.0", "6": "252.0.0.0", "7": "254.0.0.0",
            "8": "255.0.0.0", "9": "255.128.0.0", "10": "255.192.0.0", "11": "255.224.0.0",
            "12": "255.240.0.0", "13": "255.248.0.0", "14": "255.252.0.0", "15": "255.254.0.0",
            "16": "255.255.0.0", "17": "255.255.128.0", "18": "255.255.192.0", "19": "255.255.224.0",
            "20": "255.255.240.0", "21": "255.255.248.0", "22": "255.255.252.0", "23": "255.255.254.0",
            "24": "255.255.255.0", "25": "255.255.255.128", "26": "255.255.255.192", "27": "255.255.255.224",
            "28": "255.255.255.240", "29": "255.255.255.248", "30": "255.255.255.252", "31": "255.255.255.254",
            "32": "255.255.255.255"
          }[$cidr]
        )
        else null end),
      "gateway": .gateway4,
      "dns-server": .nameservers.addresses,
      "ntp-server": $ntp
    } | with_entries(select(.value != null)))
  ),
}' "${INPUT_FILE}" > "${OUTPUT_FILE}"

