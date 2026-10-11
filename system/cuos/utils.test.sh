#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-test.sh"

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

cat <<EOF | expect "image_url: user proxy" "proxy.example.com/cuos-system:latest" \
  image_url "os"
{
  "update_registry_proxy": "proxy.example.com",
  "os_image": "cuos-system:latest",
  "os_image_version": "",
  "os_image_digest": ""
}
EOF

cat <<EOF | expect "image_url: user proxy" "proxy.example.com/cuos-system:latest" \
  image_url "os"
{
  "update_registry_proxy": "proxy.example.com/",
  "os_image": "/cuos-system:latest",
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

REPLACE_DIR="$(mktemp -d)"
mkdir -p "${REPLACE_DIR}/data"
echo '{"old":1}' >"${REPLACE_DIR}/data/system_B.json"
chmod 640 "${REPLACE_DIR}/data/system_B.json"
ln -s "${REPLACE_DIR}/data/system_B.json" "${REPLACE_DIR}/system_next.json"
ln -s "${REPLACE_DIR}/data/system_A.json" "${REPLACE_DIR}/system.json"

INODE_BEFORE="$(stat -c %i "${REPLACE_DIR}/data/system_B.json")"
echo '{"new":1}' | replace_file_content "${REPLACE_DIR}/system_next.json"
expect "replace_file_content: the file behind the link is replaced" '{"new":1}' \
  cat "${REPLACE_DIR}/data/system_B.json"
expect "replace_file_content: the link stays a link" "${REPLACE_DIR}/data/system_B.json" \
  readlink "${REPLACE_DIR}/system_next.json"
expect "replace_file_content: the mode is kept" "640" \
  stat -c %a "${REPLACE_DIR}/data/system_B.json"
expect "replace_file_content: the inode is kept, for bind mounts" "${INODE_BEFORE}" \
  stat -c %i "${REPLACE_DIR}/data/system_B.json"

echo '{"a":1}' | replace_file_content "${REPLACE_DIR}/system.json"
expect "replace_file_content: a dangling link gets its file" '{"a":1}' \
  cat "${REPLACE_DIR}/data/system_A.json"
expect "replace_file_content: a new file is 644" "644" \
  stat -c %a "${REPLACE_DIR}/data/system_A.json"

expect_rc "replace_file_content: a failed write fails" 1 \
  replace_file_content "${REPLACE_DIR}/system_next.json" <"${REPLACE_DIR}"
expect "replace_file_content: a failed write leaves the old file" '{"new":1}' \
  cat "${REPLACE_DIR}/data/system_B.json"
expect "replace_file_content: and no file.new" "system_A.json system_B.json" \
  bash -c "cd '${REPLACE_DIR}/data' && echo *"
rm -rf "${REPLACE_DIR}"

summary
