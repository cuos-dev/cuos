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
#   LAYER_DIR/system_<slot>.local.json   what was set on the device - "patch*",
#                                        the console, cloud-init. Per slot as
#                                        well: an update hands the running
#                                        slot's on to the new slot and leaves
#                                        its own alone, so a rollback finds it
#                                        as it was.
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

  # Deletes the value at $p, and the objects above it the deletion leaves
  # empty. Only those: an empty object elsewhere is a value someone set.
  def delete($p):
    if at($p) == [] then . else delpaths([$p]) end
    | if ($p | length) > 1 and getpath($p[:-1]) == {}
      then delete($p[:-1]) else . end;

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
        then delete($p) else . end);

  # Drops local values the remote layer has anyway.
  def normalise($remote):
    . as $l
    | reduce ($l | leaves) as $p ($l;
        if ($remote | at($p)) == ($l | at($p)) then delete($p) else . end);

  # Splits a configuration written without layers. $seed are the paths that
  # become local, with their current values.
  def migrate($seed):
    . as $e
    | reduce $seed[] as $p ({remote: $e, local: {}};
        ($e | at($p)) as $v
        | if $v == [] then .
          else .local |= setpath($p; $v[0]) | .remote |= delete($p) end);

  def overrides: [leaves | join(".")] | unique;

  # Applies what an editor changed to a layer: every changed path gets the
  # edited value, or goes. A path below one already set or deleted is part of
  # that value: "a" turned from an object into 1 changes [a] and [a,b], and
  # [a,b] cannot be deleted from a number.
  def edit($orig; $edited):
    reduce changed($orig; $edited)[] as $p ({l: ., done: []};
      if any(.done[]; prefix(.; $p)) then .
      else ($edited | at($p)) as $v
        | .done += [$p]
        | .l |= (if $v == [] then delete($p) else setpath($p; $v[0]) end)
      end)
    | .l;
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
# {remote: the new remote layer, changed: the paths it changes, and what it
# was made from: base, config, replace}.
config_plan_update() {
  layers_jq -nc --argjson remote "$1" --argjson config "$2" --argjson replace "${3:-false}" '
    (if $replace then $config else $remote * $config end) as $new
    | {remote: $new, changed: changed($remote; $new),
       base: $remote, config: $config, replace: $replace}'
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

# $1 slot
config_local_path() {
  echo "${LAYER_DIR}/system_${1}.local.json"
}

# Reads a layer file; prints {} for one that is not there. A file that is there
# and no JSON object fails, and loudly: taken as {} it would drop every key it
# held from the configuration.
config_read() {
  if [[ ! -f "$1" ]]; then
    echo '{}'
    return 0
  fi
  if ! jq -ec 'if type == "object" then . else error("not an object") end' "$1" 2>/dev/null; then
    echo "Error: $1 is no JSON object" >&2
    return 1
  fi
}

# $1 JSON. True for an object - what every layer and configuration is. Empty
# input is not one: "jq ." accepts it and prints nothing, which written out is
# an empty configuration.
config_is_object() {
  [[ -n "$1" ]] && jq -e 'type == "object"' <<<"$1" >/dev/null 2>&1
}

# $1 target, $2 JSON, $3 "in-place" for a file others hold open. Writes only if
# the content differs. Returns 0 if it wrote, 1 if there was nothing to write,
# 2 if writing failed or $2 is no JSON object.
#
# A layer file is replaced by a rename: it is complete or not there at all,
# also after a power loss. The effective configuration is written in place
# (replace_file_content): it is reached by a symlink into /data, which a rename
# would replace, and it is bind-mounted into containers, which would go on
# reading the old inode.
config_write() {
  local target="$1"
  local mode="${3:-}"
  local tmp

  if ! config_is_object "$2"; then
    echo "Error: refusing to write ${target}: no JSON object" >&2
    return 2
  fi
  # Beside the target for a rename, which cannot cross filesystems.
  local tmp_dir="${TMPDIR:-"/tmp"}"
  [[ "${mode}" == "in-place" ]] || tmp_dir="$(dirname -- "$(readlink -f -- "${target}")")"
  tmp="$(mktemp "${tmp_dir}/.cuos-config.XXXXXX")" || return 2
  if ! jq . <<<"$2" >"${tmp}"; then
    rm -f "${tmp}"
    return 2
  fi
  if [[ -f "${target}" ]] && json_equal "${tmp}" "${target}"; then
    rm -f "${tmp}"
    return 1
  fi
  if [[ "${mode}" == "in-place" ]]; then
    replace_file_content "${target}" <"${tmp}"
    local rc="$?"
    rm -f "${tmp}"
    [[ "${rc}" == "0" ]] || return 2
    return 0
  fi
  if ! sync -- "${tmp}" 2>/dev/null && ! sync; then
    rm -f "${tmp}"
    return 2
  fi
  if ! mv -f -- "${tmp}" "${target}"; then
    rm -f "${tmp}"
    return 2
  fi
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

  config_write "$2" "$3" in-place
  rc="$?"
  if [[ "${rc}" != "2" ]]; then
    config_sum "$2" >"$(config_sum_path "$1")" 2>/dev/null || true
  fi
  return "${rc}"
}

# Runs "$@" holding the layer lock: API calls run in parallel, one process per
# connection, and each of these is a read-modify-write of the local layer.
# A lock that cannot be taken is a failure (2), not "unchanged" (1).
with_layer_lock() {
  if ! : 2>/dev/null >>"${LAYER_LOCK}"; then
    echo "Error: cannot open the layer lock ${LAYER_LOCK}" >&2
    return 2
  fi
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
# by someone who does not know the layers (config_is_foreign) and says
# something else than its layers: its remote layer is out of date then, and
# building from it would throw away what was written. A file that was only
# reformatted is not taken over. Keys already local stay local, with the values
# found. $1 is the effective configuration of this slot.
config_migrate_if_needed() {
  local effective_path="${1:-"${CONFIG_PATH}"}"
  local slot remote_path local_path layers local_layer remote effective

  slot="$(config_active_slot)"
  remote_path="$(config_remote_path "${slot}")"
  local_path="$(config_local_path "${slot}")"
  [[ -f "${effective_path}" ]] || return 0
  local_layer="$(config_read "${local_path}")" || return 2
  if [[ -f "${remote_path}" ]]; then
    config_is_foreign "${slot}" "${effective_path}" || return 0
    # A file that is no configuration at all is not taken over: the layers are
    # there, and the rebuild writes it again from them.
    effective="$(config_read "${effective_path}" 2>/dev/null)" || return 0
    remote="$(config_read "${remote_path}")" || return 2
    if jq -en --argjson a "${effective}" --argjson b "$(config_effective "${remote}" "${local_layer}")" \
        '$a == $b' >/dev/null; then
      config_sum "${effective_path}" >"$(config_sum_path "${slot}")" 2>/dev/null || true
      return 0
    fi
    echo "Info: ${effective_path} was written without the layers; taking it over" >&2
  else
    effective="$(config_read "${effective_path}")" || return 2
  fi

  layers="$(config_migrate "${effective}" "${local_layer}")" || return 2

  config_write "${local_path}" "$(jq -c .local <<<"${layers}")"
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
  local slot remote local_layer

  slot="$(config_active_slot)"
  remote="$(config_read "$(config_remote_path "${slot}")")" || return 2
  local_layer="$(config_read "$(config_local_path "${slot}")")" || return 2
  config_write_effective "${slot}" "${CONFIG_PATH}" \
    "$(config_effective "${remote}" "${local_layer}")"
}

# File. $1 is a jq filter applied to the local layer, with $remote bound to
# this slot's remote layer and any further arguments passed on to jq. The
# result is normalised and written, and the effective configuration rebuilt.
# A /system.json written by hand or by an Init App's own code since is taken
# over first, or the rebuild would throw it away. Returns config_rebuild's
# codes.
config_local_update() {
  with_layer_lock _config_local_update "$@"
}
_config_local_update() {
  local filter="$1"
  local slot local_path remote current new_local

  config_migrate_if_needed "${CONFIG_PATH}" || return 2

  slot="$(config_active_slot)"
  local_path="$(config_local_path "${slot}")"
  remote="$(config_read "$(config_remote_path "${slot}")")" || return 2
  current="$(config_read "${local_path}")" || return 2
  new_local="$(layers_jq -c --argjson remote "${remote}" "${@:2}" \
    "${filter} | normalise(\$remote)" <<<"${current}")" || return 2

  config_write "${local_path}" "${new_local}"
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
  config_local_update 'edit($orig; $edited)' --argjson orig "$1" --argjson edited "$2"
}

# File. Empties the local layer.
config_local_reset() {
  config_local_update '{}'
}

# File. $1 the plan of config_plan_update, $2 the slot it is for, $3 the path
# of that slot's effective configuration. Writes the slot's remote layer, its
# local layer - the running slot's, with what the plan withdraws - and its
# effective configuration, in that order. For the other slot, the running
# slot's layers stay as they are: if the new slot fails and the system rolls
# back, it finds them unchanged.
#
# Both are read now, not when the plan was made: an update runs for a while. A
# console change made meanwhile is kept, and a config-only update that landed
# meanwhile is not undone - the plan is made again from the remote layer it
# left.
#
# The effective file comes last. Should it fail after the layers were written,
# the boot rebuild of the slot (init.sh) writes it from them.
# Returns config_write's codes for the effective configuration.
config_commit() {
  with_layer_lock _config_commit "$@"
}
_config_commit() {
  local plan="$1"
  local slot="$2"
  local effective_path="$3"
  local active remote changed current new_local base

  config_migrate_if_needed "${CONFIG_PATH}" || return 2

  active="$(config_active_slot)"
  base="$(config_read "$(config_remote_path "${active}")")" || return 2
  if jq -e --argjson base "${base}" 'has("base") and .base != $base' <<<"${plan}" >/dev/null; then
    plan="$(config_plan_update "${base}" "$(jq -c .config <<<"${plan}")" \
      "$(jq -c .replace <<<"${plan}")")" || return 2
  fi

  remote="$(jq -c .remote <<<"${plan}")" || return 2
  changed="$(jq -c .changed <<<"${plan}")" || return 2
  current="$(config_read "$(config_local_path "${active}")")" || return 2
  new_local="$(config_withdraw "${current}" "${changed}" "${remote}")" || return 2

  config_write "$(config_remote_path "${slot}")" "${remote}"
  [[ "$?" == "2" ]] && return 2
  config_write "$(config_local_path "${slot}")" "${new_local}"
  [[ "$?" == "2" ]] && return 2
  config_write_effective "${slot}" "${effective_path}" \
    "$(config_effective "${remote}" "${new_local}")"
}
