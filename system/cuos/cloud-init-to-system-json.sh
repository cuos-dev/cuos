#!/bin/bash
set -euo pipefail

# Usage:
#   ./cloud-init-to-system-json.sh <user-data.yaml> [network-config]
#
# Input:
#   USER_DATA_FILE: cloud-init user-data YAML (may include hostname, users, ntp, and optionally network)
#   NETWORK_DATA_FILE (optional): cloud-init network-config YAML (v1 or v2). If given, its network overrides user-data.
#
# Output:
#   Prints the resulting system-json to stdout.

USER_DATA_FILE="${1:-}"
NETWORK_DATA_FILE="${2:-}"

if [[ -z "$USER_DATA_FILE" ]]; then
  echo "Usage: $0 <user-data.yaml> [network-config]" >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: 'yq' (mikefarah v4) is required." >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: 'jq' is required." >&2
  exit 2
fi

yaml2json() {
  local file="$1"
  if [ -n "${file:-}" ] && [ -f "$file" ]; then
    yq eval -o=json "${file}" 2>/dev/null || yq . "${file}"
  else
    echo '{}'
  fi
}

# Prepare a merged JSON stream for conversion:
# - If network-config is provided, extract its 'network' block (or treat the whole document as the network block if root is 'network').
#   Then merge it into user-data as '.network'.

jq -n --slurpfile u <(yaml2json "$USER_DATA_FILE") \
       --slurpfile n <(yaml2json "$NETWORK_DATA_FILE") \
'
  ($n[0].network // $n[0]) as $net |
  if ($net | length) == 0 then
    $u[0]
  else
    $u[0] + {network: $net}
  end
' | jq '

# Helpers
def as_array: if . == null then [] elif (type=="array") then . else [.] end;

def cidr_to_ip_and_mask($cidr):
  ($cidr|tostring) as $c
  | ($c | split("/")) as $parts
  | if ($parts|length) != 2 then error("Invalid CIDR: \($c)") else
      ($parts[0]) as $ip
      | ($parts[1]|tonumber) as $p
      | def oct(p):
          if p >= 8 then 255
          elif p <= 0 then 0
          else 256 - (pow(2; (8 - p)))
          end;
        [ oct($p), oct($p-8), oct($p-16), oct($p-24) ] as $mask_arr
      | { ip: $ip, mask: ($mask_arr | map(tostring) | join(".")) }
    end;

def parse_chpasswd_list:
  if . == null then {}
  else ( tostring
         | split("\n")
         | map(select(length>0))
         | map( (split(":"))
                | if (length>=2) then { (.[0]): (.[1:] | join(":")) } else {} end
              )
         | add )
  end;

def pick_password:
  (.users // []) as $users
  | (.chpasswd.list // null | parse_chpasswd_list) as $kv
  | (
      ($users | map(select(type=="object" and (.passwd!=null)))) as $hits
      | if ($hits|length)>0 then $hits[0].passwd
        else $kv["system-admin"]
        end
    );

# Build interface list for v2
def build_ifaces_v2:
  (.network.ethernets // {} | to_entries | sort_by(.key) | map(.value));

# Dotted mask -> prefix (for v1 static without CIDR)
def dotted_to_prefix($m):
  ($m|tostring|split(".")|map(tonumber)) as $o
  | def ones(x):
      if x==255 then 8
      elif x==254 then 7
      elif x==252 then 6
      elif x==248 then 5
      elif x==240 then 4
      elif x==224 then 3
      elif x==192 then 2
      elif x==128 then 1
      elif x==0 then 0
      else error("Invalid netmask octet: \(x)")
      end;
    (ones($o[0]) + ones($o[1]) + ones($o[2]) + ones($o[3]));

# Build interface list for v1 (legacy) from network.config
def build_ifaces_v1:
  (.network.config // []) as $cfg
  | ($cfg | map(select(type=="object" and (.type//"")=="physical"))) as $phys
  | ($phys | sort_by(.name // ""))
  | map(
      . as $p
      | ( ($p.subnets // []) | if (length>0) then .[0] else {} end ) as $s
      | ($s.type // "") as $stype
      | if $stype == "dhcp" or $stype == "dhcp4" then
          {
            dhcp4: true,
            nameservers: { addresses: (($s.dns_nameservers // ($cfg[] | select(.type=="nameserver") | .address) // []) | as_array | map(tostring)) }
          }
        elif $stype == "static" then
          (
            ($s.address // null) as $addr
            | ($s.netmask // null) as $mask
            | ($s.gateway // null) as $gw
            | ($s.dns_nameservers // ($cfg[] | select(.type=="nameserver") | .address) // []) as $dns
            | if $addr == null then
                error("v1 static subnet missing address")
              else
                if ($addr | tostring | contains("/")) then
                  { addresses: [ ($addr|tostring) ] }
                else
                  if $mask == null then
                    error("v1 static subnet missing netmask for address \($addr)")
                  else
                    (dotted_to_prefix($mask)) as $pfx
                    | { addresses: [ ($addr|tostring) + "/" + ($pfx|tostring) ] }
                  end
                end
              end
            | {
                dhcp4: false
              }
              + .
              + ( if $gw != null then { gateway4: ($gw|tostring) } else {} end )
              + { nameservers: { addresses: ($dns | as_array | map(tostring)) } }
          )
        else
          error("v1 subnet type unsupported or missing for interface \($p.name // "unknown")")
        end
    );

# iface -> target schema
def iface_to_entry($ntp_servers):
  . as $iface
  | ($iface.dhcp4 // false) as $dhcp
  | ($iface.nameservers.addresses | as_array | map(tostring)) as $dns
  | if $dhcp then
      { dhcp: true }
    else
      (
        ($iface.addresses | as_array) as $addrs
        | if ($addrs|length)==0 then error("Static interface missing addresses[]") else . end
        | ($addrs[0] | tostring) as $cidr
        | (cidr_to_ip_and_mask($cidr)) as $am
        | {
            dhcp: false,
            "ip-address": $am.ip,
            "network-mask": $am.mask
          }
          + ( if $iface.gateway4 then { gateway: ($iface.gateway4|tostring) } else {} end )
      )
    end
  | . as $base
  | $base
    + ( if ($dns|length)>0 then { "dns-server": ($dns | join(" ")) } else {} end )
    + ( if ($ntp_servers|length)>0 then { "ntp-server": ($ntp_servers|map(tostring)|join(" ")) } else {} end );

# Entry point
(.fqdn // .hostname) as $hostname
| (.ntp.servers | as_array | map(tostring)) as $ntp_servers
| (
    if ((.network.version // 2) == 1) then
      build_ifaces_v1
    else
      build_ifaces_v2
    end
  ) as $ifaces
| ($ifaces | map(iface_to_entry($ntp_servers))) as $network
| (.password // pick_password) as $pwd
| {}
  + (if $hostname then {hostname:$hostname} else {} end)
  + (if ($network|length)>0 then {network:$network} else {} end)
  + (if $pwd!=null then {system_admin_password:$pwd} else {} end)
'
