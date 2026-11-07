#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# The licences of the system and of every image that offers its own. Sourced by
# api.sh and dialog-maintenance.sh; expects CONFIG_PATH and utils.sh.
#
# An image offers its licences with the label dev.cuos.licenses=<path>, <path>
# being its index (docs/common/licenses.md). It is read with docker cp, never
# docker exec: nothing runs in the container, so a distroless image works, and
# so does the updater image, which never runs as a container of its own.

LICENSES_LABEL="dev.cuos.licenses"
# docker.io's copyright, the largest in the system image, is well under 1 MiB.
LICENSES_MAX_BYTES="${LICENSES_MAX_BYTES:-4194304}"
# Prefix for every file of the system source; the tests point it at fixtures.
LICENSES_ROOT="${T_LICENSES_ROOT:-}"

# Same fallback as product_name in updater/lib/config.sh, which system/cuos
# cannot source (decision 0015).
licenses_product_name() {
  local name=""
  if [[ -f "${CONFIG_PATH}" ]]; then
    name="$(jq -r '.product_name // empty' "${CONFIG_PATH}" 2>/dev/null)"
    if [[ -z "${name}" ]] && jq -r '.init_image // ""' "${CONFIG_PATH}" 2>/dev/null | grep -q 'cuos-iac'; then
      name="CuOS IaC"
    fi
  fi
  echo "${name:-CuOS}"
}

# The tag of the running system image, from /etc/image (image:tag@digest).
licenses_cuos_version() {
  local image
  image="$(cat "${T_FILE_VERSION:-"/etc/image"}" 2>/dev/null)"
  image="${image%%@*}"
  image="${image##*/}"
  [[ "${image}" == *:* ]] && echo "${image#*:}"
}

# Seam for the tests.
licenses_dpkg_list() {
  dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null
}

# Debian's copyright files, one component per package. A machine-readable file
# (DEP-5) gives its License: short names, mapped to SPDX; an unknown name
# becomes a LicenseRef-, a file that is not machine-readable NOASSERTION. The
# texts a file only points at in /usr/share/common-licenses/ come along.
licenses_dpkg_components() {
  licenses_dpkg_list | sort -u | awk -F '\t' -v root="${LICENSES_ROOT}" '
    BEGIN {
      n = split("gpl-1 GPL-1.0-only gpl-1+ GPL-1.0-or-later gpl-1.0+ GPL-1.0-or-later " \
        "gpl-2 GPL-2.0-only gpl-2.0 GPL-2.0-only gpl-2+ GPL-2.0-or-later gpl-2.0+ GPL-2.0-or-later " \
        "gpl-3 GPL-3.0-only gpl-3.0 GPL-3.0-only gpl-3+ GPL-3.0-or-later gpl-3.0+ GPL-3.0-or-later " \
        "lgpl-2 LGPL-2.0-only lgpl-2.0 LGPL-2.0-only lgpl-2+ LGPL-2.0-or-later lgpl-2.0+ LGPL-2.0-or-later " \
        "lgpl-2.1 LGPL-2.1-only lgpl-2.1+ LGPL-2.1-or-later lgpl-3 LGPL-3.0-only lgpl-3.0 LGPL-3.0-only " \
        "lgpl-3+ LGPL-3.0-or-later lgpl-3.0+ LGPL-3.0-or-later agpl-3 AGPL-3.0-only agpl-3+ AGPL-3.0-or-later " \
        "gfdl-1.2 GFDL-1.2-only gfdl-1.2+ GFDL-1.2-or-later gfdl-1.3 GFDL-1.3-only gfdl-1.3+ GFDL-1.3-or-later " \
        "apache-2 Apache-2.0 apache-2.0 Apache-2.0 artistic Artistic-1.0 artistic-1.0 Artistic-1.0 " \
        "artistic-2.0 Artistic-2.0 bsd-2-clause BSD-2-Clause bsd-3-clause BSD-3-Clause bsd-4-clause BSD-4-Clause " \
        "0bsd 0BSD expat MIT mit MIT isc ISC zlib Zlib mpl-1.1 MPL-1.1 mpl-2.0 MPL-2.0 " \
        "cc0 CC0-1.0 cc0-1.0 CC0-1.0 cc-by-3.0 CC-BY-3.0 cc-by-4.0 CC-BY-4.0 cc-by-sa-3.0 CC-BY-SA-3.0 " \
        "cc-by-sa-4.0 CC-BY-SA-4.0 bsl-1.0 BSL-1.0 boost-1.0 BSL-1.0 psf-2 PSF-2.0 python-2.0 Python-2.0 " \
        "openssl OpenSSL x11 X11 curl curl ftl FTL sleepycat Sleepycat unlicense Unlicense wtfpl WTFPL " \
        "ofl-1.1 OFL-1.1 unicode-dfs-2016 Unicode-DFS-2016 bzip2-1.0.6 bzip2-1.0.6 " \
        "public-domain LicenseRef-public-domain fsfullr FSFULLR fsful FSFUL fsfap FSFAP " \
        "afl-2.1 AFL-2.1 beerware Beerware openldap-2.8 OLDAP-2.8 oldap-2.8 OLDAP-2.8 " \
        "bsd-1-clause BSD-1-Clause bsd-4-clause-uc BSD-4-Clause-UC artistic-1 Artistic-1.0 " \
        "artistic-2 Artistic-2.0 sil-ofl-1.1 OFL-1.1 boost BSL-1.0 mit-cmu MIT-CMU vim Vim " \
        "latex2e Latex2e ipa-1 IPA gfdl-niv-1.3 GFDL-1.3-no-invariants-only " \
        "gfdl-niv-1.3+ GFDL-1.3-no-invariants-or-later gfdl-1.3-no-invariants-or-later GFDL-1.3-no-invariants-or-later", t, " ")
      for (i = 1; i < n; i += 2) spdx[t[i]] = t[i + 1]
      n = split("libtool-exception Libtool-exception linux-syscall-note Linux-syscall-note " \
        "linux-syscall-note-exception Linux-syscall-note font-exception Font-exception-2.0 " \
        "classpath-exception-2.0 Classpath-exception-2.0 gcc-exception-3.1 GCC-exception-3.1 " \
        "autoconf-generic-exception Autoconf-exception-generic", t, " ")
      for (i = 1; i < n; i += 2) addition[t[i]] = t[i + 1]
    }
    function exception(s,   k) {
      k = tolower(ref(s))
      return (k in addition) ? addition[k] : "AdditionRef-" ref(s)
    }
    # A term of the AND that makes up the whole package, each only once.
    function term(e) {
      if (e == "" || (e in seen)) return
      seen[e] = 1; nterm++
      if (e ~ / (OR|AND) /) e = "(" e ")"
      lic = lic (lic == "" ? "" : " AND ") e
    }
    function ref(s) {
      gsub(/\+/, "-or-later", s)
      gsub(/[^A-Za-z0-9.-]/, "-", s)
      return s
    }
    function name(w,   k) {
      k = tolower(w)
      return (k in spdx) ? spdx[k] : "LicenseRef-" ref(w)
    }
    # One License: line - "GPL-2+ or Artistic", "GPL-2+ with OpenSSL exception".
    function expression(s,   n, t, i, w, lw, out, add, inwith) {
      gsub(/,/, " ", s); gsub(/\(/, " ( ", s); gsub(/\)/, " ) ", s)
      n = split(s, t, /[ \t]+/)
      out = ""; add = ""; inwith = 0
      for (i = 1; i <= n; i++) {
        w = t[i]; lw = tolower(w)
        if (w == "") continue
        if (inwith) {
          if (lw != "or" && lw != "and" && w != ")") { add = add (add == "" ? "" : "-") w; continue }
          out = out " " exception(add); add = ""; inwith = 0
        }
        if (lw == "or") out = out " OR"
        else if (lw == "and") out = out " AND"
        else if (lw == "with") { out = out " WITH"; inwith = 1 }
        else if (w == "(" || w == ")") out = out " " w
        else out = out " " name(w)
      }
      if (inwith) out = out " " exception(add)
      gsub(/\( /, "(", out); gsub(/ \)/, ")", out); sub(/^ /, "", out)
      return out
    }
    {
      pkg = $1; ver = $2
      file = "/usr/share/doc/" pkg "/copyright"
      dep5 = 0; first = 1; nterm = 0; files = ""; lic = ""
      split("", seen); split("", seenref)
      if ((getline line < (root file)) < 0) {
        printf "%s\t%s\tNOASSERTION\t\n", pkg, ver
        next
      }
      files = file
      do {
        if (first && line ~ /[^ \t]/) {
          first = 0
          if (line ~ /^Format(-Specification)?:/) dep5 = 1
        }
        if (dep5 && line ~ /^License:[ \t]*[^ \t]/) {
          e = line; sub(/^License:[ \t]*/, "", e); sub(/[ \t]+$/, "", e)
          e = expression(e)
          # WITH binds tighter than AND, so a plain AND splits into its terms.
          if (e !~ /[()]/ && e !~ / OR /) {
            m = split(e, parts, / AND /)
            for (j = 1; j <= m; j++) term(parts[j])
          } else term(e)
        }
        rest = line
        while (match(rest, /\/usr\/share\/common-licenses\/[A-Za-z0-9._+-]+/)) {
          r = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
          sub(/\.+$/, "", r)
          if (!(r in seenref) && (getline dummy < (root r)) >= 0) {
            close(root r); seenref[r] = 1; files = files " " r
          }
        }
      } while ((getline line < (root file)) > 0)
      close(root file)
      if (lic == "") lic = "NOASSERTION"
      else if (nterm == 1 && lic ~ /^\(.*\)$/) lic = substr(lic, 2, length(lic) - 2)
      printf "%s\t%s\t%s\t%s\n", pkg, ver, lic, files
    }' | jq -Rn '[inputs | split("\t") | {
      name: .[0], version: .[1], license: .[2],
      files: ((.[3] // "") | split(" ") | map(select(. != "")))
    }]'
}

# Licence directories under /usr/share/licenses/: CuOS's own, and whatever an
# OS built on CuOS puts beside it. A component.json there may give name,
# version and license.
licenses_dir_components() {
  local dir base meta files
  local components="[]"
  for dir in "${LICENSES_ROOT}/usr/share/licenses"/*/; do
    [[ -d "${dir}" ]] || continue
    base="$(basename "${dir}")"
    meta="{}"
    if [[ -f "${dir}component.json" ]]; then
      meta="$(jq -c 'if type == "object" then . else {} end' "${dir}component.json" 2>/dev/null)" || meta="{}"
    fi
    if [[ "${base}" == "cuos" ]]; then
      meta="$(jq -c --arg version "$(licenses_cuos_version)" \
        '{name: "CuOS", version: $version, license: "Apache-2.0"} + .' <<<"${meta}")"
    fi
    # NOTICE first: it carries the copyright.
    files="$(find "${dir}" -maxdepth 1 -type f ! -name component.json -printf '%f\n' \
      | sort | awk '/^NOTICE/ {print; next} {rest = rest $0 "\n"} END {printf "%s", rest}' \
      | jq -Rn --arg dir "/usr/share/licenses/${base}/" '[inputs | select(. != "") | $dir + .]')"
    components="$(jq -c \
      --arg base "${base}" \
      --argjson meta "${meta}" \
      --argjson files "${files}" \
      '. + [{name: ($meta.name // $base | tostring), version: ($meta.version // "" | tostring),
        license: ($meta.license // "NOASSERTION" | tostring), files: $files}]' <<<"${components}")"
  done
  # CuOS first, the rest in directory order.
  jq -c 'map(select(.name == "CuOS")) + map(select(.name != "CuOS"))' <<<"${components}"
}

# Through a pipe, not --argjson: an argument is capped at 128 KiB.
licenses_system_index() {
  { licenses_dir_components; licenses_dpkg_components; } \
    | jq -sc '{format: 1, components: (.[0] + .[1])}'
}

# What a container or an image says about itself is not trusted: strings only,
# no control characters and no backslash (dialog --colors reads \Z as a colour).
licenses_sanitize_index() {
  jq -c '
    def clean: tostring | explode | map(select(. >= 32 and . != 127 and . != 92)) | implode | .[0:200];
    if (.format == 1 and (.components | type) == "array") then
      {format: 1, components: [.components[] | select(type == "object") | {
        name: (.name // "" | clean), version: (.version // "" | clean),
        license: (.license // "NOASSERTION" | clean),
        files: [(.files // [])[] | strings | select(startswith("/") and (test("\n") | not))]
      } | select(.name != "")]}
    else error("not a licence index of format 1") end'
}

# The updater image, as configured; empty if it is not on this device.
licenses_updater_image() {
  local image
  image="$(image_url "updater" 2>/dev/null)" || return 1
  docker image inspect "${image}" >/dev/null 2>&1 || return 1
  echo "${image}"
}

# A source as JSON: {id, name, kind, image, index}. kind is system, image or
# container; index is the path the label names.
licenses_source() {
  local id="$1"
  local inspect
  case "${id}" in
    system)
      jq -nc --arg name "$(licenses_product_name)" \
        '{id: "system", name: $name, kind: "system"}'
      ;;
    updater)
      local image
      image="$(licenses_updater_image)" || return 1
      inspect="$(docker image inspect --format '{{json .Config.Labels}}' "${image}" 2>/dev/null)" || return 1
      jq -c --arg image "${image}" --arg label "${LICENSES_LABEL}" '
        (. // {}) as $l | select($l[$label] // "" | startswith("/")) |
        {id: "updater", name: ($l["org.opencontainers.image.title"] // "Updater"),
         kind: "image", image: $image, index: $l[$label]}' <<<"${inspect}" | grep . || return 1
      ;;
    container:*)
      local container="${id#container:}"
      inspect="$(docker container inspect --format '{{json .Config}}' "${container}" 2>/dev/null)" || return 1
      jq -c --arg id "${id}" --arg container "${container}" --arg label "${LICENSES_LABEL}" '
        (.Labels // {}) as $l | select($l[$label] // "" | startswith("/")) |
        {id: $id, name: ($l["org.opencontainers.image.title"] // $container),
         kind: "container", image: .Image, index: $l[$label]}' <<<"${inspect}" | grep . || return 1
      ;;
    *) return 1 ;;
  esac
}

licenses_sources() {
  local sources=() name
  sources+=("$(licenses_source system)")
  name="$(licenses_source updater)" && sources+=("${name}")
  while read -r name; do
    [[ -n "${name}" ]] || continue
    name="$(licenses_source "container:${name}")" && sources+=("${name}")
  done < <(docker ps --filter "label=${LICENSES_LABEL}" --format '{{.Names}}' 2>/dev/null | sort)
  printf '%s\n' "${sources[@]}" | jq -sc '.'
}

# Files of a non-system source, through docker cp; $1 the source JSON, the rest
# absolute paths. Each is printed under a heading, cut at LICENSES_MAX_BYTES;
# --raw prints them without one. An image gets a container that is created,
# never started.
licenses_read_docker() {
  local raw=""
  [[ "${1:-}" == "--raw" ]] && { raw=1; shift; }
  local source="$1"; shift
  local kind target created=""
  kind="$(jq -r .kind <<<"${source}")"
  if [[ "${kind}" == "image" ]]; then
    created="$(docker create --pull=never "$(jq -r .image <<<"${source}")" 2>/dev/null)" || return 1
    target="${created}"
  else
    target="$(jq -r '.id | ltrimstr("container:")' <<<"${source}")"
  fi
  local path
  for path in "$@"; do
    [[ -z "${raw}" ]] && printf '===== %s =====\n' "${path}"
    docker cp -L "${target}:${path}" - 2>/dev/null | tar -xOf - 2>/dev/null \
      | head -c "${LICENSES_MAX_BYTES}"
    [[ -z "${raw}" ]] && printf '\n'
  done
  [[ -n "${created}" ]] && docker rm -f "${created}" >/dev/null 2>&1
  return 0
}

licenses_read_system() {
  local path
  for path in "$@"; do
    printf '===== %s =====\n' "${path}"
    head -c "${LICENSES_MAX_BYTES}" "${LICENSES_ROOT}${path}" 2>/dev/null
    printf '\n'
  done
}

# The index of a source: {format, source, components}.
licenses_index() {
  local id="$1"
  local source index
  source="$(licenses_source "${id}")" || return 1
  if [[ "${id}" == "system" ]]; then
    index="$(licenses_system_index)" || return 1
  else
    local path
    path="$(jq -r .index <<<"${source}")"
    index="$(licenses_read_docker --raw "${source}" "${path}" | licenses_sanitize_index 2>/dev/null)" \
      || return 1
  fi
  jq -c --argjson source "${source}" '{format, source: ($source | del(.index)), components}' <<<"${index}"
}

# One component with its text: name, version, license, files, text. The text
# is its files one after the other, without control characters but newline
# and tab, so that no escape sequence reaches the terminal.
licenses_text() {
  local id="$1" name="$2"
  local index component source
  index="$(licenses_index "${id}")" || return 1
  component="$(jq -c --arg name "${name}" 'first(.components[] | select(.name == $name)) // empty' <<<"${index}")"
  [[ -n "${component}" ]] || return 2
  local files=()
  mapfile -t files < <(jq -r '.files[]' <<<"${component}")
  local read=(licenses_read_system)
  if [[ "${id}" != "system" ]]; then
    source="$(licenses_source "${id}")" || return 1
    read=(licenses_read_docker "${source}")
  fi
  jq -c --rawfile text <("${read[@]}" "${files[@]+"${files[@]}"}" | tr -d '\000-\010\013-\037\177') \
    '. + {text: $text}' <<<"${component}"
}
