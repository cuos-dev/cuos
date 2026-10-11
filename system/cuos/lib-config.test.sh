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
LOCAL_LAYER="${LAYER_DIR}/system_A.local.json"
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
  '{"remote":{"a":1,"b":2,"os_image_version":"v2"},"changed":[["os_image_version"]],"base":{"a":1,"b":2,"os_image_version":"v1"},"config":{"os_image_version":"v2"},"replace":false}' \
  config_plan_update '{"a": 1, "b": 2, "os_image_version": "v1"}' '{"os_image_version": "v2"}'
expect "plan: replace takes the config as the remote layer" \
  '{"remote":{"a":1},"changed":[["b"]],"base":{"a":1,"b":2},"config":{"a":1},"replace":true}' \
  config_plan_update '{"a": 1, "b": 2}' '{"a": 1}' true

expect "overrides: as dotted paths" '["a.b","network"]' \
  config_overrides '{"network": [1], "a": {"b": 1}}'
expect "overrides: a dotted key and a path to the same name, listed once" '["a.b"]' \
  config_overrides '{"a.b": 1, "a": {"b": 2}}'
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
echo '{"os_image": "z"}' >"$(config_remote_path A)"
config_migrate_if_needed 2>/dev/null
expect "migrate_if_needed: once - a file it has seen is not taken again" \
  '{"os_image":"z"}' remote_layer
echo '{"os_image": "x"}' >"$(config_remote_path A)"

expect_rc "rebuild: an unchanged result is not written" 1 config_rebuild
config_local_patch '{"hostname": "mine"}' >/dev/null
expect "rebuild: remote * local" '{"os_image":"x","network":[{"dhcp":true}],"hostname":"mine"}' effective
expect_rc "rebuild: what this code wrote is not foreign" 1 config_is_foreign A "${CONFIG_PATH}"

# The CuOS of an older release - after a downgrade - or a hand edit writes the
# effective file, and the remote layer is out of date. It is taken over, not
# built over: network and hostname stay local, with the values found.
echo '{"os_image": "v3", "network": [{"dhcp": false}], "hostname": "mine", "keyboard_layout": "us"}' \
  >"${CONFIG_PATH}"
expect_rc "foreign: noticed" 0 config_is_foreign A "${CONFIG_PATH}"
config_migrate_if_needed 2>/dev/null
config_rebuild
expect "foreign: what was written stays" \
  '{"hostname":"mine","keyboard_layout":"us","network":[{"dhcp":false}],"os_image":"v3"}' \
  jq -S -c . "${CONFIG_PATH}"
expect "foreign: is the remote layer now" '{"os_image":"v3","keyboard_layout":"us"}' remote_layer
expect "foreign: and the local one keeps its keys" \
  '{"network":[{"dhcp":false}],"hostname":"mine"}' local_layer
expect_rc "foreign: and is not foreign any more" 1 config_is_foreign A "${CONFIG_PATH}"

rm -f "$(config_sum_path A)"
echo '{"os_image": "w"}' >"${CONFIG_PATH}"
expect_rc "foreign: without a checksum there is nothing to tell" 1 \
  config_is_foreign A "${CONFIG_PATH}"

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

# The whole downgrade: v2 (layers) installs v1 into B and boots it; v1 updates
# to v3 into A, writing only A's effective file; A boots v3.
reset_device
echo "B" >"${T_FILE_SLOT}"
echo '{"os_image_version": "v2", "hostname": "box"}' >"$(config_remote_path B)"
plan="$(config_plan_update "$(remote_layer B)" '{"os_image_version": "v1"}' true)"
config_commit "${plan}" A "${LAYER_DIR}/system_A.json" >/dev/null
echo '{"os_image_version": "v3", "hostname": "box"}' >"${LAYER_DIR}/system_A.json"
echo "A" >"${T_FILE_SLOT}"
rm -f "${CONFIG_PATH}"
ln -s "${LAYER_DIR}/system_A.json" "${CONFIG_PATH}"
config_migrate_if_needed 2>/dev/null
config_rebuild
expect "downgrade and back: the slot boots with what the old release wrote" \
  '{"hostname":"box","os_image_version":"v3"}' jq -S -c . "${CONFIG_PATH}"
rm -f "${CONFIG_PATH}"
echo "A" >"${T_FILE_SLOT}"

# The rollback case (review R2-2): slot A's network was fixed at the console;
# an update to B brings a new network and withdraws the local one - in B's
# layer. B fails, the system rolls back to A, and A still has the fix.
reset_device
echo '{"os_image_version": "v1", "network": [{"dhcp": true}]}' >"$(config_remote_path A)"
config_local_patch '{"network": [{"dhcp": false, "ip-address": "10.0.0.5"}]}' >/dev/null
plan="$(config_plan_update "$(remote_layer A)" '{"os_image_version": "v2", "network": [{"dhcp": true, "gateway": "10.0.0.1"}]}' true)"
config_commit "${plan}" B "${WORK_DIR}/system_next.json"
expect "commit: the new slot gets the running slot's local layer, withdrawn" '{}' \
  jq -c . "$(config_local_path B)"
expect "commit: the running slot's local layer stays, for a rollback" \
  '{"network":[{"dhcp":false,"ip-address":"10.0.0.5"}]}' local_layer
expect_rc "commit: and a rebuild after the rollback finds A as it was" 1 config_rebuild

# A config-only update lands on A while an update's plan waits for its commit:
# the plan is made again from the remote layer the config-only update left.
reset_device
echo '{"os_image_version": "v1", "a": 1}' >"$(config_remote_path A)"
plan="$(config_plan_update "$(remote_layer A)" '{"os_image_version": "v2"}')"
echo '{"os_image_version": "v1", "a": 1, "b": 2}' >"$(config_remote_path A)"
config_commit "${plan}" B "${WORK_DIR}/system_next.json"
expect "commit: a stale plan is made again from the current remote layer" \
  '{"os_image_version":"v2","a":1,"b":2}' remote_layer B

# A corrupt layer - a power loss, a full disk - must not become an empty
# configuration (review R2-1).
reset_device
echo '{"os_image": "x", "hostname": "box"}' >"$(config_remote_path A)"
config_rebuild
echo '{"os_image": "x", "hostn' >"$(config_remote_path A)"
expect_rc "corrupt layer: config_read fails" 1 config_read "$(config_remote_path A)"
expect_rc "corrupt layer: the rebuild fails" 2 config_rebuild
expect "corrupt layer: and leaves the configuration alone" '{"os_image":"x","hostname":"box"}' effective
expect_rc "corrupt layer: a local patch fails too" 2 config_local_patch '{"hostname": "mine"}'
expect "corrupt layer: and leaves it alone as well" '{"os_image":"x","hostname":"box"}' effective
echo '[1]' >"$(config_remote_path A)"
expect_rc "corrupt layer: an array is no layer" 1 config_read "$(config_remote_path A)"
expect_rc "config_write: empty input is refused" 2 config_write "${WORK_DIR}/w.json" ""
expect_rc "config_write: so is anything but an object" 2 config_write "${WORK_DIR}/w.json" '"x"'
expect_rc "config_write: and nothing was written" 1 test -e "${WORK_DIR}/w.json"

inode() {
  ls -i "$1" | awk '{ print $1 }'
}
reset_device
echo '{"os_image": "x"}' >"$(config_remote_path A)"
config_rebuild
before_effective="$(inode "${CONFIG_PATH}")"
before_local="$(inode "$(config_remote_path A)")"
config_write "$(config_remote_path A)" '{"os_image": "y"}'
config_rebuild
expect "config_write: a layer is replaced by a rename" "yes" \
  bash -c '[[ "$1" != "$2" ]] && echo yes' _ "${before_local}" "$(inode "$(config_remote_path A)")"
expect "config_write: the effective file in place - a bind mount keeps its inode" \
  "${before_effective}" inode "${CONFIG_PATH}"

# An object turned into a value in the expert editor (review R2-3).
reset_device
echo '{"a": {"b": 1}, "c": 1}' >"$(config_remote_path A)"
config_rebuild
expect_rc "local_edit: an object that became a value" 0 \
  config_local_edit '{"a": {"b": 1}, "c": 1}' '{"a": 5, "c": 1}'
expect "local_edit: is a local value" '{"a":5}' local_layer
expect_rc "local_edit: and back to an object" 0 \
  config_local_edit '{"a": 5, "c": 1}' '{"a": {"x": 2}, "c": 1}'
# Objects merge with the remote layer's, down to their leaves: b shows through.
expect "local_edit: the object replaces the value" '{"a":{"b":1,"x":2},"c":1}' effective

# A hand edit, then a patch: the patch must not rebuild it away (review R2-4).
reset_device
echo '{"os_image": "x", "hostname": "box"}' >"$(config_remote_path A)"
config_rebuild
echo '{"os_image": "x", "hostname": "box", "keyboard_layout": "fr"}' >"${CONFIG_PATH}"
config_local_patch '{"hostname": "mine"}' 2>/dev/null
expect "local_patch: a hand edit made before it is taken over first" \
  '{"hostname":"mine","keyboard_layout":"fr","os_image":"x"}' jq -S -c . "${CONFIG_PATH}"

# Reformatted, not changed: not taken over (review R2-7).
reset_device
echo '{"os_image": "x", "network": [1], "hostname": "box"}' >"$(config_remote_path A)"
config_rebuild
jq -S . "${CONFIG_PATH}" >"${WORK_DIR}/reformatted" && cat "${WORK_DIR}/reformatted" >"${CONFIG_PATH}"
config_migrate_if_needed 2>/dev/null
expect "foreign: a mere reformat moves nothing into the local layer" '{}' \
  bash -c 'jq -c . "$1" 2>/dev/null || echo "{}"' _ "${LOCAL_LAYER}"
expect_rc "foreign: and is not foreign afterwards" 1 config_is_foreign A "${CONFIG_PATH}"

# A lock that cannot be taken is a failure, not "unchanged" (review R2-5).
expect_rc "lock: cannot be opened" 2 \
  env LAYER_LOCK="${WORK_DIR}/no/such/dir/lock" bash -c \
  'source "$1/utils.sh"; config_local_patch "{\"hostname\": \"x\"}"' _ "${SCRIPT_DIR}"

# Only what the seed emptied is pruned (review R2-6).
expect "migrate: an empty object elsewhere stays" \
  '{"remote":{"os_image":"x","extra":{}},"local":{"network":[1]}}' \
  config_migrate '{"os_image": "x", "extra": {}, "network": [1]}' '{}'
expect "normalise: an empty object over a value is a setting" '{"foo":{}}' \
  config_normalise '{"foo": {}}' '{"foo": 1}'
expect "withdraw: the emptied parent goes" '{}' \
  config_withdraw '{"a": {"b": 1}}' '[["a","b"]]' '{"a": {"b": 2}}'

summary
