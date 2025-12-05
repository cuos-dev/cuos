#!/bin/bash

SCRIPT_DIR="$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd)"

if [[ "${UID}" != "0" ]]; then
  :
elif command -v apk >/dev/null 2>&1; then
  apk update
  apk add jsonschema-jv
elif command -v apt >/dev/null 2>&1; then
  apt-get update
  apt-get install jsonschema-jv
fi

jv "${SCRIPT_DIR}/system-schema.json"
