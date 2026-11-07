# Licences on the device

A CuOS system shows what software it carries and under which licence: on the
console under *Licenses*, and through the API as `cuos licenses`. For each
component it shows the name, the version and an SPDX licence expression. When
a component is chosen, it shows the full text: copyright, licence and NOTICE.

## Sources

The licences are grouped by **source**:

| Source | id | Where the list comes from |
|---|---|---|
| The system | `system` | Read on the device: CuOS itself, every directory in `/usr/share/licenses/`, and every Debian package |
| The updater image | `updater` | The index the image names in its label, if the image is on the device |
| A running container | `container:<name>` | The index the container's image names in its label |

The system is shown under its `product_name`. Without one, it is *CuOS IaC
System* or *CuOS System*. The component stays *CuOS*, because that is the
licensed work.

### The system

- **Debian packages:** one component each, read from dpkg's database. The text
  is `/usr/share/doc/<package>/copyright`, plus every file in
  `/usr/share/common-licenses/` it points at. The slim Debian image keeps these
  files. Debian ships no NOTICE files of its own, because their content goes
  into `copyright`.
- **Licence identifiers:** in a machine-readable `copyright` file (DEP-5), the
  `License:` fields give the licence. Debian's short names are mapped to SPDX
  (`GPL-2+` becomes `GPL-2.0-or-later`); a name without an SPDX counterpart
  becomes `LicenseRef-<name>`. A file that is not machine-readable gives
  `NOASSERTION`, which means "see the text".
- **Directories in `/usr/share/licenses/`:** each one is a component of its
  own, with the files in it as its text (`NOTICE` first). CuOS keeps
  `LICENSE.txt` and `NOTICE` in `/usr/share/licenses/cuos/`. An OS built on
  CuOS puts its own licence beside it, and may describe it in a
  `component.json`:

  ```json
  { "name": "Acme OS", "version": "1.2", "license": "LicenseRef-Acme" }
  ```

The list is built when it is asked for, not at build time. A package added by
an image built `FROM` the CuOS system image is therefore listed too.

### An image that offers its licences

An image says that it offers licences with a label naming its index:

```dockerfile
LABEL dev.cuos.licenses=/usr/share/licenses/index.json
LABEL org.opencontainers.image.title="Acme App"
```

The display name comes from `org.opencontainers.image.title`. Without it, the
container name is used, or `Updater` for the updater.

The index is a JSON file in the image:

```json
{
  "format": 1,
  "components": [
    {
      "name": "express",
      "version": "5.1.0",
      "license": "MIT",
      "files": ["/app/node_modules/express/LICENSE"]
    }
  ]
}
```

`files` are absolute paths in the same image. The text is those files, one after
the other.

**CuOS reads these files with `docker cp`; nothing runs in the container.** So
an image without a shell works too, and the updater image is never started:
CuOS creates a container from it, copies the files out and removes it again.

The index and the texts come from an image CuOS did not build, so they are
cleaned before use:

- only strings are kept, without control characters or backslashes;
- each file is cut at 4 MiB;
- the console shows the text without interpreting escape sequences.

## API

```bash
# The sources
cuos licenses

# The components of a source
cuos licenses system

# One component with its text
cuos licenses system bash
```

Over the socket the same requests are written
`{"command": "licenses", "source": "system", "component": "bash"}`. The answers:

```json
[{"id": "system", "name": "CuOS System", "kind": "system"},
 {"id": "container:cuos-app", "name": "Acme App", "kind": "container", "image": "acme/app:1", "index": "/usr/share/licenses/index.json"}]
```

```json
{"format": 1, "source": {"id": "system", "name": "CuOS System", "kind": "system"},
 "components": [{"name": "CuOS", "version": "v0.7.0", "license": "Apache-2.0",
   "files": ["/usr/share/licenses/cuos/NOTICE", "/usr/share/licenses/cuos/LICENSE.txt"]}]}
```

With a component, the answer is that component's entry plus `text`. An unknown
source gives `{"err": 1, …}`, an unknown component `{"err": 2, …}`.

## Adding to the console menu

A product can add to the *Licenses* menu from its `custom-dialog.sh`, the file
that `dialog-maintenance.sh` sources last:

```bash
custom_licenses_intro() {
  echo "Acme OS is built on CuOS. Our terms: https://acme.example/terms"
}

custom_licenses_entries() {
  printf '%s\n' "custom:terms" "Acme terms of use"
}

custom_licenses_entry() {
  case "$1" in
    custom:terms) msg "$(cat /usr/local/acme/terms.txt)" "Terms of use" 30 78 ;;
  esac
}
```

| Function | What it does |
|---|---|
| `custom_licenses_intro` | Its output is shown before the introduction text |
| `custom_licenses_entries` | Prints tag and label, one per line, for entries of its own. Tags start with `custom:` |
| `custom_licenses_entry TAG` | Runs when one of these entries is chosen |

All three are optional. A component of its own needs no function, only a
directory in `/usr/share/licenses/`.

## Known gaps

- About a quarter of Debian's `copyright` files are not machine-readable. They
  show `NOASSERTION`; their text is complete all the same.
- A package's expression is the AND of every licence its `copyright` file
  names, file by file. It says what the package contains, not under which
  licence one particular file is.
- The updater image carries no index yet, and neither do the `cuos-iac` images.
