#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Render docs/common/system-json.md from system/cuos/system-schema.json.
#
# The schema is the reference: it carries a description for every key and is
# enforced at runtime (system/cuos/init.sh). Keeping a second, hand-written key
# table in the docs meant the two could disagree silently, so the table is
# generated from the schema instead.
#
# Run it after changing the schema:
#
#   npm install              once, or after the generator version changes
#   npm run docs:system-json
#
# A checksum of the schema is written into the generated file, and
# system/cuos/system-json.test.sh fails if it no longer matches. Deliberately a
# checksum and not a timestamp: git does not record mtimes, so in a fresh clone
# every file carries the checkout time and an "is it older?" comparison would be
# meaningless.

set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd)"
REPO_DIR="$( cd -- "${SCRIPT_DIR}/../.." &> /dev/null && pwd )"

SCHEMA="${REPO_DIR}/system/cuos/system-schema.json"
OUTPUT="${REPO_DIR}/docs/common/system-json-reference.md"
GENERATOR="${REPO_DIR}/node_modules/.bin/jsonschema2mk"

raise() {
  echo "Error: $*" >&2
  exit 1
}

# sha256sum is GNU; macOS ships shasum. Keep both working - this script is run
# by people, on their own machines.
schema_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    raise "Neither sha256sum nor shasum found."
  fi
}

[[ -f "${SCHEMA}" ]] || raise "Schema not found: ${SCHEMA}"
[[ -x "${GENERATOR}" ]] \
  || raise "The documentation generator is not installed. Run 'npm install' first."

hash="$(schema_hash "${SCHEMA}")"

body="$("${GENERATOR}" --schema "${SCHEMA}")" || raise "The generator failed."
[[ -n "${body}" ]] || raise "The generator produced no output."

mkdir -p "$(dirname "${OUTPUT}")"
{
  echo "<!-- GENERATED FILE - do not edit by hand."
  echo "     Source:     system/cuos/system-schema.json"
  echo "     Regenerate: npm run docs:system-json"
  echo "-->"
  echo
  echo "${body}"
  echo
  echo "---"
  echo
  echo "*This page is generated from [\`system/cuos/system-schema.json\`](../../system/cuos/system-schema.json),"
  echo "the schema CuOS validates \`system.json\` against at boot. Edit the schema, then run"
  echo "\`npm run docs:system-json\`.*"
  echo
  echo "<!-- schema-sha256: ${hash} -->"
} >"${OUTPUT}"

echo "Wrote ${OUTPUT#"${REPO_DIR}"/} (schema sha256 ${hash})"
