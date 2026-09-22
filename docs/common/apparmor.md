# AppArmor

CuOS boots with AppArmor enabled (`apparmor=1` on the kernel command line) on
every platform except LXC. `cuos selftest` reports the state under the
`apparmor` check.

## What is confined

| | Profile | Where it comes from |
|---|---|---|
| Every container dockerd starts | `docker-default` | dockerd's built-in template, loaded when the daemon starts |
| `dhclient` | `/usr/sbin/dhclient` | Debian's `isc-dhcp-client` package |
| PAM's password check | `unix-chkpwd`, in complain mode | Debian's `apparmor` package |

That is the whole list, and `docker-default` is the point of the exercise: it is
what stands between a container and the host — the application container and
everything deployed through cuos-iac alike. Debian's `apparmor-profiles` and
`apparmor-profiles-extra` packages are not installed — they cover samba,
syslog, avahi and desktop software, none of which is here.

The `apparmor` package's own ~100 profiles are inert here: most are the Debian
13 userns stubs (`flags=(unconfined)`, body `userns,`), and every one of the
rest is either in complain mode or carries no attachment path. None of them can
deny anything, including inside a container that runs unconfined.

## What is not confined

- **dockerd, and the CuOS scripts.** A daemon that must be able to do anything
  cannot usefully be confined, and the CuOS scripts run as root and start
  privileged containers.
- **The updater.** `do-update.sh` runs it with `--privileged`, and Docker runs
  privileged containers unconfined. It repartitions the root disk, so it needs
  to be. It is pulled by digest, and the digest is checked before it runs.
- **sshd.** Debian ships no profile for it, and it is masked unless
  `os_ssh_server` is set.
- **The LXC platform.** Profiles are loaded into the host's kernel and a
  container cannot load its own, so the LXC image carries no AppArmor at all.
  Confining a CuOS guest is the LXC host's business.
- **The installer ISO.** A separate image without the AppArmor package.

## What `docker-default` forbids a container

The profile is permissive by design: `network,`, `capability,`, `file,` and
`umount,` are allowed outright, so every file and every capability is on the
table. What it carries is a short list of denials, and three of them reach
ordinary containers.

| Denied | What stops working |
|---|---|
| `deny mount,` | FUSE (sshfs, s3fs, rclone), `mount --bind` in an entrypoint, NFS/CIFS from inside, docker-in-docker, systemd as PID 1 |
| writes below `/sys`, everything but `/sys/fs/cgroup/**` | sysfs GPIO (`/sys/class/gpio/export`), LEDs, PWM, backlight, driver `bind`/`unbind`, `/sys/class/net/*` |
| `deny @{PROC}/sys/[^k]** w,` | `sysctl -w` run inside the container |

Reading is untouched — only writes to `/sys` and `/proc` are denied.

**`cap_add: [SYS_ADMIN]` does not lift any of this.** The capability is granted
and AppArmor refuses anyway, and the error names neither. `privileged: true`
does lift it, because Docker runs privileged containers unconfined.

Unaffected, and usually the cheaper way out of a denial:

- `volumes:`, `tmpfs:`, `read_only:` and `sysctls:` in a compose file — runc
  applies those before the container starts, and runc is unconfined.
- Device nodes: `/dev/gpiochip*` (libgpiod), `/dev/i2c-*`, `/dev/spidev*` are
  covered by `file,`. Only the sysfs route to the same hardware is denied.

`docker-default` separates a container from the **host**, not from other
containers. Every container carries the same profile name, so the
`signal (send,receive) peer=docker-default` and
`ptrace (trace,read) peer=docker-default` rules of the template apply between
containers as soon as they share a PID namespace (`pid: host`,
`pid: service:…`).

The rules above are moby's built-in template as of 26.1.5, the version in
Debian trixie's `docker.io`. Read `aa-status` on the device rather than this
page if a denial does not match.

## Giving an application more than `docker-default`

For a service deployed through cuos-iac, the profile is chosen per service in
the compose file, and adds to what is already there:

```yml
services:
  app:
    security_opt:
      - apparmor=unconfined
```

For the application container, the flags come from the `dev.cuos.app_command`
label on the app image (see `cuos-app-init.md`), so it is selected there:

```
LABEL dev.cuos.app_command="--security-opt apparmor=my-profile ..."
```

Note that the label **replaces** the default flag set rather than adding to it.

The profile itself has to be loaded into the kernel before the container
starts, and CuOS ships no mechanism for that yet. So the choice today is
`docker-default` or nothing: while an application is being brought up,
`--security-opt apparmor=unconfined` is the escape hatch.

## Reading a denial

```
journalctl -b | grep DENIED
```

Each line names the profile, the operation and the path. To take one profile
out of the way without touching the rest:

```
aa-complain /etc/apparmor.d/usr.sbin.dhclient   # log, do not block
aa-enforce  /etc/apparmor.d/usr.sbin.dhclient   # back to blocking
```

Both are lost on the next boot, which is what you want while diagnosing. A
permanent addition goes into the profile's `local/` include —
`/etc/apparmor.d/local/<profile>` — which survives package upgrades.

## The `/data` trap

CuOS keeps mutable state in `/data` and symlinks into it: `/var/log`,
`/var/lib/dhcp`, `/var/lib/docker`, `/var/lib/containerd`, `/root`.

**AppArmor mediates the resolved path, not the symlink.** A stock profile that
allows `/var/lib/dhcp/dhclient*` therefore denies the write that actually lands
on `/data/dhcp/dhclient.leases`. That is why the image ships

```
/data/dhcp/ r,
/data/dhcp/dhclient* lrw,
```

in `/etc/apparmor.d/local/usr.sbin.dhclient`. Any profile adopted from a
distribution package has to be read against these symlinks first.
