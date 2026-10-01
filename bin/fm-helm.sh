#!/usr/bin/env bash
# fm-helm.sh - the Privateer first mate's front door: one verb per job, each
# composed from this home's own scripts with the Privateer defaults, so the
# first mate never composes their flags.
#
# docs/configuration.md ("The front door") owns the operator contract. This
# header owns what each verb runs, the sailor choice, and the slash-command
# argument form. Every script a verb runs keeps its own checks, and its
# refusal reaches the caller unchanged.
#
# Usage:
#   fm-helm.sh helm
#   fm-helm.sh scout [--rule <n>|default] <project> <ask...>
#   fm-helm.sh ship [--rule <n>|default] <project> <ask...>
#   fm-helm.sh queue
#   fm-helm.sh sailors
#   fm-helm.sh steer <task-id> <text...>
#   fm-helm.sh land <task-id>
#   fm-helm.sh wake
#   fm-helm.sh <verb> --stdin
#
# helm runs bin/fm-session-start.sh, the session start, and then names the
# front door's slash commands.
#
# scout and ship start new work on a project that data/projects.md registers
# and that has a clone under projects/:
#   1. choose the candidate sailors (below), before anything is written;
#   2. file the backlog row with bin/fm-tasks-axi.sh add --mint, titled with
#      the ask's first line, with --kind scout|ship and --repo <project>;
#   3. write the instructions with bin/fm-brief.sh <id> <project> --scout, or
#      --mode local-only --branch-prefix <the project's registered prefix> for
#      a ship, then fill `## Captain's intent` with the ask exactly as given
#      and `## Firstmate spec` with one fixed line that keeps the work to it;
#   4. take the first candidate that bin/fm-sailor.sh check passes;
#   5. spawn with bin/fm-spawn.sh <id> <project> --scout, or --mode local-only
#      --yolo <the project's registered yolo> --branch-prefix <prefix> for a
#      ship, plus --harness opencode --sailor <sailor> --model <model> and the
#      profile's --effort when it names one.
# When every candidate is refused, or the spawn refuses, the row stays Queued
# with its instructions written, and the output names the bin/fm-spawn.sh call
# of step 5 that starts it, with the candidate sailors in order when none
# answered. When the instructions cannot be written, the row just filed is
# removed.
#
# The candidate sailors are profiles of config/crew-dispatch.json, in the
# order listed: its default profiles when it declares no rules, the profiles
# of the rule that --rule <n> names (counting from 1), or the default profiles
# with --rule default. A rule's condition is natural language, which no script
# judges, so while the file declares rules a call without --rule is refused
# before anything is written, listing each rule's condition and the call to
# repeat with --rule.
#
# queue prints the backlog summary of bin/fm-tasks-axi.sh without its hints;
# sailors runs bin/fm-sailor.sh status --all; steer runs bin/fm-send.sh
# <task-id> <text>; land runs bin/fm-merge-local.sh <task-id>, which keeps its
# own authority checks, and names the cleanup that follows; wake runs
# bin/fm-wake-drain.sh.
#
# --stdin reads the verb's arguments as text on standard input instead, the
# form the slash commands in .opencode/commands/ use: after an optional
# leading --rule <n>, the first word is the project or task id, and the rest,
# newlines included, is the ask or the steer. Each slash command writes the
# captain's words inside a quoted here-document, so no quote, $, or ; in them
# reaches a shell, three times: OpenCode's $ARGUMENTS, the line FM_HELM_AGAIN,
# $ARGUMENTS again, the line FM_HELM_TOKENS, OpenCode's $1, and the line
# FM_HELM_END_OF_ARGUMENTS. OpenCode fills $1 with the words' tokens as they
# are, but writes $ARGUMENTS with JavaScript's replaceAll, which reads $$, $&,
# $`, and $' in the words as its own patterns, and it ends the shell step at
# the first backtick. So the text is taken only when it has exactly that
# shape, its two $ARGUMENTS copies are identical, hold no literal $ARGUMENTS,
# and hold as many $ as the $1 copy; then the $ARGUMENTS copy is the
# arguments. Anything else is refused before anything is written: words
# holding a backtick or a $ followed by $, &, ', or a backtick never arrive
# unchanged.
#
# Every verb refuses (exit 2) in a home without config/privateer and, through
# bin/fm-privateer-lib.sh, from outside the home's Privateer session. Progress
# lines go to stdout; a refusal goes to stderr as `refused: <reason>`, which
# the seal plugin's refusal budget counts.
#
# Exit status: 0 done, including work left Queued; 1 refused; 2 usage, a home
# without the quarantine, or a caller outside the session. helm, queue,
# sailors, steer, land, and wake exit with the status of the script they run.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
DISPATCH="$CONFIG/crew-dispatch.json"
END_LINE=FM_HELM_END_OF_ARGUMENTS
AGAIN_LINE=FM_HELM_AGAIN
TOKENS_LINE=FM_HELM_TOKENS
VERBS='helm, scout, ship, queue, sailors, steer, land, wake'
SCOUT_SPEC="Investigate exactly what the captain's intent above asks, on this project, and write the findings to the report this brief names; change no project code, and note anything beyond the ask in the report as follow-up."
SHIP_SPEC="Build exactly what the captain's intent above asks, on this project, with tests where the project has them; note anything beyond the ask in the done line as follow-up rather than adding it."

refuse() {
  echo "refused: $*" >&2
  exit 1
}

# misuse <reason>: a malformed call, answered with the accepted forms.
misuse() {
  {
    echo "refused: $*"
    echo "the calls: bin/fm-helm.sh helm | scout|ship [--rule <n>|default] <project> <ask...> | queue | sailors | steer <task-id> <text...> | land <task-id> | wake"
  } >&2
  exit 2
}

say() {
  printf '%s\n' "$*"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# trim <text>: <text> without leading or trailing whitespace.
trim() {
  local text=$1
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  printf '%s' "$text"
}

# read_stdin_args: ARGS from the text on standard input, as the header says.
read_stdin_args() {
  local text word again tokens markers nl=$'\n'
  local mangled="OpenCode changed or cut the words, which happens when they hold a backtick or a \$ followed by \$, &, ', or a backtick; give them again without those"
  text=$(cat)
  markers=$(printf '%s\n' "$text" | awk -v a="$AGAIN_LINE" -v t="$TOKENS_LINE" -v e="$END_LINE" '
    $0 == a || $0 == t || $0 == e { printf "%s ", $0 }')
  [ "$markers" = "$AGAIN_LINE $TOKENS_LINE $END_LINE " ] || refuse "$mangled"
  case "$text" in
    *"$nl$AGAIN_LINE$nl"*"$nl$TOKENS_LINE$nl"*"$nl$END_LINE") ;;
    *) refuse "$mangled" ;;
  esac
  again=${text#*"$nl$AGAIN_LINE$nl"}
  tokens=${again#*"$nl$TOKENS_LINE$nl"}
  tokens=${tokens%"$nl$END_LINE"}
  again=${again%%"$nl$TOKENS_LINE$nl"*}
  text=${text%%"$nl$AGAIN_LINE$nl"*}
  [ "$text" = "$again" ] || refuse "$mangled"
  case "$text" in
    *"\$ARGUMENTS"*) refuse "$mangled" ;;
  esac
  again=${text//[!\$]/}
  tokens=${tokens//[!\$]/}
  [ "${#again}" -eq "${#tokens}" ] || refuse "$mangled"
  ARGS=()
  text=$(trim "$text")
  while :; do
    case "$text" in
      --rule[[:space:]]*)
        text=$(trim "${text#--rule}")
        word=${text%%[[:space:]]*}
        ARGS+=(--rule "$word")
        text=$(trim "${text#"$word"}")
        ;;
      *) break ;;
    esac
  done
  [ -n "$text" ] || return 0
  word=${text%%[[:space:]]*}
  ARGS+=("$word")
  text=$(trim "${text#"$word"}")
  [ -z "$text" ] || ARGS+=("$text")
}

no_arguments() {  # <verb> <count>
  [ "$2" -eq 0 ] || misuse "$1 takes no arguments"
}

# check_project <project>: refuse unless <project> is registered with a clone.
check_project() {
  local known='' clone
  case "$1" in
    */* | .*) refuse "'$1' is a path; give the name of a project under projects/" ;;
  esac
  if ! "$SCRIPT_DIR/fm-project-mode.sh" --registered "$1" || [ ! -d "$PROJECTS/$1" ]; then
    for clone in "$PROJECTS"/*/; do
      [ -d "$clone" ] || continue
      clone=${clone%/}
      known="$known${known:+, }${clone##*/}"
    done
    refuse "'$1' is not a registered project with a clone under projects/; the projects here are: ${known:-none}; ask the captain which one"
  fi
}

# again <kind> <project> <ask>: the same call with --rule left to fill in.
again() {
  printf '%s\n' "bin/fm-helm.sh $1 --rule <n> $2 $(shell_quote "$3")"
}

# choose_candidates <kind> <project> <ask>: CANDIDATES, one `sailor<TAB>model<TAB>effort`
# line per profile, as the header's sailor choice says.
choose_candidates() {
  local rules selector
  command -v jq >/dev/null 2>&1 || refuse "jq is required to read config/crew-dispatch.json"
  [ -f "$DISPATCH" ] || refuse "config/crew-dispatch.json is absent, so no sailor is named; tell the captain"
  jq -e . "$DISPATCH" >/dev/null 2>&1 || refuse "config/crew-dispatch.json is not valid JSON; tell the captain"
  rules=$(jq '(.rules // []) | if type == "array" then length else 0 end' "$DISPATCH")
  if [ -z "$RULE" ]; then
    if [ "$rules" -gt 0 ]; then
      {
        echo "refused: this home's dispatch rules are chosen by judgment, not by this script; repeat the call with --rule <n> for the rule whose condition fits the work, or --rule default when none fits:"
        jq -r '
          def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
          def names($v): profiles($v) | map("\(.sailor // "?")/\(.model // "?")") | join(", ");
          ((.rules // []) | to_entries[] | "  --rule \(.key + 1): \(.value.when // "") (\(names(.value.use)))"),
          (if has("default") then "  --rule default (\(names(.default)))" else empty end)' "$DISPATCH"
        echo "the call: $(again "$@")"
      } >&2
      exit 1
    fi
    selector=.default
  elif [ "$RULE" = default ]; then
    selector=.default
  else
    [ "$RULE" -le "$rules" ] || refuse "there is no rule $RULE; config/crew-dispatch.json declares $rules"
    selector=".rules[$((RULE - 1))].use"
  fi
  CANDIDATES=$(jq -r "
    def profiles(\$v): if (\$v | type) == \"array\" then \$v elif (\$v | type) == \"object\" then [\$v] else [] end;
    profiles($selector)[] | select(type == \"object\" and (.sailor | type) == \"string\" and (.model | type) == \"string\")
    | [.sailor, .model, (.effort // \"\" | tostring)] | @tsv" "$DISPATCH")
  [ -n "$CANDIDATES" ] || refuse "the ${RULE:+rule }${RULE:-default} in config/crew-dispatch.json names no sailor; tell the captain"
}

# fill_brief <brief> <kind> <ask>: the two `# Task` subsections, filled literally.
fill_brief() {
  local brief=$1 spec=$SHIP_SPEC tmp="$1.fill.$$"
  [ "$2" = ship ] || spec=$SCOUT_SPEC
  if FM_HELM_INTENT=$3 FM_HELM_SPEC=$spec awk '
      !t && $0 == "{TASK}" { print ENVIRON["FM_HELM_INTENT"]; t = 1; next }
      !s && $0 == "{FIRSTMATE_SPEC}" { print ENVIRON["FM_HELM_SPEC"]; s = 1; next }
      { print }
      END { exit !(t && s) }
    ' "$brief" > "$tmp" && mv "$tmp" "$brief"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# title_of <ask>: the ask's first line, whitespace squeezed, at most 80 characters.
title_of() {
  local title=${1%%$'\n'*}
  title=$(trim "$(printf '%s' "$title" | tr -s '[:space:]' ' ')")
  title=${title#"${title%%[!- ]*}"}
  [ "${#title}" -le 80 ] || title="${title:0:77}..."
  printf '%s' "$title"
}

# ship_posture <project>: PREFIX and YOLO, the project's registered branch
# prefix and merge authority.
ship_posture() {
  local posture
  PREFIX=$("$SCRIPT_DIR/fm-project-mode.sh" --branch-prefix "$1" 2>/dev/null) ||
    refuse "the branch prefix of $1 cannot be read; run bin/fm-project-mode.sh --branch-prefix $1 to see why"
  posture=$("$SCRIPT_DIR/fm-project-mode.sh" "$1" 2>/dev/null) ||
    refuse "the registered posture of $1 cannot be read; run bin/fm-project-mode.sh $1 to see why"
  YOLO=${posture##* }
  case "$YOLO" in
    on | off) ;;
    *) refuse "the registered posture of $1 reads '$posture', not <mode> <on|off>" ;;
  esac
}

# launch <kind> <id> <project>: steps 4 and 5, with PREFIX and YOLO set for a
# ship; exits.
launch() {
  local kind=$1 id=$2 project=$3 sailor model effort out
  local -a refusals args profiles
  refusals=()
  profiles=()
  args=("$id" "$project")
  if [ "$kind" = ship ]; then
    args+=(--mode local-only --yolo "$YOLO" --branch-prefix "$PREFIX")
  else
    args+=(--scout)
  fi
  args+=(--harness opencode)
  while IFS=$'\t' read -r sailor model effort; do
    [ -n "$sailor" ] || continue
    profiles+=("$sailor/$model${effort:+ --effort $effort}")
    if out=$("$SCRIPT_DIR/fm-sailor.sh" check "$sailor" "$model" 2>&1); then
      say "sailor: $sailor/$model can take it"
      args+=(--sailor "$sailor" --model "$model")
      [ -z "$effort" ] || args+=(--effort "$effort")
      if out=$("$SCRIPT_DIR/fm-spawn.sh" "${args[@]}" 2>&1); then
        say "started: $id, a $kind on $project, on $sailor/$model"
        exit 0
      fi
      {
        echo "refused: the spawn refused, so $id stays Queued with its instructions written; fix what it names, then start it with: bin/fm-spawn.sh ${args[*]}"
        printf '%s\n' "$out" | sed 's/^/  /'
      } >&2
      exit 1
    fi
    refusals+=("$sailor/$model: ${out#refused: }")
  done <<EOF
$CANDIDATES
EOF
  say "queued: no sailor can take $id now, so it waits in the queue with its instructions written:"
  printf '  %s\n' "${refusals[@]+"${refusals[@]}"}"
  say "start it later with: bin/fm-spawn.sh ${args[*]} --sailor <sailor> --model <model>"
  say "for the first of these that answers: $(printf '%s, ' "${profiles[@]}" | sed 's/, $//')"
  exit 0
}

# intake <kind> [--rule <n>|default] <project> <ask...>
intake() {
  local kind=$1 ask out rc id title brief project
  shift
  RULE=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --rule)
        [ "$#" -ge 2 ] || misuse "--rule needs a rule number or default"
        RULE=$2
        shift 2
        ;;
      --*) misuse "unknown flag '$1'; $kind takes only --rule <n>|default, before the project" ;;
      *) break ;;
    esac
  done
  case "$RULE" in
    '' | default) ;;
    0* | *[!0-9]*) misuse "--rule takes a rule number from 1, or default, not '$RULE'" ;;
  esac
  [ "$#" -ge 1 ] || misuse "$kind needs a project and the ask"
  project=$1
  shift
  ask=$(trim "$*")
  [ -n "$ask" ] || misuse "$kind needs a project and the ask"
  check_project "$project"
  choose_candidates "$kind" "$project" "$ask"
  [ "$kind" = scout ] || ship_posture "$project"
  title=$(title_of "$ask")
  [ -n "$title" ] || title="$kind $project"
  out=$("$SCRIPT_DIR/fm-tasks-axi.sh" add "$title" --mint --kind "$kind" --repo "$project" --json 2>&1) ||
    refuse "the backlog row could not be filed: $out"
  id=$(printf '%s' "$out" | jq -r '.task.id // empty' 2>/dev/null)
  [ -n "$id" ] || refuse "the backlog answered without a task id: $out"
  say "filed: $id - $title"
  brief="$DATA/$id/brief.md"
  rc=0
  if [ "$kind" = ship ]; then
    out=$("$SCRIPT_DIR/fm-brief.sh" "$id" "$project" --mode local-only --branch-prefix "$PREFIX" 2>&1) || rc=$?
  else
    out=$("$SCRIPT_DIR/fm-brief.sh" "$id" "$project" --scout 2>&1) || rc=$?
  fi
  if [ "$rc" -ne 0 ] || ! fill_brief "$brief" "$kind" "$ask"; then
    rm -f "$brief"
    rmdir "$DATA/$id" 2>/dev/null
    "$SCRIPT_DIR/fm-tasks-axi.sh" rm "$id" >/dev/null 2>&1 ||
      echo "refused: $id could not be removed from the backlog; remove it with bin/fm-tasks-axi.sh rm $id" >&2
    refuse "the instructions for $id could not be written, so its backlog row was removed: $out"
  fi
  say "instructions: data/$id/brief.md, with the ask as the captain's intent"
  launch "$kind" "$id" "$project"
}

case "${1:-}" in
  -h | --help)
    sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

# shellcheck source=bin/fm-privateer-lib.sh
. "$SCRIPT_DIR/fm-privateer-lib.sh"
if ! fm_privateer_home "$CONFIG"; then
  echo "refused: the front door serves only a Privateer home, and this home has no config/privateer" >&2
  exit 2
fi
fm_privateer_refuse_outside "$FM_HOME" "$CONFIG"

[ "$#" -ge 1 ] || misuse "no verb given; the verbs are $VERBS"
VERB=$1
shift
if [ "${1:-}" = --stdin ]; then
  [ "$#" -eq 1 ] || misuse "--stdin takes the arguments on standard input, and nothing else"
  read_stdin_args
  set -- ${ARGS[@]+"${ARGS[@]}"}
fi

case "$VERB" in
  helm)
    no_arguments helm "$#"
    "$SCRIPT_DIR/fm-session-start.sh"
    status=$?
    say "front door: /scout <project> <ask>, /ship <project> <ask>, /queue, /sailors, /steer <task-id> <text>, /land <task-id>, /wake"
    exit "$status"
    ;;
  scout | ship) intake "$VERB" "$@" ;;
  queue)
    no_arguments queue "$#"
    "$SCRIPT_DIR/fm-tasks-axi.sh" | awk '/^(bin|description): / { next } /^help\[/ { exit } { print }'
    exit "${PIPESTATUS[0]}"
    ;;
  sailors)
    no_arguments sailors "$#"
    exec "$SCRIPT_DIR/fm-sailor.sh" status --all
    ;;
  steer)
    [ "$#" -ge 2 ] || misuse "steer needs a task id and the text to send"
    id=$1
    shift
    exec "$SCRIPT_DIR/fm-send.sh" "$id" "$*"
    ;;
  land)
    [ "$#" -eq 1 ] || misuse "land takes exactly one task id"
    "$SCRIPT_DIR/fm-merge-local.sh" "$1"
    status=$?
    [ "$status" -ne 0 ] || say "landed: $1; clean up its worker and local copy with bin/fm-teardown.sh $1"
    exit "$status"
    ;;
  wake)
    no_arguments wake "$#"
    exec "$SCRIPT_DIR/fm-wake-drain.sh"
    ;;
  *) misuse "unknown verb '$VERB'; the verbs are $VERBS" ;;
esac
