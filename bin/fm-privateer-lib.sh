#!/usr/bin/env bash
# fm-privateer-lib.sh - the session gate of a sealed Privateer home: the one
# owner of "is this process inside the home's Privateer session".
#
# docs/configuration.md ("Privateer quarantine") owns the operator contract,
# including which scripts call the gate and which captain-side commands stay
# usable outside the session. bin/fm-privateer.sh owns the session itself; this
# library owns its tmux socket name, the inside-session predicate, the refusal
# every gated script prints, and when a script inside the session hands a task
# record write to the session's record writer (bin/fm-privateer-records.py).
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
# Sourced by bin/fm-privateer.sh, the gated scripts, and
# bin/fm-backlog-transition-lib.sh. No side effects on source. set -u / set -e
# safe.

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

# FM_PRIVATEER_SESSION: the tmux session name inside a Privateer home's server.
FM_PRIVATEER_SESSION=privateer

# fm_privateer_socket_path <socket-name>: the filesystem path of that socket.
fm_privateer_socket_path() {
  printf '%s/tmux-%s/%s\n' "${TMUX_TMPDIR:-/tmp}" "$(id -u)" "$1"
}

# fm_privateer_records_socket <home>: the socket of <home>'s record writer
# (bin/fm-privateer-records.py), fm-records-<the same 12 hex digits> beside the
# session's tmux socket, a path short enough for a Unix socket wherever the
# home lives. The session sandbox denies every write to it.
fm_privateer_records_socket() {
  local name
  name=$(fm_privateer_socket_name "$1")
  fm_privateer_socket_path "fm-records-${name#fm-privateer-}"
}

# fm_privateer_records_route <home> <config-dir>: return 0 when this process
# must hand <home>'s task-record writes to its record writer: a Privateer home,
# called inside its session, while the writer's socket exists. Anywhere else a
# record is written directly, so a home without the writer is unchanged.
fm_privateer_records_route() {
  fm_privateer_home "$2" || return 1
  fm_privateer_inside_session "$1" || return 1
  [ -S "$(fm_privateer_records_socket "$1")" ]
}

# fm_privateer_records_request <home> <op> [<id> [<mode>]]: one request to
# <home>'s record writer (ping, or publish, append, or remove of <id>, with the
# content on stdin, and a publish's octal file mode); exits as
# bin/fm-privateer-records.py request does, the refusal on stderr.
fm_privateer_records_request() {
  local home=$1 dir
  shift
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 3
  python3 -I "$dir/fm-privateer-records.py" request "$(fm_privateer_records_socket "$home")" "$@"
}

# fm_privateer_session_running <socket-name>: return 0 when that socket's server
# holds the Privateer session. It only queries the server: it never attaches,
# sends keys, or captures panes.
fm_privateer_session_running() {
  tmux -L "$1" has-session -t "$FM_PRIVATEER_SESSION" 2>/dev/null
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

# fm_privateer_active_project <config-dir> <data-dir> <projects-dir> <bin-dir>:
# the home's active project, from <config-dir>/active-project. Exit 0 with the
# name on stdout when the file holds one registered project name that has a
# clone; exit 2, silently, when the file is absent; exit 1 with one line on
# stdout saying what is wrong with it otherwise (several lines, a path or odd
# characters, an unregistered name, or no clone under <projects-dir>).
fm_privateer_active_project() {
  local file="$1/active-project" lines name
  [ -e "$file" ] || [ -L "$file" ] || return 2
  if [ ! -f "$file" ]; then
    echo "config/active-project is not a file"
    return 1
  fi
  lines=$(awk 'NF { n++ } END { print n + 0 }' "$file" 2>/dev/null)
  if [ "$lines" -ne 1 ]; then
    echo "config/active-project must hold one project name on one line, not ${lines} lines"
    return 1
  fi
  name=$(awk 'NF { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }' "$file")
  case "$name" in
    *[!A-Za-z0-9._-]* | .* | -*)
      echo "config/active-project holds '$name', which is not a project name"
      return 1
      ;;
  esac
  if ! FM_DATA_OVERRIDE="$2" "$4/fm-project-mode.sh" --registered "$name" 2>/dev/null; then
    echo "config/active-project names '$name', which data/projects.md does not register"
    return 1
  fi
  if [ ! -d "$3/$name" ]; then
    echo "config/active-project names '$name', which has no clone under projects/"
    return 1
  fi
  printf '%s\n' "$name"
}

# fm_privateer_projects_view <config-dir> <data-dir> <projects-dir> <bin-dir>:
# the registry as the captain reads it: every project data/projects.md
# registers that has a clone, one per line, the active one marked `*`, then a
# line saying which is active (or that none is, or why the value is unused).
fm_privateer_projects_view() {
  local name active reason rc=0 listed=0
  active=$(fm_privateer_active_project "$1" "$2" "$3" "$4") || rc=$?
  [ "$rc" -ne 1 ] || { reason=$active; active=''; }
  if [ -f "$2/projects.md" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] && [ -d "$3/$name" ] || continue
      listed=1
      if [ "$name" = "$active" ]; then printf '* %s\n' "$name"; else printf '  %s\n' "$name"; fi
    done <<EOF2
$(awk '/^- / { print $2 }' "$2/projects.md")
EOF2
  fi
  [ "$listed" -eq 1 ] || echo "no registered project has a clone under projects/"
  if [ -n "$active" ]; then
    echo "active project: $active"
  elif [ -n "${reason:-}" ]; then
    echo "active project: none - $reason"
  else
    echo "active project: none"
  fi
}
