#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# The configuration layers. /system.json is the *effective* configuration and
# what everything reads; it is built from two layers and written by nothing
# but config_rebuild and config_commit:
#
#   LAYER_DIR/system_<slot>.remote.json  what came from outside - "update",
#                                        provisioning. Per slot, because it
#                                        carries the image references.
#   LAYER_DIR/system.local.json          what was set on the device - "patch*",
#                                        the console, cloud-init. Shared by
#                                        both slots.
#
# effective = remote * local: local wins, until the remote layer changes the
# same key - a new value or its removal. Then the key leaves the local layer
# ("last write wins, per key"). A key is a path as jq's "*" sees it: objects
# down to their leaves, anything else - arrays included - as one unit, so
# "network" is local or remote as a whole. A local value equal to the remote
# one is dropped on every write: the local layer holds real deviations only.
#
# Sourced by utils.sh. Everything below takes and prints JSON; files are read
# and written only by the functions marked so.

LAYER_DIR="${LAYER_DIR:-"/data"}"
LOCAL_LAYER="${LOCAL_LAYER:-"${LAYER_DIR}/system.local.json"}"
LAYER_LOCK="${LAYER_LOCK:-"/run/cuos-config.lock"}"

# Keys that are the device's own when a device from before the layers is
# migrated. The NTP servers are part of "network" ("ntp-server" per entry).
# Everything else becomes remote: a repository that does not set "network"
# must not take the device's address away with its first replace.
MIGRATION_SEED='[["network"], ["hostname"]]'

JQ_LAYERS='
  # The paths of an object that "*" treats as values: objects are descended
  # into, anything else is a leaf. An empty object is a leaf of its own; the
  # root is not.
  def lpaths:
    if type == "object" and length > 0 then
      keys_unsorted[] as $k | .[$k] | lpaths | [$k] + .
    else [] end;
  def leaves: select(type == "object" and length > 0) | lpaths;

  # [value] at $p, or [] if there is none - a null is a value.
  def at($p):
    reduce $p[] as $k ([.];
      if length == 1 and (.[0] | type) == "object" and (.[0] | has($k))
      then [.[0][$k]] else [] end);

  def prefix($a; $b): ($a | length) <= ($b | length) and $b[0:($a | length)] == $a;

  # Empty objects left behind by a deletion.
  def prune:
    if type == "object" then
      with_entries(.value |= prune) | with_entries(select(.value != {}))
    else . end;

  # The paths whose value differs between two remote layers: a new value, a
  # new key, or a key gone.
  def changed($old; $new):
    [($old | leaves), ($new | leaves)] | unique
    | map(. as $p | select(($old | at($p)) != ($new | at($p))));

  # Takes every local key a changed path touches out of the local layer -
  # the key itself, anything below it, and a local value above it.
  def withdraw($changed):
    . as $l
    | reduce ($l | leaves) as $p ($l;
        if any($changed[]; prefix(.; $p) or prefix($p; .))
        then delpaths([$p]) else . end)
    | prune;

  # Drops local values the remote layer has anyway.
  def normalise($remote):
    . as $l
    | reduce ($l | leaves) as $p ($l;
        if ($remote | at($p)) == ($l | at($p)) then delpaths([$p]) else . end)
    | prune;

  # Splits a configuration written without layers. $seed are the paths that
  # become local, with their current values.
  def migrate($seed):
    . as $e
    | reduce $seed[] as $p ({remote: $e, local: {}};
        ($e | at($p)) as $v
        | if $v == [] then .
          else .local |= setpath($p; $v[0]) | .remote |= delpaths([$p]) end)
    | .remote |= prune;

  def overrides: [leaves | join(".")];
'

# jq with the functions above. The filter is the last argument, after the
# options; input comes from stdin or -n.
layers_jq() {
  jq "${@:1:$#-1}" "${JQ_LAYERS} ${!#}"
}

# --- pure functions ----------------------------------------------------------

# $1 old remote, $2 new remote. Prints the changed paths.
config_changed() {
  layers_jq -nc --argjson old "$1" --argjson new "$2" 'changed($old; $new)'
}

# $1 local, $2 changed paths, $3 the remote layer they lead to. Prints the
# local layer after the change: withdrawn, then normalised.
config_withdraw() {
  layers_jq -nc --argjson local "$1" --argjson changed "$2" --argjson remote "$3" \
    '$local | withdraw($changed) | normalise($remote)'
}

# $1 local, $2 remote. Prints the local layer without what remote has anyway.
config_normalise() {
  layers_jq -nc --argjson local "$1" --argjson remote "$2" '$local | normalise($remote)'
}

# $1 remote, $2 local. Prints the effective configuration.
config_effective() {
  jq -n --argjson remote "$1" --argjson local "$2" '$remote * $local'
}

# $1 effective configuration, $2 local layer to keep ({} if there is none).
# Prints {remote, local}.
config_migrate() {
  layers_jq -nc --argjson eff "$1" --argjson local "$2" --argjson seed "${MIGRATION_SEED}" \
    '$eff | migrate($seed + ($local | [leaves]))'
}

# $1 current remote, $2 config given to "update", $3 "true" to replace.
# Prints the plan an update carries until it is committed:
# {remote: the new remote layer, changed: the paths it changes}.
config_plan_update() {
  layers_jq -nc --argjson remote "$1" --argjson config "$2" --argjson replace "${3:-false}" '
    (if $replace then $config else $remote * $config end) as $new
    | {remote: $new, changed: changed($remote; $new)}'
}

# $1 local layer. Prints its paths, one string each ("network", "a.b").
config_overrides() {
  layers_jq -nc --argjson local "$1" '$local | overrides'
}

# --- files -------------------------------------------------------------------

config_active_slot() {
  cat "${T_FILE_SLOT:-"/etc/active_slot"}" 2>/dev/null || echo "A"
}

config_other_slot() {
  if [[ "$(config_active_slot)" == "A" ]]; then echo "B"; else echo "A"; fi
}

# $1 slot
config_remote_path() {
  echo "${LAYER_DIR}/system_${1}.remote.json"
}

# Reads a layer file; prints {} for one that is not there.
config_read() {
  if [[ -f "$1" ]]; then
    jq -c . "$1"
  else
    echo '{}'
  fi
}

# $1 target, $2 JSON. Writes only if the content differs, and through the
# path: the effective configuration is reached by a symlink into /data, which
# "mv" would replace, and in a container it may be a bind mount, which "mv"
# cannot replace at all. Returns 0 if it wrote, 1 if there was nothing to
# write, 2 if writing failed.
config_write() {
  local target="$1"
  local tmp

  tmp="$(mktemp "${TMPDIR:-"/tmp"}/cuos-config.XXXXXX")" || return 2
  if ! jq . <<<"$2" >"${tmp}"; then
    rm -f "${tmp}"
    return 2
  fi
  if [[ -f "${target}" ]] && json_equal "${tmp}" "${target}"; then
    rm -f "${tmp}"
    return 1
  fi
  if ! cat "${tmp}" >"${target}"; then
    rm -f "${tmp}"
    return 2
  fi
  rm -f "${tmp}"
  return 0
}

# $1 slot. Where the checksum of the slot's effective configuration is kept, as
# this code last wrote it.
config_sum_path() {
  echo "${LAYER_DIR}/system_${1}.sum"
}

# $1 file. cksum, not sha256sum: it is POSIX, so busybox and macOS have it too,
# and this only has to notice a change, not withstand one made on purpose.
config_sum() {
  cksum <"$1" | awk '{ print $1, $2 }'
}

# $1 slot, $2 the path of its effective configuration. True if someone who does
# not know the layers wrote it since this code did: the CuOS of an older
# release - a downgrade, then an update from there - or a hand edit. Without a
# checksum there is nothing to tell, and it is not taken as foreign.
config_is_foreign() {
  local sum_path

  sum_path="$(config_sum_path "$1")"
  [[ -f "${sum_path}" && -f "$2" ]] || return 1
  [[ "$(config_sum "$2")" != "$(cat "${sum_path}")" ]]
}

# $1 slot, $2 path, $3 JSON. config_write for an effective configuration: it
# remembers the checksum of what is there afterwards, written or not. Returns
# config_write's codes.
config_write_effective() {
  local rc

  config_write "$2" "$3"
  rc="$?"
  if [[ "${rc}" != "2" ]]; then
    config_sum "$2" >"$(config_sum_path "$1")" 2>/dev/null || true
  fi
  return "${rc}"
}

# Runs "$@" holding the layer lock: API calls run in parallel, one process per
# connection, and each of these is a read-modify-write of the local layer.
with_layer_lock() {
  (
    if command -v flock >/dev/null 2>&1; then
      flock -x 200
    fi
    "$@"
  ) 200>"${LAYER_LOCK}"
}

# File. A device that has a configuration but no layers - it ran a CuOS from
# before them - gets them from what it has: MIGRATION_SEED becomes local,
# everything else remote. The same when the effective configuration was written
# by someone who does not know the layers (config_is_foreign): its remote layer
# is out of date then, and building from it would throw away what was written.
# Keys already local stay local, with the values found. $1 is the effective
# configuration of this slot.
config_migrate_if_needed() {
  local effective_path="${1:-"${CONFIG_PATH}"}"
  local slot remote_path layers local_layer

  slot="$(config_active_slot)"
  remote_path="$(config_remote_path "${slot}")"
  [[ -f "${effective_path}" ]] || return 0
  if [[ -f "${remote_path}" ]]; then
    config_is_foreign "${slot}" "${effective_path}" || return 0
    echo "Info: ${effective_path} was written without the layers; taking it over" >&2
  fi

  local_layer="$(config_read "${LOCAL_LAYER}")"
  layers="$(config_migrate "$(jq -c . "${effective_path}")" "${local_layer}")" || return 2

  config_write "${LOCAL_LAYER}" "$(jq -c .local <<<"${layers}")"
  [[ "$?" == "2" ]] && return 2
  config_write "${remote_path}" "$(jq -c .remote <<<"${layers}")"
  [[ "$?" == "2" ]] && return 2
  config_sum "${effective_path}" >"$(config_sum_path "${slot}")" 2>/dev/null || true
  return 0
}

# File. Builds the effective configuration of this slot (CONFIG_PATH) from its
# layers and writes it if it differs. Returns config_write's codes: 0 written - run
# "init.sh --reinit" -, 1 unchanged, 2 failed.
config_rebuild() {
  local remote

  local slot
  slot="$(config_active_slot)"
  remote="$(config_read "$(config_remote_path "${slot}")")"
  config_write_effective "${slot}" "${CONFIG_PATH}" \
    "$(config_effective "${remote}" "$(config_read "${LOCAL_LAYER}")")"
}

# File. $1 is a jq filter applied to the local layer, with $remote bound to
# this slot's remote layer and any further arguments passed on to jq. The
# result is normalised and written, and the effective configuration rebuilt.
# Returns config_rebuild's codes.
config_local_update() {
  with_layer_lock _config_local_update "$@"
}
_config_local_update() {
  local filter="$1"
  local remote new_local

  remote="$(config_read "$(config_remote_path "$(config_active_slot)")")"
  new_local="$(config_read "${LOCAL_LAYER}" \
    | layers_jq -c --argjson remote "${remote}" "${@:2}" "${filter} | normalise(\$remote)")" \
    || return 2

  config_write "${LOCAL_LAYER}" "${new_local}"
  [[ "$?" == "2" ]] && return 2
  config_rebuild
}

# File. $1 is a partial configuration set on the device.
config_local_patch() {
  config_local_update '. * $patch' --argjson patch "$1"
}

# File. $1 is the effective configuration an editor on the device started
# from - the console's network dialog, the expert editor -, $2 what it saved.
# Only the paths the edit changed go into the local layer: an editor holds the
# whole configuration for minutes, and a value an update changed meanwhile must
# not come back as a setting of this device. A path the edit removed leaves the
# local layer, so what remote has shows through again.
config_local_edit() {
  config_local_update '
    . as $l
    | reduce changed($orig; $edited)[] as $p ($l;
        ($edited | at($p)) as $v
        | if $v == [] then delpaths([$p]) else setpath($p; $v[0]) end)' \
    --argjson orig "$1" --argjson edited "$2"
}

# File. Empties the local layer.
config_local_reset() {
  config_local_update '{}'
}

# File. $1 the plan of config_plan_update, $2 the slot it is for, $3 the path
# of that slot's effective configuration. Writes the slot's remote layer, the
# local layer with what the plan withdraws, and the effective configuration -
# in that order. The local layer is read now, not when the plan was made: an
# update runs for a while, and a console change made meanwhile is kept.
# Returns config_write's codes for the effective configuration.
config_commit() {
  with_layer_lock _config_commit "$@"
}
_config_commit() {
  local plan="$1"
  local slot="$2"
  local effective_path="$3"
  local remote changed new_local

  remote="$(jq -c .remote <<<"${plan}")" || return 2
  changed="$(jq -c .changed <<<"${plan}")" || return 2
  new_local="$(config_withdraw "$(config_read "${LOCAL_LAYER}")" "${changed}" "${remote}")" \
    || return 2

  config_write "$(config_remote_path "${slot}")" "${remote}"
  [[ "$?" == "2" ]] && return 2
  config_write "${LOCAL_LAYER}" "${new_local}"
  [[ "$?" == "2" ]] && return 2
  config_write_effective "${slot}" "${effective_path}" \
    "$(config_effective "${remote}" "${new_local}")"
}
