#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# docs/common/system-json.md is generated from system-schema.json. Check that it
# still matches the schema it was generated from.
#
# The check compares a checksum embedded in the generated file, not file times:
# git does not record mtimes, so in a fresh clone every file has the checkout
# time and an age comparison would pass or fail at random.

SCRIPT_DIR="$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd)"
REPO_DIR="$( cd -- "${SCRIPT_DIR}/../.." &> /dev/null && pwd )"

SCHEMA="${SCRIPT_DIR}/system-schema.json"
DOC="${REPO_DIR}/docs/common/system-json-reference.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

schema_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    fail "Neither sha256sum nor shasum found."
  fi
}

[[ -f "${SCHEMA}" ]] || fail "Schema not found: ${SCHEMA}"
[[ -f "${DOC}" ]] || fail "Generated documentation not found: ${DOC}
      Run: npm run docs:system-json"

expected="$(schema_hash "${SCHEMA}")"
actual="$(sed -n 's/^<!-- schema-sha256: \([0-9a-f]*\) -->$/\1/p' "${DOC}" | tail -n 1)"

if [[ -z "${actual}" ]]; then
  fail "${DOC#"${REPO_DIR}"/} carries no schema checksum.
      Run: npm run docs:system-json"
fi

if [[ "${actual}" != "${expected}" ]]; then
  fail "${DOC#"${REPO_DIR}"/} is out of date - the schema changed since it was generated.
      schema:    ${expected}
      generated: ${actual}
      Run: npm run docs:system-json"
fi

echo "OK: ${DOC#"${REPO_DIR}"/} matches system-schema.json (${expected})"
