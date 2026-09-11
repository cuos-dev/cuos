#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# What system.json says. Sourced, never run.

product_name() {
  local name="CuOS"

  if [[ ! -f "${CONFIG_PATH}" ]]; then
    echo "${name}"
    return
  fi

  name="$(jq -r '.product_name // empty' "${CONFIG_PATH}")"
  if [[ -z "${name}" ]]; then
    if jq -r '.init_image' "${CONFIG_PATH}" | grep -q 'cuos-iac'; then
      name="CuOS IaC"
    else
      name="CuOS"
    fi
  fi
  echo "${name}"
}

