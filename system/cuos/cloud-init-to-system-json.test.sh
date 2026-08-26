#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR="$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd)"

set -euo pipefail

RESULT="$("${SCRIPT_DIR}/cloud-init-to-system-json.sh" \
  "${SCRIPT_DIR}/cloud-init-to-system-json.test.v1-seperate.yml" \
  "${SCRIPT_DIR}/cloud-init-to-system-json.test.v1-network.yml")"
EXPECTED="$(cat "${SCRIPT_DIR}/cloud-init-to-system-json.test.v1-expected.json")"

echo -n "[Test] V1 Separate + Network: "
if [[ "${RESULT}" != "${EXPECTED}" ]]; then
  echo "failed"
  diff -u <(echo "${EXPECTED}") <(echo "${RESULT}")
  exit 1
else
  echo "passed"
fi

RESULT="$("${SCRIPT_DIR}/cloud-init-to-system-json.sh" \
  "${SCRIPT_DIR}/cloud-init-to-system-json.test.v2-basic.yml")"
EXPECTED="$(cat "${SCRIPT_DIR}/cloud-init-to-system-json.test.v2-expected.json")"

echo -n "[Test] V2 Basic: "
if [[ "${RESULT}" != "${EXPECTED}" ]]; then
  echo "failed"
  diff -u <(echo "${EXPECTED}") <(echo "${RESULT}")
  exit 1
else
  echo "passed"
fi


RESULT="$("${SCRIPT_DIR}/cloud-init-to-system-json.sh" \
  "${SCRIPT_DIR}/cloud-init-to-system-json.test.prox-config.yml" \
  "${SCRIPT_DIR}/cloud-init-to-system-json.test.prox-network.yml")"
EXPECTED="$(cat "${SCRIPT_DIR}/cloud-init-to-system-json.test.prox-expected.json")"

echo -n "[Test] V2 Proxmox: "
if [[ "${RESULT}" != "${EXPECTED}" ]]; then
  echo "failed"
  diff -u <(echo "${EXPECTED}") <(echo "${RESULT}")
  exit 1
else
  echo "passed"
fi

RESULT="$("${SCRIPT_DIR}/cloud-init-to-system-json.sh" \
  "${SCRIPT_DIR}/cloud-init-to-system-json.test.rpi-config.yml")"
EXPECTED="$(cat "${SCRIPT_DIR}/cloud-init-to-system-json.test.rpi-expected.json")"

echo -n "[Test] Raspberry PI: "
if [[ "${RESULT}" != "${EXPECTED}" ]]; then
  echo "failed"
  diff -u <(echo "${EXPECTED}") <(echo "${RESULT}")
  exit 1
else
  echo "passed"
fi
