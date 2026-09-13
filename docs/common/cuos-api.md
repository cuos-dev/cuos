# CuOS API Reference

## Overview

The CuOS API provides a comprehensive interface for system management and monitoring. It's accessible via on the host via shell commands and in the containers via a UNIX socket.

## Basic Usage

The API can be accessed through the `cuos` command:

```bash
cuos <command>
```

## Core Commands

### System Information

```bash
# See help page
cuos --help

# Get system version
cuos version

# Get system state
cuos state

# Get system resources
cuos resources

# Check the invariants of this system
cuos selftest
```

### System Management

```bash
# Update system
cuos update - <<< $CONFIG

# Rollback to previous version
cuos rollback

# Reboot system
cuos reboot

# Shutdown system
cuos shutdown
```

### Network Configuration

```bash
# Set network configuration
cuos patch-network - <<< $NETWORK_CONFIG

# Set hostname
cuos patch-hostname - <<< $MY_HOSTNAME
```

### Resource Monitoring

The resources command returns a JSON object with system metrics:

```bash
cuos resources
```

Example output:
```json
{
  "cpu_cores": 4,
  "cpu_usage": 25.5,
  "mem_total_mb": 8192,
  "mem_used_mb": 2048,
  "mem_available_mb": 6144,
  "disk_total_mb": 32768,
  "disk_used_mb": 12288,
  "disk_free_mb": 20480,
  "network": [
    {
      "interface": "eth0",
      "ip": "192.168.1.100/24"
    }
  ],
  "default_route_ip": "192.168.1.1"
}
```

### Self-test

`cuos selftest` reads the system and reports whether its invariants hold —
useful in a support case, and as the assertion an automated test makes. It
changes nothing.

```json
{
  "ok": false,
  "summary": { "ok": 9, "failed": 1, "skipped": 1 },
  "checks": [
    { "id": "slot", "status": "ok", "detail": "A" },
    { "id": "subvolumes", "status": "skipped", "detail": "a container has no subvolumes; the root is swapped instead" },
    { "id": "app", "status": "failed", "detail": "cuos-app is exited" }
  ]
}
```

Checked: `config`, `version`, `slot`, `subvolumes`, `state`, `docker`, `app`,
`network`, `hostname`, `ssh`, `log`. A check is **skipped** when it does not
apply to this kind of system — a container has no subvolumes, and its interface
is configured by its host — never to hide a problem.

**Read `ok` from the output, not the exit code**: the API exits 0 for every
command, because systemd socket activation stops working otherwise.

## Using the API in Your Application

### Error Handling

The API returns standard exit codes:
- 0: Success
- 1: General error
- 2: No new version available
- 3: No space left for update

**Except when invoked as `cuos <command>`**, where the exit code is always 0 —
see the note under Self-test. Read the result from the output.


## API Commands Reference

| Command | Description | Input JSON | Output JSON | Notes |
|---------|-------------|------------|-------------|--------|
| help | See help page | `{}` | Help page | |
| version | Show current system version | `{}` | String: "registry/image:tag" | Returns current active system image |
| state | Show current OS system state | `{}` | `{ "state": "running\|updating\|error" }` | System operational state |
| update | Apply system update | `{ "config": new system config }` | Status messages | Initiates system update |
| rollback | Rollback last update | `{}` | Status messages | Reverts to previous version |
| resources | Show system resources | `{}` | `{ "cpu_cores": number, "cpu_usage": number, ... }` | System metrics |
| selftest | Check this system's invariants | `{}` | `{ "ok": bool, "summary": {...}, "checks": [...] }` | Read-only; see [Self-test](#self-test) |
| patch | Patch the current system | `{ "config": partial system config }` | Status message | No slot change |
| patch-network | Set network configuration | `{"network_id": 0,"config": {"dhcp": true}}` | Status message | See [Documentation system.json](./system-json.md) |
| patch-hostname | Set system hostname | `"myhostname"` | Status message | Set new hostname |
| log | Get reports | `{}` | Report lines | `cuos log -f` follows |
| factory-reset | Reset to a clean baseline | `{}` | Status messages | Destructive; runs asynchronously |
| trigger-update | Ask the CuOS Init App to update | `{}` | Status messages | Runs `/api/cuos-trigger-update` in the app, else `cuos update` — see [Your CuOS Init App](./cuos-init-app.md#in-container-hooks) |
| app | Call the app's own API | passed through | the app's output | Runs `/api/trigger` in the app |
| report | Write a report | `{ "id": ..., "message": ... }` | — | Used by the system's own scripts |
| reboot, shutdown | Restart or power off | `{}` | Status message | |

## API Integration Examples

### Bash Implementation
```bash
# From cuos-iac/iac/entrypoint.sh
cuos_api() {
    local command="$1"
    local json_data="${2:-""}"
    if [[ ! -S $SOCKET_PATH ]]; then
        echo "Socket does not exist: $SOCKET_PATH"
        return 2
    fi
    if [[ "${json_data}" == "-" ]]; then
        json_data="$(cat)"
    fi

    # open file descriptor for socat
    exec 3> >(socat - UNIX-CONNECT:$SOCKET_PATH)
    local socat_pid="$!"

    # Send command
    echo "${json_data:-"{}"}" | jq -c --arg command "$command" '.command = $command' >&3
    wait -f "${socat_pid}"
    
    local return_code="$?"
    if [[ "${return_code}" != "0" ]]; then
        echo "socat exited with return code ${return_code}." >&2
        return "${return_code}"
    fi

    exec 3>&-
    return 0
}

# Usage examples
cuos_api "version"

cuos_api "patch-network" <<EOF
{
  "network_id": 0,
  "config": {
    "dhcp": true
  }
}
EOF
```

Note: The bash function does not return the exit codes!

Hint: Use jq for JSON handling.

### Node.js Implementation
```javascript
// From cuos-iac/webui/app.js
function cuosApi(command, data = {}) {
    return new Promise((resolve, reject) => {
        const client = net.createConnection(SOCKET_PATH);

        client.on('connect', () => {
            client.write(JSON.stringify({ command, ...data })+"\n");
        });

        let response = '';
        client.on('data', (chunk) => {
            response += chunk.toString();
        });

        client.on('end', () => {
            try {
                const result = JSON.parse(response);
                resolve(result);
            } catch (err) {
                resolve(response.trim());
            }
        });

        client.on('error', (err) => {
            reject(err);
        });
    });
}

// Usage examples
const version = await cuosApi('version');

await cuosApi('patch-network', {
  "network_id": 0,
  "config": {
    "dhcp": true
  }
});
```

## Best Practices

1. **Error Handling**
   - Read the result from the output, not the exit code — see above
   - Handle system state changes gracefully
   - Implement proper logging

2. **Resource Monitoring**
   - Poll resources at reasonable intervals
   - Set appropriate thresholds
   - Implement alerting if needed

3. **Update Management**
   - Check system state before updates
   - Handle update failures
   - Implement rollback procedures

4. **Network Configuration**
   - Validate network settings
   - Handle network failures
   - Keep configurations consistent
