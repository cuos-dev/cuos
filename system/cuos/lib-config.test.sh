#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR="$( cd -- "$( dirname -- "$( readlink -f "${BASH_SOURCE[0]}" )" )" &> /dev/null && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-test.sh"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

export LAYER_DIR="${WORK_DIR}/data"
export LOCAL_LAYER="${LAYER_DIR}/system.local.json"
export LAYER_LOCK="${WORK_DIR}/lock"
export T_FILE_SLOT="${WORK_DIR}/active_slot"
export CONFIG_PATH="${WORK_DIR}/system.json"
mkdir -p "${LAYER_DIR}"
echo "A" >"${T_FILE_SLOT}"

# --- changed ---

expect "changed: a new value" '[["os_image_version"]]' \
  config_changed '{"os_image_version": "v1", "a": 1}' '{"os_image_version": "v2", "a": 1}'
expect "changed: a key gone" '[["update_registry_user"]]' \
  config_changed '{"update_registry_user": "x", "a": 1}' '{"a": 1}'
expect "changed: a new key" '[["b"]]' config_changed '{"a": 1}' '{"a": 1, "b": 2}'
expect "changed: nothing" '[]' config_changed '{"a": {"b": 1}}' '{"a": {"b": 1}}'
expect "changed: objects to their leaves" '[["a","c"]]' \
  config_changed '{"a": {"b": 1, "c": 2}}' '{"a": {"b": 1, "c": 3}}'
expect "changed: an array is one value" '[["network"]]' \
  config_changed '{"network": [{"dhcp": true}]}' '{"network": [{"dhcp": false}]}'
expect "changed: a scalar becomes an object" '[["a"],["a","b"]]' \
  config_changed '{"a": 1}' '{"a": {"b": 1}}'
expect "changed: null is a value, absence is not" '[["a"]]' \
  config_changed '{"a": null}' '{}'

# --- withdraw ---

expect "withdraw: a key the remote changed leaves the local layer" '{"hostname":"box"}' \
  config_withdraw '{"network": [{"dhcp": false}], "hostname": "box"}' '[["network"]]' '{"network": [{"dhcp": true}]}'
expect "withdraw: a key the remote did not touch stays" '{"network":[{"dhcp":false}]}' \
  config_withdraw '{"network": [{"dhcp": false}]}' '[["os_image_version"]]' '{"os_image_version": "v2"}'
expect "withdraw: below a changed path" '{}' \
  config_withdraw '{"a": {"b": 1}}' '[["a"]]' '{}'
expect "withdraw: above a changed path" '{}' \
  config_withdraw '{"a": 5}' '[["a","b"]]' '{"a": {"b": 1}}'
expect "withdraw: and empty objects go with it" '{"a":{"c":2}}' \
  config_withdraw '{"a": {"b": 1, "c": 2}, "d": {"e": 1}}' '[["a","b"],["d","e"]]' '{}'
expect "withdraw: what equals the new remote is dropped as well" '{}' \
  config_withdraw '{"keyboard_layout": "de"}' '[]' '{"keyboard_layout": "de"}'

# --- normalise ---

expect "normalise: equal values go" '{"hostname":"mine"}' \
  config_normalise '{"hostname": "mine", "keyboard_layout": "de"}' '{"hostname": "box", "keyboard_layout": "de"}'
expect "normalise: a nested equal value" '{"a":{"c":3}}' \
  config_normalise '{"a": {"b": 1, "c": 3}}' '{"a": {"b": 1, "c": 2}}'

# --- effective ---

expect "effective: local wins" '{"a":1,"hostname":"mine"}' \
  jq -c . <(config_effective '{"a": 1, "hostname": "box"}' '{"hostname": "mine"}')

# --- migrate ---

expect "migrate: network and hostname are local, the rest remote" \
  '{"remote":{"os_image":"x","keyboard_layout":"de"},"local":{"network":[{"dhcp":true}],"hostname":"box"}}' \
  config_migrate '{"os_image": "x", "network": [{"dhcp": true}], "hostname": "box", "keyboard_layout": "de"}' '{}'
expect "migrate: keys a device does not have are not invented" \
  '{"remote":{"os_image":"x"},"local":{}}' \
  config_migrate '{"os_image": "x"}' '{}'
expect "migrate: an existing local layer keeps its keys, with the current values" \
  '{"remote":{"os_image":"x"},"local":{"network":[1],"keyboard_layout":"us"}}' \
  config_migrate '{"os_image": "x", "network": [1], "keyboard_layout": "us"}' '{"keyboard_layout": "de"}'

# --- plan ---

expect "plan: update merges by default" \
  '{"remote":{"a":1,"b":2,"os_image_version":"v2"},"changed":[["os_image_version"]]}' \
  config_plan_update '{"a": 1, "b": 2, "os_image_version": "v1"}' '{"os_image_version": "v2"}'
expect "plan: replace takes the config as the remote layer" \
  '{"remote":{"a":1},"changed":[["b"]]}' \
  config_plan_update '{"a": 1, "b": 2}' '{"a": 1}' true

expect "overrides: as dotted paths" '["network","a.b"]' \
  config_overrides '{"network": [1], "a": {"b": 1}}'
expect "overrides: none" '[]' config_overrides '{}'

# --- files ---

reset_device() {
  rm -f "${LAYER_DIR}"/* "${CONFIG_PATH}"
}

effective() {
  jq -c . "${CONFIG_PATH}"
}
local_layer() {
  jq -c . "${LOCAL_LAYER}"
}
remote_layer() {
  jq -c . "$(config_remote_path "${1:-A}")"
}

reset_device
echo '{"os_image": "x", "network": [{"dhcp": true}], "hostname": "box"}' >"${CONFIG_PATH}"
config_migrate_if_needed
expect "migrate_if_needed: a device without layers gets them" \
  '{"network":[{"dhcp":true}],"hostname":"box"} {"os_image":"x"}' \
  echo "$(local_layer) $(remote_layer)"
echo '{"os_image": "y"}' >"${CONFIG_PATH}"
config_migrate_if_needed
expect "migrate_if_needed: once" '{"os_image":"x"}' remote_layer

expect_rc "rebuild: writes what differs" 0 config_rebuild
expect "rebuild: remote * local" '{"os_image":"x","network":[{"dhcp":true}],"hostname":"box"}' effective
expect_rc "rebuild: an unchanged result is not written" 1 config_rebuild

# "cat >", not "mv": the effective configuration is a symlink.
reset_device
ln -s "${LAYER_DIR}/system_A.json" "${CONFIG_PATH}"
echo '{"os_image": "x"}' >"$(config_remote_path A)"
config_rebuild
expect "rebuild: through the symlink" "link" \
  bash -c '[[ -L "$1" ]] && echo link' _ "${CONFIG_PATH}"
expect "rebuild: into its target" '{"os_image":"x"}' jq -c . "${LAYER_DIR}/system_A.json"
rm -f "${CONFIG_PATH}"

reset_device
echo '{"hostname": "box", "keyboard_layout": "de"}' >"$(config_remote_path A)"
expect_rc "local_patch: a change is written" 0 config_local_patch '{"hostname": "mine"}'
expect "local_patch: into the local layer" '{"hostname":"mine"}' local_layer
expect "local_patch: and the effective config" '{"hostname":"mine","keyboard_layout":"de"}' effective
expect_rc "local_patch: the remote value again" 0 config_local_patch '{"hostname": "box"}'
expect "local_patch: normalised away" '{}' local_layer
expect_rc "local_patch: nothing new" 1 config_local_patch '{"keyboard_layout": "de"}'

# The editor started from what is in effect; meanwhile the remote layer moved
# keyboard_layout on. Only the hostname was edited.
editor_start='{"hostname": "box", "keyboard_layout": "de"}'
echo '{"hostname": "box", "keyboard_layout": "us"}' >"$(config_remote_path A)"
config_local_edit "${editor_start}" '{"hostname": "edited", "keyboard_layout": "de"}'
expect "local_edit: the edited path is local" '{"hostname":"edited"}' local_layer
expect "local_edit: a value the editor merely held is not" \
  '{"hostname":"edited","keyboard_layout":"us"}' effective
config_local_edit '{"hostname": "edited", "keyboard_layout": "us"}' '{"keyboard_layout": "us"}'
expect "local_edit: a path the edit removed leaves the local layer" '{}' local_layer
echo '{"hostname": "box", "keyboard_layout": "de"}' >"$(config_remote_path A)"
config_local_patch '{"hostname": "edited"}' >/dev/null
config_local_reset
expect "local_reset: empty" '{}' local_layer
expect "local_reset: remote again" '{"hostname":"box","keyboard_layout":"de"}' effective

# The acceptance case: a console network survives a replace without
# "network", and goes with one that changes it.
reset_device
echo '{"os_image_version": "v1", "network": [{"dhcp": true}]}' >"$(config_remote_path A)"
config_local_patch '{"network": [{"dhcp": false, "ip-address": "10.0.0.5"}]}'
plan="$(config_plan_update "$(remote_layer)" '{"os_image_version": "v2", "network": [{"dhcp": true}]}' true)"
config_commit "${plan}" A "${CONFIG_PATH}"
expect "commit: a replace that leaves network as it was keeps the console's" \
  '{"os_image_version":"v2","network":[{"dhcp":false,"ip-address":"10.0.0.5"}]}' effective
plan="$(config_plan_update "$(remote_layer)" '{"os_image_version": "v2", "network": [{"dhcp": true, "ntp-server": "ntp.local"}]}' true)"
config_commit "${plan}" A "${CONFIG_PATH}"
expect "commit: one that changes network withdraws it" \
  '{"os_image_version":"v2","network":[{"dhcp":true,"ntp-server":"ntp.local"}]}' effective
expect "commit: and the local layer is empty" '{}' local_layer

# An update goes to the other slot: this one's remote layer stays for rollback.
reset_device
echo '{"os_image_version": "v1", "update_registry_user": "old"}' >"$(config_remote_path A)"
plan="$(config_plan_update "$(remote_layer A)" '{"os_image_version": "v2"}' true)"
config_commit "${plan}" B "${WORK_DIR}/system_next.json"
expect "commit: the new slot's remote layer" '{"os_image_version":"v2"}' remote_layer B
expect "commit: the old slot's is untouched" \
  '{"os_image_version":"v1","update_registry_user":"old"}' remote_layer A
expect "commit: the new slot's effective config" '{"os_image_version":"v2"}' \
  jq -c . "${WORK_DIR}/system_next.json"

summary
