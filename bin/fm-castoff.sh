#!/usr/bin/env bash
# fm-castoff.sh - the phone mirror: while it is on, each turn's final message
# from the first mate also reaches the pinnace chat, beside the replies to the
# captain's phone notes. Cast Off (/castoff) turns it on and Make Fast
# (/makefast) turns it off; the castoff skill owns the procedure and the
# extra-concise rule. This script is the one owner of the flag and its writer.
#
# FLAG. $STATE/.castoff, owner-only, published by rename: first line `on`, then
# `at=<epoch>` of the `on` that started it. Its presence is the whole state.
# `on` while on is a refresh that keeps at=; `off` removes the flag and the
# turn stamp below. The mirror is presentation only: it grants no authority,
# is not the away posture, and `/afk` never turns it on.
#
# WRITER. `hook claude|cursor` runs on the harness's prompt-submit and
# turn-end surfaces: Claude UserPromptSubmit and Stop (.claude/settings.json),
# Cursor beforeSubmitPrompt and afterAgentResponse (.cursor/hooks.json). Other
# harnesses have no writer. Gates, in order: the flag exists (checked before
# anything is sourced, so a home without it stays inert); the Claude
# registration stands down on a Cursor payload (bin/fm-hook-host-lib.sh); the
# payload is a prompt or a final message (bin/fm-turn-dialog-lib.sh owns the
# fields); the hook runs in a genuine primary checkout whose session holds the
# fleet lock, so a crewmate worktree and a read-only second session write
# nothing.
# A submitted prompt is never recorded; it only stamps the turn in
# $STATE/.castoff-turn (two lines, the id then the class; owner-only, by
# rename): class
# `operational` for fleet machinery (bin/fm-turn-dialog-lib.sh) or a
# record-backed operational doorbell whose record sits in this home
# (bin/fm-operational-input.sh), `captain` otherwise.
# A final message goes on stdin to `bin/fm-inbox.sh mate`, which owns the
# record, its cap, its order beside note replies, and its dedupe. Its class is
# the stamp recorded under the same id, else `captain`: the one mirrored turn
# with no stamp is the turn that turned the mirror on, whose prompt arrived
# before the flag. The turn that turns it off ends with the flag gone and is
# not mirrored.
#
# Usage:
#   fm-castoff.sh on
#   fm-castoff.sh off
#   fm-castoff.sh status
#   fm-castoff.sh hook <claude|cursor>      a hook payload on stdin
# on and off print what changed in plain words; status prints
# `on since <UTC>` and exits 0, or prints `off` and exits 1; hook always exits
# 0 and prints nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FLAG="$STATE/.castoff"
TURN="$STATE/.castoff-turn"

usage() {
  sed -n '/^# Usage:/,/^# on and off/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() { printf 'fm-castoff: %s\n' "$*" >&2; exit 1; }

# The epoch the flag was set, or nothing when it is absent or unreadable.
flag_at() {
  local line at=
  [ -f "$FLAG" ] || return 0
  while IFS= read -r line; do
    case "$line" in at=*) at=${line#at=} ;; esac
  done < "$FLAG"
  case "$at" in ''|*[!0-9]*) ;; *) printf '%s' "$at" ;; esac
}

utc() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$1"
}

# Publish <lines> at <path> as newline-terminated lines, owner-only, by rename.
publish() {  # <path> <lines>
  local tmp
  tmp=$(umask 077; mktemp "$1.tmp.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$2" > "$tmp" || ! mv -f "$tmp" "$1"; then
    rm -f "$tmp"
    return 1
  fi
}

cmd_on() {
  local at
  [ -d "$STATE" ] || die "no state directory at $STATE"
  at=$(flag_at)
  if [ -n "$at" ]; then
    printf 'The phone mirror was already on, since %s; nothing changed.\n' "$(utc "$at")"
    return 0
  fi
  publish "$FLAG" "$(printf 'on\nat=%s' "$(date +%s)")" || die "could not write $FLAG"
  printf 'The phone mirror is on: each reply the first mate finishes here also reaches the pinnace chat, kept extra concise, until Make Fast turns it off.\n'
  [ -f "$CONFIG/pinnace" ] \
    || printf 'No pinnace is configured for this home (config/pinnace), so nothing reads the mirror until one is.\n'
}

cmd_off() {
  if [ ! -e "$FLAG" ]; then
    rm -f "$TURN"
    printf 'The phone mirror was already off; nothing changed.\n'
    return 0
  fi
  rm -f "$FLAG" "$TURN" || die "could not remove $FLAG"
  printf 'The phone mirror is off: replies stay in the terminal.\n'
}

cmd_status() {
  local at
  if [ ! -f "$FLAG" ]; then
    printf 'off\n'
    return 1
  fi
  at=$(flag_at)
  printf 'on since %s\n' "$(if [ -n "$at" ]; then utc "$at"; else printf unknown; fi)"
}

# The class a prompt stamps on its turn.
prompt_class() {  # <text>
  local kind
  if fm_turn_dialog_prompt_is_machinery "$1"; then
    printf 'operational'
    return 0
  fi
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"
  if fm_operational_doorbell_kind "$1" "$STATE" kind; then
    printf 'operational'
  else
    printf 'captain'
  fi
}

# The class stamped for turn <id>, else captain.
turn_class() {  # <id>
  local id='' class=''
  if [ -f "$TURN" ]; then
    { IFS= read -r id; IFS= read -r class; } < "$TURN" 2>/dev/null || true
    if [ "$id" = "$1" ]; then
      case "$class" in captain|operational) printf '%s' "$class"; return 0 ;; esac
    fi
  fi
  printf 'captain'
}

cmd_hook() {
  local payload parsed tag id text class
  command -v jq >/dev/null 2>&1 || return 0
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || return 0
  if [ "$1" = claude ]; then
    # shellcheck source=bin/fm-hook-host-lib.sh
    . "$SCRIPT_DIR/fm-hook-host-lib.sh"
    # Cursor loads the tracked Claude settings too; its own entries cover it.
    ! fm_hook_payload_is_foreign_host "$payload" || return 0
  fi
  # shellcheck source=bin/fm-turn-dialog-lib.sh
  . "$SCRIPT_DIR/fm-turn-dialog-lib.sh"
  parsed=$(printf '%s' "$payload" | fm_turn_dialog_parse) || return 0
  [ -n "$parsed" ] || return 0
  tag=$(printf '%s\n' "$parsed" | sed -n '1p')
  id=$(printf '%s\n' "$parsed" | sed -n '2p')
  text=$(printf '%s\n' "$parsed" | sed '1,2d')
  fm_turn_dialog_writer_in_scope "$FM_ROOT" "$STATE" || return 0
  if [ "$tag" = captain ]; then
    publish "$TURN" "$(printf '%s\n%s' "$id" "$(prompt_class "$text")")" || true
    return 0
  fi
  class=$(turn_class "$id")
  # An id the record would refuse (fm-inbox.sh's request-id rule) must not
  # cost the message itself: it is recorded without one.
  case "$id" in .*|*[!A-Za-z0-9._:-]*) id= ;; esac
  [ "${#id}" -le 128 ] || id=
  set -- --turn "$class"
  [ -z "$id" ] || set -- --id "$id" "$@"
  printf '%s' "$text" | FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-inbox.sh" mate "$@" - >/dev/null 2>&1 || true
}

case "${1:-}" in
  on) [ "$#" -eq 1 ] || usage; cmd_on ;;
  off) [ "$#" -eq 1 ] || usage; cmd_off ;;
  status) [ "$#" -eq 1 ] || usage; cmd_status ;;
  hook)
    # The flag gate runs before anything is read or sourced, so a home without
    # it, and a crewmate worktree with no state/, stay inert and silent.
    [ -f "$FLAG" ] || exit 0
    case "${2:-}" in claude|cursor) ;; *) exit 0 ;; esac
    [ "$#" -eq 2 ] || exit 0
    cmd_hook "$2"
    exit 0
    ;;
  -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac
