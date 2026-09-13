# Your CuOS Init App

To start your application you have to define a container. Let's call it CuOS Init App; it runs as `cuos-app`. Bringing your own is the [Own CuOS Init App](../development-guide.md#own-cuos-init-app) level — if you do not, you get CuOS IaC.

What you can do within this container:

* Start your application
* Start more docker container (you need to mount the docker socket, see app_command label)
* Interact with the [CuOS API](./cuos-api.md) via `/var/run/cuos.sock`.

## Start the container

Relevant configuration fields, see [system.json](./system-json.md):

```json
{
  "init_image": "your-registry/your-app",
  "init_image_version": "1.2.3",
  "init_image_digest": "sha256:..."
}
```

### CuOS IaC is the default one

[CuOS IaC](https://github.com/cuos-dev/cuos-iac) is a CuOS Init App like any
other — the one you get if you do not bring your own.
`cuos-release`'s `release.json` pins it as `init_image`, so a configuration that
includes `release.json` **already has one** and starts CuOS IaC, which then
deploys your services from a git repository.

Setting `init_image` yourself replaces it:

```json
{
  "#include": ["cuos-release/release.json"],
  "init_image": "your-registry/your-app",
  "init_image_version": "1.2.3",
  "init_image_digest": "sha256:..."
}
```

The system's name follows the same key: `product_name` defaults to `CuOS IaC`
when `init_image` contains `cuos-iac`, and to `CuOS` otherwise
(`updater/perform_update.sh:80`).

## Build your CuOS Init App

```dockerfile
FROM your-base-image

# Your application setup
COPY app /app

```

### Label Based Custom Command

If the application image sets a label:

```dockerfile
LABEL dev.cuos.app_command="--env FOO=bar --cap-add NET_ADMIN"
```

Its value replaces the default Docker run argument block (still augmented with standard names/restart/logging flags). Keep security in mind: avoid unnecessary capabilities.

Default:

```shell
--volume /var/run/docker.sock:/var/run/docker.sock \
--volume /root/.docker/config.json:/root/.docker/config.json:ro \
--volume /system.json:/system.json:ro \
--volume /var/run/cuos.sock:/var/run/cuos.sock \
--volume /usr/local/share/ca-certificates/custom:/usr/local/share/ca-certificates/custom:ro
```

Suggestions for more parameters:

```shell
--memory 512MB \
--user myuser:mygroup \
--read-only \
--tmpfs /etc/ssl/certs:rw,noexec,nosuid,size=16m
--tmpfs /tmp:rw,size=64m
```

### Entrypoint

To make ca-certificate import work, you have to execute

```shell
update-ca-certificates --fresh
```

### Entrypoint: Container Startup Parameters

Additional runtime environment variables, that are set by CuOS:

| Variable | Purpose |
|----------|---------|
| `SYSTEM_TYPE=cuos` | Identify environment |
| `SYSTEM_CONFIG_PATH=/system.json` | Location of active config |
| `VIRT_TYPE` | Result of `systemd-detect-virt` |
| Positional Args | Current + previous app version (used by your entrypoint logic) |

### In-Container Update Hook

After a successful OS/app update the script `/api/update` is executed in the container:

This allows the application to perform migrations or internal reconfiguration. The hook is optional; failures are ignored (logged only). Provide an `/api/update` entrypoint if you need deterministic upgrade steps.

Don't forget to add execution permission to your script.

| Name | Type | Description |
|------|------|-------------|
| `SYSTEM_TYPE` | env | Always `cuos` for identification |
| `SYSTEM_CONFIG_PATH` | env | Path to active config (`/system.json`) |
| `VIRT_TYPE` | env | Result of `systemd-detect-virt` (e.g. `kvm`, `docker`, `none`) |
| `$1` | arg | Current application version (from `init_image_version`) |
| `$2` | arg | Previous application version (if available) |

## Failure & Rollback Logic

| Failure Scenario | Host Reaction |
|------------------|---------------|
| App fails to start repeatedly during update window | Triggers OS rollback |
| Digest never matches (tamper?) | Continuous pull attempts + error logs |
| Timeout (> 3600s startup/update) | Rollback & reboot |
| Single transient pull failure | Retry every 60s |

Rollback resets to previous OS subvolume and replays last stable config.

## Operational Tips

* Use **digests** for production to ensure integrity.
* Store persistent writable data under mounted `/data` volumes if you add any (consider explicit mounts rather than relying on default host path sharing beyond what CuOS provides).
* Avoid `--privileged` unless mandatory; prefer granular `--cap-add`.

## Launch Flow (Simplified)

```text
[systemd] → cuos-app.service → app-init.sh
  └─ waits for Docker daemon ready
     └─ performs registry login (if configured)
        └─ evaluates desired vs current image digest
           ├─ pull if missing / version change / digest mismatch
           ├─ create or start container `cuos-app`
           └─ invoke optional in-container update hook (/api/update)
```
