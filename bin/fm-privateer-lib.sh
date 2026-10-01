#!/usr/bin/env bash
# fm-privateer-lib.sh - the session gate of a sealed Privateer home: the one
# owner of "is this process inside the home's Privateer session".
#
# docs/configuration.md ("Privateer quarantine") owns the operator contract,
# including which scripts call the gate and which captain-side commands stay
# usable outside the session. bin/fm-privateer.sh owns the session itself; this
# library owns its tmux socket name, the inside-session predicate, and the
# refusal every gated script prints.
#
# A home is a Privateer home while its config/privateer exists, as a file or a
# symlink. Its session runs on a dedicated tmux server whose socket name is
# fm-privateer-<the first 12 hex digits of the SHA-256 of the home's physical
# path>. A process is inside that session when the socket path its TMUX
# variable names ends in that name; tmux sets TMUX in every pane, and the first
# mate, every command it runs, and every worker it spawns inherit it.
#
# The gate is mistake-proofing, not a security boundary: TMUX is an ordinary
# environment variable, and tmux lets any same-user process drive the socket.
# It stops a session outside the quarantine that did not mean to act on the
# home, and its refusal names only the captain's next step, never a socket,
# port, or path an outside caller could drive.
#
# fm_privateer_refuse_outside exits FM_PRIVATEER_SEALED_EXIT (2), the code the
# gated scripts already use for a call they cannot act on, so no caller reads
# the refusal as a negative answer (bin/fm-captain-hold.sh open reads 2 as
# "cannot tell").
#
# Sourced by bin/fm-privateer.sh and the gated scripts. No side effects on
# source. set -u / set -e safe.

FM_PRIVATEER_SEALED_EXIT=2
FM_PRIVATEER_SEALED_REFUSAL='this is a sealed Privateer home; attach with bin/fm-privateer.sh attach, and never drive its session from outside'

# fm_privateer_home <config-dir>: return 0 when <config-dir>/privateer exists.
fm_privateer_home() {
  [ -e "$1/privateer" ] || [ -L "$1/privateer" ]
}

# fm_privateer_first_mate <config-dir>: the first mate's <sailor>/<model>, the
# first field of the first non-blank line of <config-dir>/privateer once #
# comments are stripped, or empty (bin/fm-privateer.sh owns the format).
fm_privateer_first_mate() {
  [ -f "$1/privateer" ] || return 0
  sed -e 's/#.*//' "$1/privateer" 2>/dev/null | awk 'NF { print $1; exit }'
}

# fm_privateer_socket_name <home>: the tmux socket name of <home>'s session.
fm_privateer_socket_name() {
  local root hash
  root=$(cd "$1" 2>/dev/null && pwd -P) || root=$1
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | cut -c1-12)
  else
    hash=$(printf '%s' "$root" | sha256sum | cut -c1-12)
  fi
  printf 'fm-privateer-%s\n' "$hash"
}

# fm_privateer_inside_session <home>: return 0 when this process runs inside
# <home>'s Privateer session.
fm_privateer_inside_session() {
  local socket=${TMUX:-}
  socket=${socket%%,*}
  [ -n "$socket" ] || return 1
  [ "${socket##*/}" = "$(fm_privateer_socket_name "$1")" ]
}

# fm_privateer_refuse_outside <home> <config-dir>: in a Privateer home, exit
# FM_PRIVATEER_SEALED_EXIT with the refusal on stderr unless this process runs
# inside the home's session. Call before anything is read or written; returns
# 0 in every other home and inside the session.
fm_privateer_refuse_outside() {
  fm_privateer_home "$2" || return 0
  fm_privateer_inside_session "$1" && return 0
  echo "error: ${0##*/} refused: $FM_PRIVATEER_SEALED_REFUSAL" >&2
  exit "$FM_PRIVATEER_SEALED_EXIT"
}
