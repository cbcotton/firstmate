#!/usr/bin/env bash
# fm-opencode-permissions.sh - the permission block every OpenCode worker launch carries.
#
# docs/configuration.md ("OpenCode permission profile") owns the operator
# contract. This header owns selection and composition; bin/fm-spawn.sh puts
# the printed JSON inside the OPENCODE_CONFIG_CONTENT it writes.
#
# Usage:
#   fm-opencode-permissions.sh profile
#   fm-opencode-permissions.sh compose <task-id>
#   fm-opencode-permissions.sh worker-note
#   fm-opencode-permissions.sh baseline
#
# profile prints the selected profile: config/opencode-permission-profile holds
# one token, whitespace-trimmed. Absent or `allow` selects `allow`, today's
# launch; `restricted` selects the composed default-deny profile below. Any
# other value, or an unreadable file, exits 2 naming the accepted values, and
# bin/fm-spawn.sh refuses the spawn rather than choose a posture itself.
#
# compose prints one compact JSON object, the `permission` value for that
# task's launch. For `allow` it is exactly {"*":"allow"}. For `restricted` it is
# these layers, in this order, because OpenCode evaluates every rule in order
# and the last matching rule wins (docs/verification/local-sailors.md):
#   1. the baseline, whose catch-all "*": "deny" comes first;
#   2. every permission grant in force for the task, oldest first
#      (bin/fm-permission-grant.sh active), so the captain's latest word wins;
#   2a. the guard: the deny on a Git command writing its output with --output,
#      which no grant may lift;
#   3. the worker protocol: the task's own brief directory, steering inbox, and
#      status file under external_directory, and the exact shell commands the
#      brief tells a worker to run against them, last so no grant can break it.
# A later layer's rule for a pattern replaces an earlier rule for the same
# pattern and moves to the end, so it wins over every earlier pattern. A
# permission given as a string means that action for the pattern "*", and a
# permission left with only "*" is printed back as a string.
#
# worker-note prints the launch-brief section a restricted worker reads, telling
# it to report a denied tool call instead of looking for another route; it
# prints nothing for `allow`.
#
# baseline prints the shipped restricted baseline on its own.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, and
# FM_CONFIG_OVERRIDE resolve the home exactly as the other bin/ scripts do.
#
# Exit status: 0 success, 2 usage or configuration error (including missing jq).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SELECTOR="$CONFIG/opencode-permission-profile"

# The shipped baseline. Reading and editing inside the task's own copy, the
# read-only and local-commit Git commands, and the pipeline's own CLI are
# allowed; everything else, including every path outside the copy, the network
# tools, sub-agents, any shell command not listed, and a Git command that
# writes its output with --output, is denied. A shell glob cannot rule out a
# redirection, so a restricted sailor also needs the sailor sandbox, which
# bounds where a redirection can write (bin/fm-spawn.sh refuses it without
# config/sailor-sandbox).
BASELINE='{
  "*": "deny",
  "read": "allow",
  "glob": "allow",
  "grep": "allow",
  "lsp": "allow",
  "skill": "allow",
  "edit": "allow",
  "external_directory": "deny",
  "webfetch": "deny",
  "websearch": "deny",
  "task": "deny",
  "question": "deny",
  "doom_loop": "deny",
  "bash": {
    "*": "deny",
    "git status *": "allow",
    "git diff *": "allow",
    "git log *": "allow",
    "git show *": "allow",
    "git add *": "allow",
    "git commit *": "allow",
    "git switch -c *": "allow",
    "git checkout -b *": "allow",
    "git rev-parse *": "allow",
    "git branch --show-current": "allow",
    "no-mistakes axi *": "allow",
    "git push*": "deny"
  }
}'

# Composed after every grant, so no grant for a Git subcommand that takes
# --output can move its allow past this deny.
GUARD='{"bash":{"git *--output*":"deny"}}'

usage() {
  echo "usage: fm-opencode-permissions.sh profile | compose <task-id> | worker-note | baseline" >&2
  exit 2
}

die() {
  echo "fm-opencode-permissions: $*" >&2
  exit 2
}

selected_profile() {
  local token
  if [ ! -e "$SELECTOR" ] && [ ! -L "$SELECTOR" ]; then
    echo allow
    return 0
  fi
  [ -f "$SELECTOR" ] && [ -r "$SELECTOR" ] ||
    die "config/opencode-permission-profile must be a readable regular file holding one of: allow, restricted"
  token=$(tr -d '[:space:]' <"$SELECTOR")
  case "$token" in
    allow | restricted) echo "$token" ;;
    *) die "config/opencode-permission-profile holds '$token'; accepted values are: allow (every tool allowed, the default when the file is absent), restricted (the default-deny profile)" ;;
  esac
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

real_or_given() {  # <path>: the physical path when it resolves, else the path as given
  local dir base
  dir=$(dirname -- "$1")
  base=$(basename -- "$1")
  if dir=$(cd "$dir" 2>/dev/null && pwd -P); then
    printf '%s/%s\n' "$dir" "$base"
  else
    printf '%s\n' "$1"
  fi
}

# protocol_layer <task-id>: the paths and exact shell commands the generated
# brief tells a worker to use (bin/fm-brief.sh), for both the path as the brief
# spells it and its physical path.
protocol_layer() {
  local id=$1 status inbox brief_dir status_real inbox_real brief_real ledger config
  status="$STATE/$id.status"
  inbox="$STATE/$id.inbox"
  brief_dir="$DATA/$id"
  status_real=$(real_or_given "$status")
  inbox_real=$(real_or_given "$inbox")
  brief_real=$(real_or_given "$brief_dir")
  ledger="$FM_ROOT/bin/fm-fleet-ledger.sh"
  config="$CONFIG"
  jq -cn \
    --arg status "$status" --arg status_real "$status_real" \
    --arg inbox "$inbox" --arg inbox_real "$inbox_real" \
    --arg brief "$brief_dir" --arg brief_real "$brief_real" \
    --arg qstatus "$(shell_quote "$status")" --arg qinbox "$(shell_quote "$inbox")" \
    --arg qledger "$(shell_quote "$ledger")" --arg qconfig "$(shell_quote "$config")" \
    --arg qflag "$(shell_quote "$config/fleet-ledger")" '
    {
      external_directory: ([$status, $status_real, ($inbox + "/*"), ($inbox_real + "/*"), $inbox, $inbox_real, ($brief + "/*"), ($brief_real + "/*")]
        | unique | map({key: ., value: "allow"}) | from_entries),
      bash: {
        ("echo * >> " + $qstatus): "allow",
        ("[ ! -e " + $qflag + " ]"): "allow",
        ($qledger + " appended " + $qconfig + " " + $qstatus): "allow",
        ("true"): "allow",
        ("ls " + $qinbox + "/*.msg"): "allow",
        ("cat " + $qinbox + "/*.msg"): "allow",
        ("mv " + $qinbox + "/*.msg " + $qinbox + "/handled/"): "allow",
        ("mkdir -p " + $qinbox + "/handled"): "allow"
      }
    }'
}

# compose_layers <layer-json>...: fold the layers in order under the rule above.
compose_layers() {
  jq -cn --argjson layers "$(printf '%s\n' "$@" | jq -cs .)" '
    def norm: with_entries(.value |= (if type == "string" then {"*": .} else . end));
    reduce ($layers[] | norm) as $layer ({};
      reduce ($layer | to_entries[]) as $perm (.;
        .[$perm.key] = (((.[$perm.key] // {}) | to_entries
                         | map(select(.key as $k | ($perm.value | has($k)) | not)))
                        + ($perm.value | to_entries) | from_entries)))
    | map_values(if keys == ["*"] then .["*"] else . end)'
}

cmd_compose() {
  local id=$1 profile grants layer
  local -a layers
  case "$id" in '' | .* | *[!A-Za-z0-9._-]*) die "invalid task id '$id'" ;; esac
  profile=$(selected_profile) || exit 2
  if [ "$profile" = allow ]; then
    printf '%s\n' '{"*":"allow"}'
    return 0
  fi
  grants=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-permission-grant.sh" active --task "$id") ||
    die "the permission grants for task $id could not be read"
  layers=("$(printf '%s' "$BASELINE" | jq -c .)")
  while IFS= read -r layer; do
    [ -z "$layer" ] || layers+=("$layer")
  done < <(printf '%s' "$grants" | jq -c '.[]')
  layers+=("$GUARD" "$(protocol_layer "$id")")
  compose_layers "${layers[@]}"
}

cmd_worker_note() {
  local profile
  profile=$(selected_profile) || exit 2
  [ "$profile" = restricted ] || return 0
  cat <<'EOF'

# Restricted tools
Your tools run under a restricted permission profile: reading and editing inside this copy, local Git commits, the no-mistakes CLI, and this task's own status and inbox commands are allowed, and everything else is denied.
When a tool call is denied, do not look for another way to reach the same result.
Append `needs-decision [at=<epoch>] [key=perm-<slug>]: needs <what> because <why>` to your status file and stop; firstmate relays it, and only the captain widens a worker's permissions.
EOF
}

command -v jq >/dev/null 2>&1 || die "jq is required"
[ "$#" -ge 1 ] || usage
case "$1" in
  profile)
    [ "$#" -eq 1 ] || usage
    selected_profile
    ;;
  compose)
    [ "$#" -eq 2 ] || usage
    cmd_compose "$2"
    ;;
  worker-note)
    [ "$#" -eq 1 ] || usage
    cmd_worker_note
    ;;
  baseline)
    [ "$#" -eq 1 ] || usage
    printf '%s' "$BASELINE" | jq -c .
    ;;
  -h | --help)
    sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    ;;
  *) usage ;;
esac
