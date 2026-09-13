<!-- GENERATED FILE - do not edit by hand.
     Source:     system/cuos/system-schema.json
     Regenerate: npm run docs:system-json
-->

# CuOS System Configuration Schema

Schema for configuring CuOS system parameters including networking, update sources, and image versions.


**Properties**

|Name|Type|Description|Required|
|----|----|-----------|--------|
|**update\_registry**|`string`|URL of the registry used for system updates (e.g., https://update.example.com)<br/>||
|**update\_registry\_proxy**|`string`|URL of the registry proxy used for system updates<br/>||
|**update\_registry\_user**|`string`|Username for accessing the update registry<br/>||
|**update\_registry\_password**|`string`|Password for accessing the update registry<br/>||
|**hostname**|`string`|Fully Qualified Domain Name (FQDN) of the system<br/>||
|[**network**](#network)|`object[]`|List of network interface configurations<br/>||
|**docker\_net\_space**|`string`|CIDR notation for Docker container network space (e.g., '10.235.128.0/18')<br/>Default: `"10.235.128.0/18"`<br/>Pattern: `^\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$`<br/>||
|**docker\_net\_space\_size**|`number`|Subnet size for Docker container networks (CIDR suffix)<br/>Default: `26`<br/>Minimum: `0`<br/>Maximum: `32`<br/>||
|**custom\_ca\_certs**||Custom CA certificates to be trusted by the system<br/>||
|**swap\_size**|`number`|Swap size in GB (will only be extended if enough disk space is available)<br/>Default: `8`<br/>Minimum: `0`<br/>||
|**init\_image**|`string`|CuOS Init App to start: the one container CuOS runs, and from which everything else is started. CuOS IaC is the default one, pinned by cuos-release's release.json<br/>Minimal Length: `1`<br/>||
|**init\_image\_version**|`string`|Version of the CuOS Init App<br/>Minimal Length: `1`<br/>||
|**init\_image\_digest**|`string`|Digest of the CuOS Init App for integrity check (optional)<br/>||
|**updater\_image**|`string`|Image used for updating the system<br/>Minimal Length: `1`<br/>||
|**updater\_image\_version**|`string`|Version of the updater image<br/>Minimal Length: `1`<br/>||
|**updater\_image\_digest**|`string`|Digest of the updater image for integrity check (optional)<br/>||
|**os\_image**|`string`|Operating system image<br/>Minimal Length: `1`<br/>||
|**os\_image\_version**|`string`|Version of the operating system image<br/>Minimal Length: `1`<br/>||
|**os\_image\_digest**|`string`|Digest of the OS image for integrity check (optional)<br/>||
|**keyboard\_model**|`string`|Keyboard Model<br/>Pattern: `^[A-Za-z]+[0-9]+$`<br/>||
|**keyboard\_layout**|`string`|Keyboard Layout<br/>Pattern: `^[A-Za-z]{2}$`<br/>||
|**keyboard\_variant**|`string`|Keyboard Variant<br/>Pattern: `^[A-Za-z0-9_-]{1,32}$`<br/>||
|**os\_root\_password**|`string`|Root Password for the operating system: local login or SSH - hash or password<br/>||
|[**os\_root\_authorized\_keys**](#os_root_authorized_keys)|`string[]`|SSH public keys accepted for root login, written to /root/.ssh/authorized_keys on every boot. Key-based login works even without 'os_root_password'; without either, the root account is locked<br/>||
|**os\_ssh\_server**|`boolean`|Activate SSH server for the operating system, on port 4222<br/>||
|**console\_expert\_password**|`string`|Password for the expert menu of the console interface<br/>||
|**console\_password**|`string`|Password for the console interface - hash or password<br/>||
|**product\_name**|`string`|Product name shown in the boot menu and the installer, and used as the first part of the built artefact's file name (default: 'CuOS', or 'CuOS IaC' when the init image is a cuos-iac image)<br/>||
|**system\_name**|`string`|Name of this particular system, used as the second part of the built artefact's file name (default: the hostname, else the configuration file or directory name)<br/>||
|**platform**|`string`|Target platform to build for, selecting the '<platform>_image' key and falling back to 'os_image' (e.g. 'x86_64', 'rpi-arm64', 'rpi-arm32', 'orangepi-zero3', 'lxc'). Overridden by 'tool.sh --platform'; defaults to the build host's architecture<br/>||
|**boot\_layout**|`string`|Disk layout and boot chain to build: 'mbr' for an MBR disk with a FAT boot partition (Raspberry Pi, Orange Pi), 'gpt' for a GPT disk with BIOS and UEFI GRUB (PC-style firmware). Only needed for a platform the build tool does not know. Overridden by 'tool.sh --layout'<br/>Enum: `"mbr"`, `"gpt"`, `"rpi"`, `"grub"`<br/>||

**Example**

```json
{
    "network": [
        {
            "dhcp": false
        }
    ],
    "docker_net_space": "10.235.128.0/18",
    "docker_net_space_size": 26,
    "swap_size": 8
}
```

   
<a name="network"></a>
## network\[\]: array

List of network interface configurations


**Items**

**Item Properties**

|Name|Type|Description|Required|
|----|----|-----------|--------|
|**name**|`string`|Interface name for interface identification<br/>Pattern: `^e[0-9A-Za-z]+$`<br/>||
|**mac\-address**|`string`|MAC address for interface identification<br/>Pattern: `^(?:[0-9A-Fa-f]{2}[-:](?:[0-9A-Fa-f]{2}[-:]){4}[0-9A-Fa-f]{2}\|[0-9A-Fa-f]{12})$`<br/>||
|**dhcp**|`boolean`|Enable DHCP for this interface<br/>Default: `false`<br/>||
|**ip\-address**|`string`|Static IPv4 address (required if DHCP is false)<br/>Pattern: `^\d{1,3}(\.\d{1,3}){3}$`<br/>||
|**network\-mask**|`string`|IPv4 subnet mask (required if DHCP is false)<br/>Pattern: `^\d{1,3}(\.\d{1,3}){3}$`<br/>||
|**gateway**|`string`|IPv4 gateway address<br/>Pattern: `^\d{1,3}(\.\d{1,3}){3}$`<br/>||
|**dns\-server**||DNS server(s) for this interface<br/>||
|**ntp\-server**||NTP server(s) for time synchronization<br/>||
|**routes**||Static routes for this interface. Can be a single object or an array of objects.<br/>||

**Example**

```json
[
    {
        "dhcp": false
    }
]
```

   
<a name="os_root_authorized_keys"></a>
## os\_root\_authorized\_keys\[\]: array

SSH public keys accepted for root login, written to /root/.ssh/authorized_keys on every boot. Key-based login works even without 'os_root_password'; without either, the root account is locked


**Items**

**Item Type:** `string`   

---

*This page is generated from [`system/cuos/system-schema.json`](../../system/cuos/system-schema.json),
the schema CuOS validates `system.json` against at boot. Edit the schema, then run
`npm run docs:system-json`.*

<!-- schema-sha256: 2b8d59d977d83713a0d37d99c501e3f52effcdff0113d0417e62ebc448cc1ef7 -->
