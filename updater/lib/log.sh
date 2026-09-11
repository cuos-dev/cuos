#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Failing and saying what is going on. Sourced, never run.

raise() {
  local code=1
  local message="$*"

  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    code="${1:-}"
    message="${*:2}"
  fi

  echo "Error: $message" >&2
  exit "$code"
}

raise_info() {
  local code=1
  local message="$*"

  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    code="${1:-}"
    message="${*:2}"
  fi

  echo "Info: $message" >&2
  exit "$code"
}

# One line per step, marked for whoever is watching. cuos-release/tool.sh puts
# lines carrying this marker on the terminal - indented by itself, so this one
# does not - and everything else in output/NAME.build.log. On a device the
# marker is just a prefix in the journal. Keep it in step with
# log_is_step_line() over there.
step() {
  echo "==> $*"
}
