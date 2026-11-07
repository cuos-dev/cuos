#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR="$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd)"

set -euo pipefail

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-test.sh"

# Fixtures are made here, not kept beside the test: everything in system/cuos/
# goes into the image.
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

ROOT="${TMP}/root"
mkdir -p "${ROOT}/usr/share/licenses/cuos" "${ROOT}/usr/share/licenses/acme" \
  "${ROOT}/usr/share/doc/pkg-a" "${ROOT}/usr/share/doc/pkg-b" "${ROOT}/usr/share/common-licenses"
echo "Apache License" >"${ROOT}/usr/share/licenses/cuos/LICENSE.txt"
echo "CuOS NOTICE" >"${ROOT}/usr/share/licenses/cuos/NOTICE"
echo '{"name": "Acme OS", "version": "1.2", "license": "MIT"}' >"${ROOT}/usr/share/licenses/acme/component.json"
echo "Acme licence" >"${ROOT}/usr/share/licenses/acme/LICENSE"
echo "GPL-2 text" >"${ROOT}/usr/share/common-licenses/GPL-2"
cat >"${ROOT}/usr/share/doc/pkg-a/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: pkg-a

Files: *
Copyright: 2020 Someone
License: GPL-2+

Files: lib/*
Copyright: 2021 Other
License: Expat and GPL-2+

Files: fonts/*
License: GPL-2+ with Font exception

Files: odd/*
License: Weird-1 or BSD-3-clause

License: GPL-2+
 On Debian systems, see /usr/share/common-licenses/GPL-2.

License: Expat
 Permission is hereby granted ...
EOF
printf 'pkg-b was written by\n\tsomeone, see /usr/share/common-licenses/GPL-2.\n' \
  >"${ROOT}/usr/share/doc/pkg-b/copyright"
printf '\033[31mred\033[0m\n' >>"${ROOT}/usr/share/doc/pkg-b/copyright"

echo '{"product_name": "My OS"}' >"${TMP}/system.json"
echo "ghcr.io/cuos-dev/cuos-system:v0.7.0@sha256:abc" >"${TMP}/image"

export CONFIG_PATH="${TMP}/system.json"
export T_LICENSES_ROOT="${ROOT}"
export T_FILE_VERSION="${TMP}/image"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/licenses.sh"
set +e

# mocks:
licenses_dpkg_list() {
  printf 'pkg-b\t2.0\npkg-a\t1.0-1\npkg-c\t3\npkg-a\t1.0-1\n'
}

# The container "app" (labelled), "plain" (not) and the updater image. Their
# file systems are directories; docker cp hands out a tar, like docker does.
CTR="${TMP}/ctr"
mkdir -p "${CTR}/licenses" "${CTR}/doc"
cat >"${CTR}/licenses/index.json" <<'EOF'
{"format": 1, "components": [
  {"name": "express", "version": "5.0.0", "license": "MIT", "files": ["/doc/LICENSE", "relative/path"]},
  {"name": "big", "license": "MIT", "files": ["/doc/BIG"]},
  {"name": "evil\u001b[2J\\Z1", "version": 3, "files": ["/doc/LICENSE"]},
  "not an object",
  {"version": "no name"}
]}
EOF
printf 'MIT text\n\033]0;title\007\n' >"${CTR}/doc/LICENSE"
printf '%05000d' 0 >"${CTR}/doc/BIG"
DOCKER_LOG="${TMP}/docker.log"
docker() {
  echo "docker $*" >>"${DOCKER_LOG}"
  case "$1 $2" in
    "image inspect")
      [[ "${*: -1}" == "ghcr.io/cuos-dev/cuos-updater:v1" ]] || return 1
      [[ "$*" == *"--format"* ]] && echo '{"dev.cuos.licenses": "/licenses/index.json"}'
      return 0
      ;;
    "ps --filter") printf 'plain\napp\n' ;;
    "container inspect")
      case "${*: -1}" in
        app) echo '{"Image": "acme/app:1", "Labels": {"dev.cuos.licenses": "/licenses/index.json", "org.opencontainers.image.title": "Acme App"}}' ;;
        plain) echo '{"Image": "plain:1", "Labels": {}}' ;;
        *) return 1 ;;
      esac
      ;;
    "create --pull=never") echo "created-123" ;;
    "rm -f") ;;
    "cp -L")
      local path="${3#*:}"
      [[ -f "${CTR}${path}" ]] || return 1
      tar -C "${CTR}$(dirname "${path}")" -cf - "$(basename "${path}")"
      ;;
    *) return 1 ;;
  esac
}

# In a subshell, so that the variables set for one case stay there.
product_name_of() {
  ( CONFIG_PATH="$1"; licenses_product_name )
}
echo '{"init_image": "ghcr.io/cuos-dev/cuos-iac"}' >"${TMP}/iac.json"
expect "product name: from the config" "My OS" licenses_product_name
expect "product name: cuos-iac" "CuOS IaC" product_name_of "${TMP}/iac.json"
expect "product name: no config" "CuOS" product_name_of "${TMP}/none.json"
expect "cuos version: the tag of /etc/image" "v0.7.0" licenses_cuos_version

components="$(licenses_dpkg_components)"
expect "dpkg: one component per package, sorted, deduplicated" "pkg-a,pkg-b,pkg-c" \
  jq -r 'map(.name) | join(",")' <<<"${components}"
expect "dpkg: DEP-5 short names to SPDX, AND flattened, each term once" \
  "GPL-2.0-or-later AND MIT AND GPL-2.0-or-later WITH Font-exception-2.0 AND (LicenseRef-Weird-1 OR BSD-3-Clause)" \
  jq -r '.[0].license' <<<"${components}"
expect "dpkg: copyright plus the common licence it points at" \
  '["/usr/share/doc/pkg-a/copyright","/usr/share/common-licenses/GPL-2"]' \
  jq -c '.[0].files' <<<"${components}"
expect "dpkg: not machine-readable is NOASSERTION" "NOASSERTION" jq -r '.[1].license' <<<"${components}"
expect "dpkg: a pointer outside DEP-5 brings the text too" \
  '["/usr/share/doc/pkg-b/copyright","/usr/share/common-licenses/GPL-2"]' \
  jq -c '.[1].files' <<<"${components}"
expect "dpkg: no copyright file, no files" '{"name":"pkg-c","version":"3","license":"NOASSERTION","files":[]}' \
  jq -c '.[2]' <<<"${components}"

expect "dirs: CuOS first, NOTICE before the licence, then the others with component.json" \
  '[{"name":"CuOS","version":"v0.7.0","license":"Apache-2.0","files":["/usr/share/licenses/cuos/NOTICE","/usr/share/licenses/cuos/LICENSE.txt"]},{"name":"Acme OS","version":"1.2","license":"MIT","files":["/usr/share/licenses/acme/LICENSE"]}]' \
  licenses_dir_components

expect "system index: format 1, directories then packages" "1 CuOS,Acme OS,pkg-a,pkg-b,pkg-c" \
  jq -r '"\(.format) \(.components | map(.name) | join(","))"' <<<"$(licenses_system_index)"

echo '{"product_name": "My OS", "updater_image": "ghcr.io/cuos-dev/cuos-updater:v1"}' >"${TMP}/updater.json"
sources_with_updater() {
  ( CONFIG_PATH="${TMP}/updater.json"; licenses_sources )
}
sources_without_docker() {
  ( docker() { return 1; }; licenses_sources )
}
expect "sources: system with the product name, the updater, labelled containers only" \
  '[{"id":"system","name":"My OS System","kind":"system"},{"id":"updater","name":"Updater","kind":"image","image":"ghcr.io/cuos-dev/cuos-updater:v1","index":"/licenses/index.json"},{"id":"container:app","name":"Acme App","kind":"container","image":"acme/app:1","index":"/licenses/index.json"}]' \
  sources_with_updater
expect "sources: no updater configured, no docker" '[{"id":"system","name":"My OS System","kind":"system"}]' \
  sources_without_docker

expect "index: the system's carries its source" '{"id":"system","name":"My OS System","kind":"system"}' \
  jq -c .source <<<"$(licenses_index system)"
expect "index: from a container, sanitized" \
  '{"format":1,"source":{"id":"container:app","name":"Acme App","kind":"container","image":"acme/app:1"},"components":[{"name":"express","version":"5.0.0","license":"MIT","files":["/doc/LICENSE"]},{"name":"big","version":"","license":"MIT","files":["/doc/BIG"]},{"name":"evil[2JZ1","version":"3","license":"NOASSERTION","files":["/doc/LICENSE"]}]}' \
  licenses_index container:app
expect_rc "index: an unlabelled container is no source" 1 licenses_index container:plain
expect_rc "index: an unknown source" 1 licenses_index nothing

echo '{"format": 2}' >"${TMP}/bad.json"
expect_rc "sanitize: another format is refused" 5 licenses_sanitize_index <"${TMP}/bad.json"

text_of() {
  licenses_text "$@" | jq -j .text
}
updater_text_of() {
  ( CONFIG_PATH="${TMP}/updater.json"; text_of "$@" )
}
expect "text: system, files one after the other under a heading" \
  $'===== /usr/share/licenses/cuos/NOTICE =====\nCuOS NOTICE\n\n===== /usr/share/licenses/cuos/LICENSE.txt =====\nApache License' \
  text_of system CuOS
expect "text: escape sequences are dropped" \
  $'===== /usr/share/doc/pkg-b/copyright =====\npkg-b was written by\n\tsomeone, see /usr/share/common-licenses/GPL-2.\n[31mred[0m\n\n===== /usr/share/common-licenses/GPL-2 =====\nGPL-2 text' \
  text_of system pkg-b
expect "text: from a container, through docker cp" \
  $'===== /doc/LICENSE =====\nMIT text\n]0;title' \
  text_of container:app express
expect_rc "text: an unknown component" 2 licenses_text container:app nothing

: >"${DOCKER_LOG}"
expect "text: from the updater image" \
  $'===== /doc/LICENSE =====\nMIT text\n]0;title' \
  updater_text_of updater express
expect "text: the updater container is created and removed, never started" \
  "create --pull=never ghcr.io/cuos-dev/cuos-updater:v1|cp -L created-123:/doc/LICENSE -|rm -f created-123" \
  bash -c "grep -E '^docker (create|cp|rm|start|run|exec)' '${DOCKER_LOG}' | sed 's/^docker //' | tail -3 | paste -sd '|'"
expect "text: each file cut at the limit" "===== /doc/BIG =====|$(printf '%01000d' 0)" \
  bash -c "$(declare -f); CTR='${CTR}'; DOCKER_LOG=/dev/null; LICENSES_ROOT=''; LICENSES_LABEL=dev.cuos.licenses; LICENSES_MAX_BYTES=1000; licenses_text container:app big | jq -j .text | paste -sd '|'"

# The API command, as cuos and over the socket. api.sh sets its own
# CONFIG_PATH and sources licenses.sh again.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/api.sh"
set +e
CONFIG_PATH="${TMP}/system.json"
licenses_dpkg_list() {
  printf 'pkg-a\t1.0-1\n'
}
api_jq() {
  local filter="$1"; shift
  ( docker() { return 1; }; api_main "$@" | jq -r "${filter}" )
}
socket() {
  ( api_main input <<<"$1" )
}
expect "api: licenses lists the sources" "system" api_jq '.[].id' licenses
expect "api: licenses SOURCE" "CuOS,Acme OS,pkg-a" api_jq '.components | map(.name) | join(",")' licenses system
expect "api: licenses SOURCE COMPONENT" "Acme OS 1.2 MIT" api_jq '"\(.name) \(.version) \(.license)"' licenses system "Acme OS"
expect "api: over the socket" "MIT" \
  jq -r .license <<<"$(socket '{"command": "licenses", "source": "system", "component": "Acme OS"}')"
expect "api: an unknown component" '{"err":2,"message":"No component nope in source system"}' \
  api_main licenses system nope
expect "api: an unknown source" '{"err":1,"message":"No licences from source nope"}' \
  api_jq -c licenses nope

summary
