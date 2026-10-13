#!/usr/bin/env bash
# fm-permission-grant.sh - the captain's widening or narrowing of an OpenCode
# worker's restricted permission profile, recorded with the captain's words.
#
# docs/configuration.md ("Permission grants") owns the operator contract. This
# header owns the record, the scopes, and the refusal list.
#
# Usage:
#   fm-permission-grant.sh grant --scope task|session|standing [--task <id>] \
#     --permission <name> [--pattern <pattern>] --action allow|deny \
#     [--words-file <path>] --channel chat|pinnace [--ref <note-or-message-id>]
#   fm-permission-grant.sh revoke <grant-id> [--words-file <path>] \
#     --channel chat|pinnace [--ref <id>]
#   fm-permission-grant.sh list [--task <id>]
#   fm-permission-grant.sh active --task <id>
#
# grant appends one record to state/permission-grants.jsonl: a new grant id,
# the time, the scope, the OpenCode permission name and pattern (default "*"),
# allow or deny, the captain's exact words (non-empty, at most 8192 bytes),
# the channel they came through, and an optional reference. The words come
# from --words-file, which every home but a Privateer home requires.
# It changes nothing that is already running: the grant reaches a worker at its
# next launch, so apply it to a running worker with
# `bin/fm-control.sh <task> relaunch`, which keeps the task and its sailor.
#
# Scopes:
#   task      that task only (--task required), until its cleanup; the record
#             binds the task record's dispatched_at stamp, so a later task that
#             reuses the id never inherits it.
#   session   every OpenCode worker until this home's first mate session ends;
#             the record binds the session lock's holder (state/.lock), so the
#             next session starts without it.
#   standing  every OpenCode worker from now on, until revoked.
# revoke appends a revocation record for one grant id, with the captain's words.
#
# A deny is always accepted, because narrowing never needs more trust. An allow
# is refused for the classes the captain approves only one action at a time,
# in the moment, and that firstmate then performs itself rather than delegating:
# a blanket or top-level "*" allow; web fetch or search; paths outside a
# project that hold credentials, system or shell configuration, Git
# configuration, a command directory on PATH, a whole home or
# filesystem root, or this firstmate home; and shell patterns for privilege
# escalation, a leading environment assignment, a shell, interpreter, or
# command or package runner, Git global options or configuration, a wildcard
# that does not follow a literal program and subcommand (bash_shape_reason),
# pushing with force, deletion, or a wildcard; branch, tag, or
# history deletion; merging; recursive or out-of-copy deletion; credential or
# keychain access; system configuration; network tools; global installs or
# running downloaded code; fleet, permission, or sandbox control; and anything
# that names Anthropic or Claude.
#
# active prints the task's grants that are in force as one compact JSON array
# of permission layers, oldest first, for bin/fm-opencode-permissions.sh to
# fold in after its baseline; list prints them for people. A revoked grant, a
# task grant for another dispatch, and a session grant from an earlier session
# are never in force.
#
# In a Privateer home (bin/fm-privateer-lib.sh) only the captain records a
# grant or revocation, from their own shell outside the home's session, whose
# sandbox denies the ledger to the first mate and every worker alike. Inside
# the session grant and revoke refuse before reading anything, naming the same
# call, less any --words-file, as a command the captain can run; list and
# active run on both sides. Any worker can write anywhere in the home, so
# there the captain's words never come from a file in it: with no
# --words-file, grant and revoke read them on stdin once every other check has
# passed, after showing on a terminal what the record holds; a --words-file
# whose real path is in the home is refused, naming that stdin command.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE resolve the
# home exactly as the other bin/ scripts do.
#
# Exit status: 0 success, 1 refused (a grant from the refusal list, an unknown
# grant id, or a scope that cannot bind), 2 usage or configuration error,
# including a Privateer home's words file in the home, or a grant or revoke
# called from inside a Privateer home's session.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-privateer-lib.sh
. "$SCRIPT_DIR/fm-privateer-lib.sh"
LOG="$STATE/permission-grants.jsonl"
LOCK_FILE="$STATE/.lock"
WORDS_MAX=8192
CAPTAIN_CALL=''
WORDS_JQ=()

usage() {
  sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() {
  echo "fm-permission-grant: $*" >&2
  exit 2
}

refuse() {
  echo "refused: $*"
  exit 1
}

# shell_word <text>: <text> as one shell word, quoted only when it needs it.
shell_word() {
  case "$1" in
    '' | *[!A-Za-z0-9_./:@%+,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# captain_call <verb> [args...]: the call as the command the captain runs from
# their own shell, less any --words-file, so it takes their words on stdin.
captain_call() {
  local call
  call="FM_HOME=$(shell_word "$FM_HOME") $(shell_word "$SCRIPT_DIR/fm-permission-grant.sh") $(shell_word "$1")"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --words-file) shift 2 || shift ;;
      --*) call="$call $(shell_word "$1")${2+ $(shell_word "$2")}"; shift 2 || shift ;;
      *) call="$call $(shell_word "$1")"; shift ;;
    esac
  done
  printf '%s\n' "$call"
}

# captain_side_only: inside a Privateer home's session, refuse with
# CAPTAIN_CALL as the command the captain runs from their own shell.
captain_side_only() {
  fm_privateer_home "$CONFIG" || return 0
  fm_privateer_inside_session "$FM_HOME" || return 0
  echo "error: fm-permission-grant.sh refused: in a Privateer home only the captain records a grant or revocation, from their own shell outside this session, typing their own words when it asks; ask the captain to run it there, then relaunch the worker once the captain says it is recorded: $CAPTAIN_CALL" >&2
  exit "$FM_PRIVATEER_SEALED_EXIT"
}

task_ok() {
  case "$1" in '' | .* | *[!A-Za-z0-9._-]*) return 1 ;; esac
}

meta_get() {  # <task> <key>
  sed -n "s/^$2=//p" "$STATE/$1.meta" 2>/dev/null | tail -1
}

# session_stamp: the live first mate session, as the lock holder's pid and the
# lock file's modification time; empty when no session holds the lock.
session_stamp() {
  local pid mtime
  [ -f "$LOCK_FILE" ] || return 0
  pid=$(head -1 "$LOCK_FILE" 2>/dev/null)
  case "$pid" in '' | *[!0-9]*) return 0 ;; esac
  kill -0 "$pid" 2>/dev/null || return 0
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
    mtime=$(/usr/bin/stat -f %m "$LOCK_FILE" 2>/dev/null) || return 0
  else
    mtime=$(stat -c %Y "$LOCK_FILE" 2>/dev/null) || return 0
  fi
  printf '%s@%s\n' "$pid" "$mtime"
}

# read_words <path-or-empty>: check --words-file. In a Privateer home, with
# none take_words reads the words on stdin, and a file whose real path is in
# the home is refused, since any worker can rewrite it.
read_words() {
  local size status
  if fm_privateer_home "$CONFIG"; then
    [ -n "$1" ] || return 0
    perl -MCwd=realpath -e '
      my @h = stat($ARGV[1]) or exit 2;
      my $p = realpath($ARGV[0]); defined($p) or exit 1;
      while (1) {
        my @s = stat($p);
        exit 3 if @s && $s[0] == $h[0] && $s[1] == $h[1];
        last if $p eq "/";
        $p =~ s{/[^/]*$}{};
        $p = "/" if $p eq "";
      }' "$1" "$FM_HOME" 2>/dev/null
    status=$?
    case "$status" in
      0) ;;
      2) die "cannot resolve $FM_HOME" ;;
      3) die "--words-file is in this Privateer home, where any worker can rewrite it; run the command without it and type the captain's words on stdin: $CAPTAIN_CALL" ;;
      *) die "--words-file must be a readable file" ;;
    esac
  fi
  [ -f "$1" ] && [ -r "$1" ] || die "--words-file must be a readable file"
  size=$(wc -c <"$1" | tr -d ' ')
  [ "$size" -gt 0 ] || die "--words-file is empty; record the captain's actual words"
  [ "$size" -le "$WORDS_MAX" ] || die "--words-file is larger than $WORDS_MAX bytes"
  [ -n "$(tr -d '[:space:]' <"$1")" ] || die "--words-file holds only whitespace; record the captain's actual words"
}

# take_words <path-or-empty> <record>: set WORDS_JQ to the jq arguments
# carrying the captain's words: the --words-file read_words checked, or the
# words on stdin, read after showing <record> when stdin is a terminal.
take_words() {
  local text
  if [ -n "$1" ]; then
    WORDS_JQ=(--rawfile words "$1")
    return 0
  fi
  if [ -t 0 ]; then
    {
      printf 'This records: %s\n' "$2"
      printf 'Type your own words for the record, then press Ctrl-D on a new line:\n'
    } >&2
  fi
  text=$(head -c "$((WORDS_MAX + 1))"; printf x)
  text=${text%x}
  [ -n "${text//[[:space:]]/}" ] || die "no words on stdin; record the captain's actual words"
  [ "${#text}" -le "$WORDS_MAX" ] || die "the words on stdin are larger than $WORDS_MAX bytes"
  WORDS_JQ=(--arg words "$text")
}

# bash_shape_reason <lowercased pattern>: why a shell allow's shape can run
# commands it does not name, or nothing when it cannot. A pattern with a
# wildcard (`*` or `?`) is accepted only when it spells `git`, one of its
# read-only or local-commit subcommands, and a space before the wildcard; any
# other allow is one exact command.
bash_shape_reason() {
  local pat=$1 prefix head sub runner first
  local -a w=() pw=()
  set -f
  read -r -a w <<<"$pat"
  set +f
  head=${w[0]:-}
  sub=${w[1]:-}
  case "$head" in
    *=*) echo "an environment assignment before the command can change what it runs"; return ;;
  esac
  case "${head##*/}" in
    sh | bash | zsh | dash | ksh | fish | csh | tcsh | python | python[0-9]* | node | deno | bun | bunx | perl | ruby | php | lua | osascript | awk | gawk | \
      env | xargs | find | make | gmake | command | exec | eval | source | . | nohup | nice | timeout | time | watch | caffeinate | script | arch | stdbuf | \
      npx | uvx | pipx)
      echo "a shell, interpreter, or command runner runs any command it is given"; return ;;
  esac
  for runner in "npm exec" "npm x" "pnpm exec" "pnpm dlx" "yarn dlx" "yarn exec"; do
    [ "${head##*/} $sub" != "$runner" ] || { echo "a package runner runs any command it is given"; return; }
  done
  if [ "${head##*/}" = git ]; then
    case "$sub" in
      -*) echo "a Git global option can change what any Git command runs"; return ;;
      config) echo "Git configuration can make any later Git command run arbitrary code"; return ;;
    esac
  fi
  case "$pat" in *[*?]*) ;; *) return ;; esac
  prefix=${pat%%[*?]*}
  set -f
  read -r -a pw <<<"$prefix"
  set +f
  case "$prefix" in
    *[[:space:]]) ;;
    *) pw=() ;;
  esac
  first=${pw[0]:-}
  case "$first ${pw[1]:-}" in
    git\ log | git\ diff | git\ show | git\ status | git\ add | git\ commit | git\ rev-parse | git\ blame | git\ ls-files | git\ shortlog | git\ describe) ;;
    *) echo "a wildcard allow is granted only over git log, diff, show, status, add, commit, rev-parse, blame, ls-files, shortlog, or describe; grant one exact command otherwise"; return ;;
  esac
}

# refusal_reason <permission> <pattern>: why an allow can never be pre-granted,
# or nothing when it can.
refusal_reason() {
  local perm=$1 pat=$2 lower home_re reason
  lower=$(printf '%s' "$pat" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *anthropic* | *claude*) echo "nothing that names Anthropic or Claude may be granted"; return ;;
  esac
  case "$perm" in
    '*') echo "a blanket allow for every permission is never granted"; return ;;
    webfetch | websearch) echo "web access reaches arbitrary hosts"; return ;;
    external_directory)
      home_re=$(printf '%s' "$HOME" | sed 's/[][\.^$*+?(){}|]/\\&/g')
      if printf '%s\n' "$pat" | sed "s|^~|$HOME|" | grep -Eq "^(\\*|/|/\\*|$home_re/?\\*?|$home_re/[^/]*\\*.*|/Users/?\\*?|/private/?\\*?)\$"; then
        echo "a whole filesystem root or home directory is never granted"; return
      fi
      if printf '%s\n' "$pat" | sed "s|^~|$HOME|" | grep -Eq "^($home_re/(\\.ssh|\\.aws|\\.gnupg|\\.config|\\.netrc|\\.no-mistakes|\\.claude|Library|\\.zsh[^/]*|\\.bash[^/]*|\\.profile|\\.zprofile|\\.zlogin|\\.zlogout|\\.inputrc|\\.gitconfig|\\.git-credentials|\\.local/bin|bin)|/etc|/private/etc|/System|/Library|/usr|/bin|/sbin|/opt/homebrew|/opt/local)(/|\$|\\*)"; then
        echo "credential, system, or shell configuration paths are never granted"; return
      fi
      case "$pat" in
        "$FM_HOME" | "$FM_HOME"/*) echo "a firstmate home's own files are never granted"; return ;;
      esac
      return
      ;;
    bash) ;;
    *) return ;;
  esac
  [ "$pat" != '*' ] || { echo "a blanket shell allow is never granted"; return; }
  reason=$(bash_shape_reason "$lower")
  [ -z "$reason" ] || { echo "$reason"; return; }
  if printf '%s\n' "$lower" | grep -Eq '(^|[;&|( ])(sudo|su|doas)( |$)'; then echo "privilege escalation is never granted"; return; fi
  if printf '%s\n' "$lower" | grep -Eq 'git +push'; then
    if printf '%s\n' "$lower" | grep -Eq -- '--force|(^| )-f( |$)|--mirror|--delete|(^| )-d( |$)|(^| )\+|\*'; then
      echo "a push that can force, delete, or match by wildcard is never granted; grant one exact push command"; return
    fi
  fi
  if printf '%s\n' "$lower" | grep -Eq 'git +(branch +(-d|-D|--delete)|tag +(-d|--delete)|filter-branch|filter-repo|reflog +expire|update-ref +-d)'; then echo "branch, tag, or history deletion is never granted"; return; fi
  if printf '%s\n' "$lower" | grep -Eq '(pr|pulls|mr) +merge|fm-pr-merge|fm-merge-local'; then echo "merging is never granted"; return; fi
  if printf '%s\n' "$lower" | grep -Eq '(^|[;&| ])rm( |$)'; then
    if printf '%s\n' "$pat" | grep -Eq '\*|(^| )/|~|\.\.|(^| )-[a-zA-Z]*[rR]'; then echo "recursive, wildcard, or out-of-copy deletion is never granted"; return; fi
  fi
  if printf '%s\n' "$lower" | grep -Eq '(^|[;&| ])(security|ssh|scp|sftp|gpg|op)( |$)|gh +auth|git +credential|\.ssh|\.aws|\.netrc|keychain'; then echo "credential or keychain access is never granted"; return; fi
  if printf '%s\n' "$lower" | grep -Eq '(^|[;&| ])(launchctl|pfctl|networksetup|scutil|systemsetup|csrutil|nvram|crontab|chown)( |$)|defaults +write'; then echo "system configuration is never granted"; return; fi
  if printf '%s\n' "$lower" | grep -Eq '(^|[;&| ])(curl|wget|nc|ncat|telnet|ftp|rsync|http|xh)( |$)'; then echo "network tools reach arbitrary hosts"; return; fi
  if printf '%s\n' "$lower" | grep -Eq '(npm|pnpm) +(install|i|in|ins|inst|insta|instal|isnt|isnta|isntal|isntall|add) +(.* )?(-g|--global)|yarn +global|(^|[;&| ])(brew|pipx|npx|bunx|uvx)( |$)|pnpm +dlx|(cargo|go|gem) +install'; then echo "global installs and downloaded code are never granted"; return; fi
  if printf '%s\n' "$lower" | grep -Eq 'tmux|herdr|fm-send|fm-spawn|fm-control|fm-teardown|fm-permission-grant|opencode-permission|sailor-sandbox|sandbox-exec|opencode_config|opencode\.json|\.opencode/'; then echo "fleet, permission, or sandbox control is never granted"; return; fi
  case "$pat" in
    *"$FM_HOME"*) echo "a firstmate home's own files are never granted"; return ;;
  esac
}

append_record() {  # <json>
  mkdir -p "$STATE" || die "cannot create $STATE"
  printf '%s\n' "$1" >>"$LOG" || die "cannot append to $LOG"
}

cmd_grant() {
  local scope='' task='' perm='' pat='*' action='' words='' channel='' ref='' reason stamp='' session='' id now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --scope) scope=${2:-}; shift 2 || usage ;;
      --task) task=${2:-}; shift 2 || usage ;;
      --permission) perm=${2:-}; shift 2 || usage ;;
      --pattern) pat=${2:-}; shift 2 || usage ;;
      --action) action=${2:-}; shift 2 || usage ;;
      --words-file) words=${2:-}; shift 2 || usage ;;
      --channel) channel=${2:-}; shift 2 || usage ;;
      --ref) ref=${2:-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  case "$scope" in task | session | standing) ;; *) die "--scope must be task, session, or standing" ;; esac
  case "$action" in allow | deny) ;; *) die "--action must be allow or deny" ;; esac
  case "$channel" in chat | pinnace) ;; *) die "--channel must be chat or pinnace" ;; esac
  case "$perm" in '' | *[!a-z_*]*) die "--permission must be an OpenCode permission name such as bash, edit, or external_directory" ;; esac
  [ -n "$pat" ] || die "--pattern must not be empty"
  case "$pat" in *[[:cntrl:]]*) die "--pattern must be one line" ;; esac
  read_words "$words"
  if [ "$scope" = task ]; then
    task_ok "$task" || die "--scope task needs --task <id>"
    [ -f "$STATE/$task.meta" ] || refuse "task $task has no live record in this home"
    stamp=$(meta_get "$task" dispatched_at)
  else
    [ -z "$task" ] || die "--task applies only to --scope task"
  fi
  if [ "$scope" = session ]; then
    session=$(session_stamp)
    [ -n "$session" ] || refuse "no live first mate session holds this home's lock, so a session grant has nothing to end with"
  fi
  if [ "$action" = allow ]; then
    reason=$(refusal_reason "$perm" "$pat")
    [ -z "$reason" ] || refuse "$reason; the captain approves that one action in the moment and firstmate performs it"
  fi
  take_words "$words" "$action $perm \"$pat\" for $scope${task:+ $task}"
  now=$(date +%s)
  id="g$now-$$-$RANDOM"
  append_record "$(jq -cn --arg id "$id" --argjson ts "$now" --arg scope "$scope" --arg task "$task" \
    --arg stamp "$stamp" --arg session "$session" --arg perm "$perm" --arg pat "$pat" --arg action "$action" \
    "${WORDS_JQ[@]}" --arg channel "$channel" --arg ref "$ref" '
    {v: 1, op: "grant", id: $id, ts: $ts, scope: $scope,
     task: (if $task == "" then null else $task end),
     task_dispatched_at: (if $scope == "task" then $stamp else null end),
     session: (if $session == "" then null else $session end),
     permission: $perm, pattern: $pat, action: $action,
     words: $words, channel: $channel, ref: (if $ref == "" then null else $ref end)}')"
  echo "$id: $action $perm \"$pat\" for $scope${task:+ $task}; it applies at each OpenCode worker's next launch (bin/fm-control.sh <task> relaunch to apply now)"
}

cmd_revoke() {
  local id=${1:-} words='' channel='' ref=''
  [ -n "$id" ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --words-file) words=${2:-}; shift 2 || usage ;;
      --channel) channel=${2:-}; shift 2 || usage ;;
      --ref) ref=${2:-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  case "$channel" in chat | pinnace) ;; *) die "--channel must be chat or pinnace" ;; esac
  read_words "$words"
  if [ ! -f "$LOG" ] || ! jq -e --arg id "$id" 'select(.op == "grant" and .id == $id)' "$LOG" >/dev/null 2>&1; then
    refuse "no grant $id in this home"
  fi
  take_words "$words" "revoke grant $id"
  append_record "$(jq -cn --arg id "$id" --argjson ts "$(date +%s)" "${WORDS_JQ[@]}" --arg channel "$channel" --arg ref "$ref" '
    {v: 1, op: "revoke", id: $id, ts: $ts, words: $words, channel: $channel, ref: (if $ref == "" then null else $ref end)}')"
  echo "$id: revoked; it no longer applies from each OpenCode worker's next launch"
}

# in_force <task-or-empty>: the grant records in force, oldest first, as JSON lines.
in_force() {
  local task=$1 stamp='' session
  [ -f "$LOG" ] || return 0
  [ -z "$task" ] || stamp=$(meta_get "$task" dispatched_at)
  session=$(session_stamp)
  jq -c -s --arg task "$task" --arg stamp "$stamp" --arg session "$session" '
    (map(select(.op == "revoke") | .id)) as $revoked
    | map(select(.op == "grant" and ((.id as $i | $revoked | index($i)) == null)))
    | map(select(
        .scope == "standing"
        or (.scope == "session" and $session != "" and .session == $session)
        or (.scope == "task" and $task != "" and .task == $task and (.task_dispatched_at // "") == $stamp)))
    | sort_by(.ts) | .[]' "$LOG"
}

cmd_active() {
  if [ "${1:-}" != --task ] || ! task_ok "${2:-}"; then
    usage
  fi
  in_force "$2" | jq -cs 'map({(.permission): {(.pattern): .action}})'
}

cmd_list() {
  local task=''
  if [ "$#" -gt 0 ]; then
    if [ "$1" != --task ] || ! task_ok "${2:-}"; then
      usage
    fi
    task=$2
  fi
  in_force "$task" | jq -r '"\(.id) \(.scope)\(if .task then " " + .task else "" end) \(.action) \(.permission) \"\(.pattern)\" via \(.channel): \(.words | gsub("\n"; " ") | .[0:120])"'
}

command -v jq >/dev/null 2>&1 || die "jq is required"
[ "$#" -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  grant | revoke)
    CAPTAIN_CALL=$(captain_call "$cmd" "$@")
    captain_side_only
    if [ "$cmd" = grant ]; then cmd_grant "$@"; else cmd_revoke "$@"; fi
    ;;
  list) cmd_list "$@" ;;
  active) cmd_active "$@" ;;
  -h | --help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) usage ;;
esac
