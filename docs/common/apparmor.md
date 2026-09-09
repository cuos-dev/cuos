# AppArmor

CuOS boots with AppArmor enabled (`apparmor=1` on the kernel command line) on
every platform except LXC. `cuos selftest` reports the state under the
`apparmor` check.

## What is confined

| | Profile | Where it comes from |
|---|---|---|
| The application container | `docker-default` | dockerd's built-in template, loaded when the daemon starts |
| `dhclient` | `/usr/sbin/dhclient` | Debian's `isc-dhcp-client` package |
| PAM's password check | `unix-chkpwd` | Debian's `apparmor` package |

That is the whole list, and `docker-default` is the point of the exercise: it is
what stands between the application container and the host. Debian's
`apparmor-profiles` and `apparmor-profiles-extra` packages are not installed —
they cover samba, syslog, avahi and desktop software, none of which is here.

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

## Giving an application more than `docker-default`

The flags of the application container come from the `dev.cuos.app_command`
label on the app image (see `cuos-app-init.md`), so the profile is selected
there:

```
LABEL dev.cuos.app_command="--security-opt apparmor=my-profile ..."
```

Note that the label **replaces** the default flag set rather than adding to it.

The profile itself has to be loaded into the kernel before the container
starts, and CuOS ships no mechanism for that yet. While an application is being
brought up, `--security-opt apparmor=unconfined` is the escape hatch.

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
