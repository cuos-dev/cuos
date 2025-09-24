#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

pass=0; fail=0
expect() {
  local label="$1"; shift
  local EXPECTED="$1"; shift
  local GOT
  GOT="$("$@")" || true
  if [ "$GOT" = "$EXPECTED" ]; then
    printf 'OK   %s\n' "$label"
    pass=$((pass+1))
  else
    printf 'FAIL %s\n  got:      %q\n  expected: %q\n' "$label" "$GOT" "$EXPECTED"
    fail=$((fail+1))
  fi
}
summary() {
  printf '\nSummary: %d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] || exit 1
}

export CONFIG_PATH="/dev/stdin"

cat <<EOF | expect "image_url: full object" "ghcr.io/cuos-dev/cuos-system:latest" \
  image_url "os"
{
  "os_image": "ghcr.io/cuos-dev/cuos-system",
  "os_image_version": "latest",
  "os_image_digest": ""
}
EOF

cat <<EOF | expect "image_url: with registry" "ghcr.io/cuos-dev/cuos-system:latest" \
  image_url "os"
{
  "update_registry": "ghcr.io/cuos-dev",
  "os_image": "/cuos-system",
  "os_image_version": "latest",
  "os_image_digest": ""
}
EOF

cat <<EOF | expect "image_url: with registry" "ghcr.io/cuos-dev/cuos-system:latest" \
  image_url "os"
{
  "update_registry": "ghcr.io/cuos-dev/",
  "os_image": "cuos-system",
  "os_image_version": "latest",
  "os_image_digest": ""
}
EOF

cat <<EOF | expect "image_url: version in image" "ghcr.io/cuos-dev/cuos-system:latest" \
  image_url "os"
{
  "update_registry": "ghcr.io/cuos-dev/",
  "os_image": "cuos-system:latest",
  "os_image_version": "",
  "os_image_digest": ""
}
EOF

cat <<EOF | expect "image_url: just image" "ghcr.io/cuos-dev/cuos-system:latest" \
  image_url "os"
{
  "os_image": "ghcr.io/cuos-dev/cuos-system:latest",
  "os_image_digest": ""
}
EOF

cat <<EOF | expect "image_url: empty" "" \
  image_url "os"
{
}
EOF

expect "image_version: custom version" "development" \
  image_version "abcdef:development"

expect "image_version: full url" "latest" \
  image_version "myhost:7654/hallo/abcdef"

expect "image_version: no version" "latest" \
  image_version "abcdef"

expect "image_version: no image" "latest" \
  image_version

summary
