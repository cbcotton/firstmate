#!/usr/bin/env bash
# fm-privateer.sh - the Privateer quarantine: a firstmate home that never reaches
# Anthropic, and the launcher for its OpenCode first mate.
#
# docs/configuration.md ("Privateer quarantine") owns the operator contract.
# This header owns the rules `check` enforces, the launch environment, and the
# session mechanics. bin/fm-spawn.sh and bin/fm-bootstrap.sh call `check`, so
# the spawn refusal, the bootstrap report, and the launcher share one list.
#
# Usage:
#   fm-privateer.sh check
#   fm-privateer.sh inside
#   fm-privateer.sh launch-env
#   fm-privateer.sh start
#   fm-privateer.sh attach
#   fm-privateer.sh stop [--stow]
#   fm-privateer.sh project [<name> | --clear]
#   fm-privateer.sh reload
#
# The quarantine is on while config/privateer exists. Its content is optional:
# one line `<sailor>/<model>` names the sailor and model the first mate itself
# runs on, both from config/crew-dispatch.json; `start` requires that line.
#
# check prints nothing and exits 0 when config/privateer is absent. Otherwise it
# prints one line per violation and exits 1 on any, else exits 0 silently:
#   - config/crew-harness must hold opencode;
#   - config/secondmate-harness, when present, must name opencode;
#   - config/supervision-host, config/claude-account, and config/pi-account must
#     not exist (a Claude engine, a Claude login, a Pi login);
#   - config/inbox-ask-model, inbox-stt-model, inbox-region, inbox-profile,
#     voice-model, voice-region, and voice-profile must not exist (the inbox and
#     voice side channels send the captain's words to Bedrock);
#   - config/sailor-sandbox must exist, so every sailor's egress is confined;
#   - .env must set no FMX_PAIRING_TOKEN or TYPESAFE_API_KEY (Relay and typed
#     resolution reach outside services), no FM_INBOX_* or FM_VOICE_* override
#     (the same Bedrock side channels), and no ANTHROPIC_*, CLAUDE_*, or
#     CLAUDECODE line;
#   - config/launch-env-allowlist must list no ANTHROPIC_*, CLAUDE_*, or
#     CLAUDECODE name;
#   - config/crew-dispatch.json must exist and parse, declare no sailor_fallback,
#     give every rule and default profile the opencode harness and a sailor, and
#     give every sailor a private endpoint: an http or https URL whose authority
#     (everything up to the first /, ?, or #) carries no userinfo or backslash
#     and names localhost, a loopback, RFC 1918, or tailnet (100.64/10) IPv4
#     address, an IPv6 loopback or unique-local address, or a name ending in
#     .local or .ts.net;
#   - a non-empty config/privateer must read <sailor>/<model> with that model
#     listed for that sailor;
#   - the origin of this checkout and of every clone under projects/ (https,
#     http, ssh, and scp forms) must not be on a host that is, or is under,
#     anthropic.com, claude.ai, or claude.com; the egress proxy never allows
#     such a host either.
#
# inside answers whether the calling process runs inside this home's Privateer
# session, which is so when its TMUX names the session's socket. It exits 0,
# silently, when it does; 3, silently, when config/privateer is absent, so there
# is no session to be inside; and 1 otherwise, with one refusal line on stderr
# that tells the caller to stop and hand back to the captain, who attaches with
# `attach`, and names no socket or port the caller could drive. The OpenCode
# seal plugin (.opencode/plugins/fm-privateer-seal.js) acts on that answer.
#
# launch-env prints the isolation assignments, one NAME=value per line, for
# bin/fm-spawn.sh to export into every Privateer worker launch, and refuses
# (exit 1) unless it runs inside this home's Privateer session (the test
# bin/fm-privateer-lib.sh owns, which also gates the home's other scripts) and
# the session's egress proxy runs: XDG_CONFIG_HOME,
# XDG_DATA_HOME, XDG_STATE_HOME, and XDG_CACHE_HOME under
# state/privateer/opencode/, so the captain's own OpenCode config, logins,
# sessions, and cache are invisible; OPENCODE_DISABLE_AUTOUPDATE=1;
# TREEHOUSE_ROOT naming this home's own worktree pool; HTTP_PROXY,
# HTTPS_PROXY, http_proxy, and https_proxy naming the egress proxy; and
# GIT_SSH_COMMAND, which tunnels Git over SSH through it. The first mate
# receives the same assignments from start.
#
# The egress proxy (bin/fm-privateer-proxy.py) is the session's only way out.
# start runs it as its own process, outside the session and its sandbox; it
# listens on a loopback port, writes that port to state/privateer/egress/port
# and its process id to state/privateer/egress/pid, logs every allowed and
# refused destination to state/privateer/egress/log, and allows exactly: every
# sailor endpoint in config/crew-dispatch.json, and the origin of this checkout
# and of every clone under projects/ (the forge: the URL's host and port, 443
# for https, 80 for http, 22 for ssh). start writes that list, one
# `<host>:<port>` per line, to state/privateer/egress/allow, which the session
# sandbox cannot write, by temp-file-and-rename, and the proxy re-reads the file
# when it changes.
#
# The record writer (bin/fm-privateer-records.py, whose header owns its wire
# behavior and identity check) is the only writer of the task records
# state/<id>.meta while the session runs. start runs it as its own process,
# outside the session and its sandbox, after the tmux server, with the first
# mate's pane process id and start time, which it captures right after the
# server starts, and writes its process id to
# state/privateer/egress/records.pid. Its socket is the one
# bin/fm-privateer-lib.sh names, beside the session's tmux socket; it stages
# each write in state/privateer/egress/records.tmp/ and logs each refusal to
# state/privateer/egress/records.log. It writes a record only for the first
# mate's own process or one that descends from it, so a worker, which is a pane
# the tmux server forks, can write none; the home's scripts inside the session
# hand it every write of a task record (bin/fm-backlog-transition-lib.sh).
#
# reload is the captain's command to rewrite that file from the current config
# (config/crew-dispatch.json and the forge origins) without restarting the
# session. It runs outside the session like start and stop, refuses inside it
# and when no egress proxy runs, prints each destination it added or removed
# (or that nothing changed), and the proxy logs the reload.
#
# start refuses without config/privateer, on any check violation, without a
# first-mate line in config/privateer, without this checkout's Privateer
# rulebook (docs/privateer/AGENTS.md and docs/privateer/agents/privateer.md),
# and while the session already runs. It probes the first mate's sailor with
# bin/fm-sailor.sh check, renders the helm, starts the egress proxy, refusing
# and starting nothing else if the helm cannot be rendered or the proxy cannot
# bind, then starts a dedicated tmux server (the socket bin/fm-privateer-lib.sh
# names) inside bin/fm-sandbox-exec.sh, whose session `privateer` runs the
# OpenCode primary as `opencode --agent privateer` in window `firstmate`, in
# the helm with FM_HOME set to this home. Once that window's pane exists, and
# before any worker can, it starts the record writer for the pane's process,
# and if it cannot, stops the server and the proxy and refuses. The
# server, and again the primary itself, start from an empty environment plus
# exactly: HOME PATH USER LOGNAME SHELL TERM TERMINFO TERMINFO_DIRS COLORTERM LANG
# LC_ALL LC_CTYPE TMPDIR TMP TEMP TMUX_TMPDIR as the launcher saw them (TERMINFO
# and TERMINFO_DIRS only name where terminal descriptions are read from),
# TMPPREFIX inside that temporary directory, FM_HOME, and the
# launch-env assignments above; the primary adds OPENCODE_CONFIG_CONTENT, which
# pins the model to the first mate's sailor as the only provider, allows every
# tool as a secondmate primary is allowed, turns auto-update off, disables
# sharing, and makes the privateer agent the default, so a turn a plugin starts
# without naming an agent, such as the session-start digest or a wake, runs
# as that agent too; FM_ROOT_OVERRIDE naming this checkout, so every script and plugin
# keeps it as the code root; and OPENCODE_DISABLE_EXTERNAL_SKILLS=1 and
# OPENCODE_DISABLE_CLAUDE_CODE=1, so no skill or instruction file under the
# captain's ~/.claude or ~/.agents reaches the first mate. The primary also
# keeps the TMUX and TMUX_PANE names its own server sets.
# No ANTHROPIC_*, CLAUDE_*, or CLAUDECODE variable can reach the tree,
# because nothing outside that list does; the server copies no variable from a
# later attaching client either. A worker pane's login shell may still read
# the captain's shell profile, so bin/fm-spawn.sh clears the environment again
# at each worker's command boundary.
#
# The helm, state/privateer/helm/, is the first mate's working directory and
# its whole instruction surface, rendered afresh at every start from this
# checkout's tracked sources: its own Git repository, where OpenCode's search
# for instructions and skills stops, so the checkout's AGENTS.md never loads;
# docs/privateer/AGENTS.md, the Privateer rulebook, as AGENTS.md;
# docs/privateer/agents/privateer.md as .opencode/agents/privateer.md, whose
# skill permission denies every skill but the helm's own;
# docs/privateer/skills/<name>/SKILL.md as .opencode/skills/<name>/SKILL.md; a
# copy of this checkout's .opencode/plugins/ and, when it has them, its
# .opencode/commands/, the slash commands; .opencode/.gitignore, as
# OpenCode itself writes it, because OpenCode writes that file at start when
# it is missing and cannot start when the sandbox refuses the write; and bin/,
# holding for every executable bin/*.sh of this checkout a script that execs
# it by its real path, so each finds this checkout as its root, and a link to
# every other entry of this checkout's bin/.
# bin/fm-privateer-rulebook-check.sh owns the rules those sources must meet.
#
# The sandbox holds the tmux server itself, so every pane and every command
# started in the session inherits it: the first mate, each worker and its pane
# shell, and anything the first mate asks tmux to run. Everything inside may
# write only to this home, this checkout's .opencode/ scratch, the shared
# temporary namespaces the remaining limits below name, and the server's own
# socket. Workers'
# copies live in this home's own Treehouse pool, state/privateer/treehouse,
# which launch-env names as TREEHOUSE_ROOT, so treehouse creates and hands out
# slots there; the shared pool under ~/.treehouse, and every other home's
# slots, are out of reach. Nothing inside may write this home's egress
# directory, config/, or bin/; the grant ledger state/permission-grants.jsonl,
# which the captain writes from outside (bin/fm-permission-grant.sh); any task
# record state/<id>.meta, which the record writer writes, or its socket; the
# helm, or any directory entry between this home and it; when this checkout
# is inside this home, its bin/, the scripts the captain runs outside the
# session, and any path in it an
# OpenCode first mate loads or the helm is rendered from: its AGENTS.md, CLAUDE.md,
# CONTEXT.md, opencode.json(c), tui.json(c), .agents/, docs/, the .claude
# entry and its skills link, the .opencode entry, and, under .opencode/, the
# opencode.json(c) and tui.json(c) files and the agent(s), command(s),
# mode(s), plugin(s), skill(s), and tool(s) directories, so no worker can
# rewrite the first mate's instructions, docs, config, skills, agents,
# commands, modes, plugins, or tools there; the Git config or hooks of this
# checkout, of any clone under projects/, or of any linked worktree or
# submodule of those (git dirs under .git/worktrees/<name>/ and
# .git/modules/<path>/, and, for a linked worktree outside this home's pool,
# its own modules/<path>/); the commondir of the top-level git dir of the
# checkout and of each clone, and of every submodule git dir under those or
# under a linked worktree outside the pool, which Git reads to find the config
# and hooks it uses; the git dir, commondir, or gitdir of a linked worktree
# that lives outside the pool, so none can be redirected or relabeled as a
# pool worktree; any .git entry inside a clone, the checkout's own .git, or
# the .git gitfile, which Git reads to find a git dir, of every submodule
# checkout and every linked worktree outside the pool that lies in this home,
# with each directory entry between this home and it; or the projects
# directory, any clone's directory, any directory between this home and the
# checkout's git dir, or any directory entry that leads to one of those Git
# configs or hooks: the top-level git dir of the checkout and of each clone,
# its modules directory, every entry under that leading to a submodule's git
# dir, each submodule git dir's own modules and worktrees entries, and the git
# dir of a linked worktree outside the pool with the same modules entries of
# its own; so none of those can be moved aside, changed, and moved back,
# replaced, or linked over. The worktrees directory of the checkout's and each
# clone's git dir is the one such entry that may still be created, because the
# session's first pool worktree creates it, but nothing inside may move it,
# remove it, or place a symlink there.
# It may connect only to the egress proxy, the DNS resolver, that socket, and
# the record writer's socket, so a client that ignores the proxy variables
# reaches nothing remote at all, and may signal only processes inside the same
# sandbox, so it can neither stop the proxy or the record writer nor rewrite
# their records. Process information stays readable, as
# bin/fm-sandbox-exec.sh states, so the first mate finds its own OpenCode
# process and owns this home's session lock, while a plain shell started in
# the session finds no harness and stays read-only.
#
# Remaining limits, by design:
#   - macOS cannot apply a second sandbox inside the first, so one session
#     sandbox covers the first mate and every worker alike, in place of a
#     per-task sailor sandbox;
#   - a worker can therefore still write every other file under state/ and
#     data/, including the status lines the first mate reads as evidence, and
#     hold a task record's lock (state/.meta-<id>.lock) so the first mate's
#     spawn waits; on the session's one tmux server it can also type into the
#     first mate's pane, and so make the first mate write a record for it;
#   - a record write from a script the first mate detaches (nohup, setsid)
#     is refused, because that script no longer descends from the first mate;
#     and once the first mate's process ends, every record write is refused
#     until the session is started again;
#   - the per-task temp roots under /tmp/fm-*, the user's own temporary
#     directory ($TMPDIR), and the flat here-document files stock macOS
#     Bash writes directly in /var/tmp as sh-thd* are namespaces shared by
#     every home on this machine, so a checkout kept in one of them, such as
#     a linked worktree, keeps its .git gitfile writable;
#   - clones under projects/ are added, moved, and removed outside the
#     session, and a worktree the session creates in its own pool is meant
#     for use only inside it;
#   - start finds the linked worktrees, submodule git dirs, and submodule
#     checkouts that exist when it runs, so for one added from outside while
#     the session runs, only its Git config and hooks, a submodule git dir's
#     commondir, any .git entry inside a clone, and the worktrees and modules
#     entries of the checkout's or clone's git dir with the entries directly
#     in that modules directory, are covered until the next start; until then
#     a linked worktree added that way can still be redirected through its
#     commondir, because the session's own pool worktrees write the same file
#     and a path rule cannot tell the two apart;
#   - OpenCode also loads plugins and configuration from its own directories
#     under state/privateer/opencode/, which stay writable, so a worker can
#     still add one there that the first mate loads at its next start;
#   - as bin/fm-sandbox-exec.sh states, the sandbox is not a boundary against
#     same-user system services that start programs outside it.
#
# attach attaches this terminal to the running session. stop refuses while any
# task record (state/<id>.meta) exists, because a running worker's copy would
# be orphaned, and otherwise stops this home's watcher and the whole server,
# and then the egress proxy and the record writer. When the session has already
# ended, stop still stops the watcher and any egress proxy or record writer
# left behind and says so, and refuses only when there was neither to stop.
#
# stop --stow is the captain's stop with a /stow first, for a caller such as a
# Dock app. It applies the same refusals as stop, then, as the front door acting
# on its own session, waits until the first mate's pane reads idle, refuses
# unless its input line is proven empty, types /stow there with the shared
# verified submit (bin/fm-tmux-lib.sh fm_tmux_submit_core), waits until the
# pane reads busy at least once, so the stow turn is seen to start, and then
# waits until it reads idle again; idle is the OpenCode delivery-busy footer
# read (fm_pane_busy_state) absent STOW_IDLE_READS times in a row. Only then,
# and only while still no task record exists, does it run the stop sequence.
# All waits share one deadline, FM_PRIVATEER_STOW_WAIT seconds (600), read
# every FM_PRIVATEER_STOW_POLL seconds (2); a stow that is not delivered, not
# seen to start, or not finished by then refuses and leaves the session
# running. Its output names no socket or port. When the session has already
# ended there is nothing to stow, and it cleans up as stop does.
#
# project is the captain's way to set the home's active project, the default
# referent for a request that names none (docs/configuration.md owns the
# contract). `project <name>` refuses unless data/projects.md registers <name>
# and a clone of it exists under projects/, then writes config/active-project
# atomically (a temporary file renamed over it); `project --clear` removes the
# file; `project` alone prints every registered project that has a clone, the
# active one marked `*`. The session sandbox denies writes to config/, so the
# set and clear forms also refuse inside the session; every form refuses in a
# home without config/privateer, so the main home never sets an active project.
# The bare form only reads, so it also works inside the session.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, and
# FM_PROJECTS_OVERRIDE resolve the home exactly as the other bin/ scripts do. With FM_TEST_SEAM=1, FM_PRIVATEER_PRIMARY names a command to launch in
# place of opencode, with the same arguments, so a test can prove the launch
# environment with a stub.
#
# Exit status: 0 success, 1 refused (a violation, a missing prerequisite, work
# in flight, a stow not delivered, not started, or not finished, or, for
# inside, a caller outside the session), 2 usage or configuration error, 3
# (inside only) no config/privateer.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-privateer-lib.sh
. "$SCRIPT_DIR/fm-privateer-lib.sh"
FLAG="$CONFIG/privateer"
DISPATCH="$CONFIG/crew-dispatch.json"
SESSION=$FM_PRIVATEER_SESSION
OPENCODE_ROOT="$STATE/privateer/opencode"
EGRESS="$STATE/privateer/egress"
POOL="$STATE/privateer/treehouse"
HELM="$STATE/privateer/helm"
RULEBOOK="$FM_ROOT/docs/privateer"
STOW_IDLE_READS=3
FORBIDDEN_NAME_RE='^(ANTHROPIC_[A-Za-z0-9_]*|CLAUDE_[A-Za-z0-9_]*|CLAUDECODE)$'

usage() {
  echo "usage: fm-privateer.sh check | inside | launch-env | start | attach | stop [--stow] | reload | project [<name>|--clear]" >&2
  exit 2
}

die() {
  echo "fm-privateer: $*" >&2
  exit 2
}

refuse() {
  echo "fm-privateer: refused: $*" >&2
  exit 1
}

active() {
  [ -e "$FLAG" ] || [ -L "$FLAG" ]
}

regex_quote() {
  printf '%s' "$1" | sed 's/[][\.^$*+?(){}|]/\\&/g'
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# url_hostport <url>: `<host>:<port>` of an http(s) URL, the host lowercased
# (an IPv6 address kept in brackets) and the port explicit or the scheme's
# default. The authority ends at the first /, ?, or #, and one carrying
# userinfo or a backslash fails, as does anything that is not such a URL.
url_hostport() {
  local url=$1 authority host port
  case "$url" in
    http://*) port=80 ;;
    https://*) port=443 ;;
    *) return 1 ;;
  esac
  authority=${url#*://}
  authority=${authority%%[/?#]*}
  case "$authority" in
    '' | *@* | *\\*) return 1 ;;
    \[*\]) host=$authority ;;
    \[*\]:*) host="${authority%%]*}]"; port=${authority#*]:} ;;
    \[*) return 1 ;;
    *:*) host=${authority%%:*}; port=${authority#*:} ;;
    *) host=$authority ;;
  esac
  case "$port" in '' | *[!0-9]*) return 1 ;; esac
  case "$host" in '' | '[]') return 1 ;; esac
  printf '%s:%s\n' "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" "$((10#$port))"
}

# private_host <host>: the endpoint rule in the header, on the host alone.
private_host() {
  local host=$1 lower o1 o2
  lower=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  [ -n "$lower" ] || return 1
  case "$lower" in
    localhost | *.local | *.ts.net) return 0 ;;
    ::1) return 0 ;;
    f[cd]??:*) return 0 ;;
  esac
  case "$lower" in
    *[!0-9.]*) return 1 ;;
  esac
  IFS=. read -r o1 o2 _ _ <<EOF
$lower
EOF
  case "$o1" in '' | *[!0-9]*) return 1 ;; esac
  case "$o2" in '' | *[!0-9]*) return 1 ;; esac
  [ "$o1" -le 255 ] && [ "$o2" -le 255 ] || return 1
  case "$o1" in
    127 | 10) return 0 ;;
    192) [ "$o2" -eq 168 ] && return 0 ;;
    172) [ "$o2" -ge 16 ] && [ "$o2" -le 31 ] && return 0 ;;
    100) [ "$o2" -ge 64 ] && [ "$o2" -le 127 ] && return 0 ;;
  esac
  return 1
}

endpoint_ok() {
  local host
  host=$(url_hostport "$1") || return 1
  host=${host%:*}
  host=${host#[}
  private_host "${host%]}"
}

# env_file_violations: forbidden keys set in this home's .env, one per line.
env_file_violations() {
  local file="$FM_HOME/.env" key
  [ -f "$file" ] || return 0
  grep -E '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$file" 2>/dev/null |
    sed -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/' |
    while IFS= read -r key; do
      case "$key" in
        FMX_PAIRING_TOKEN) echo ".env sets FMX_PAIRING_TOKEN, and Relay answers public mentions through an outside service" ;;
        TYPESAFE_API_KEY) echo ".env sets TYPESAFE_API_KEY, and typed dispatch resolution sends every brief to an outside model" ;;
        FM_INBOX_* | FM_VOICE_*) echo ".env sets $key, and the inbox and voice side channels send the captain's words to Bedrock" ;;
        *)
          if printf '%s\n' "$key" | grep -Eq "$FORBIDDEN_NAME_RE"; then
            echo ".env sets $key, an Anthropic or Claude variable"
          fi
          ;;
      esac
    done
}

allowlist_violations() {
  local file="$CONFIG/launch-env-allowlist" name
  [ -f "$file" ] || return 0
  grep -E "$FORBIDDEN_NAME_RE" "$file" 2>/dev/null | while IFS= read -r name; do
    echo "config/launch-env-allowlist lists $name, an Anthropic or Claude variable, for every worker launch"
  done
}

harness_token() {  # <file>: the first non-empty, non-comment line's first word
  sed -e 's/#.*//' "$1" 2>/dev/null | awk 'NF { print $1; exit }'
}

# first_mate_line: the <sailor>/<model> line of config/privateer, or empty.
first_mate_line() {
  [ -f "$FLAG" ] || return 0
  sed -e 's/#.*//' "$FLAG" 2>/dev/null | awk 'NF { print $1; exit }'
}

dispatch_violations() {
  local line
  if [ ! -f "$DISPATCH" ]; then
    echo "config/crew-dispatch.json is absent; a Privateer home dispatches only to the sailors it names"
    return 0
  fi
  if ! jq -e . "$DISPATCH" >/dev/null 2>&1; then
    echo "config/crew-dispatch.json is not valid JSON"
    return 0
  fi
  jq -r '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    def uses: [(.rules // [])[]? | profiles(.use?)[]?] + [profiles(.default?)[]?];
    def profile_name($p): ($p.harness // "no harness" | tostring) + (if $p.model? then "/" + ($p.model | tostring) else "" end);
    (if has("sailor_fallback") then ["config/crew-dispatch.json declares sailor_fallback; Privateer work queues when every sailor is down instead of falling back"] else [] end)
    + [uses[] | select(type == "object") | select(.harness != "opencode") | "config/crew-dispatch.json profile " + profile_name(.) + " uses a harness other than opencode"]
    + [uses[] | select(type == "object") | select(.harness == "opencode" and (has("sailor") | not)) | "config/crew-dispatch.json profile " + profile_name(.) + " names no sailor, so it would run on the captain'"'"'s own OpenCode providers"]
    + (if has("sailors") and (.sailors | type) != "object" then ["config/crew-dispatch.json sailors must be an object"]
       elif (.sailors // {} | length) == 0 then ["config/crew-dispatch.json names no sailors"]
       else [] end)
    | .[]' "$DISPATCH" 2>/dev/null
  jq -r '(.sailors // {}) | to_entries[] | select((.value | type) == "object") | "\(.key)\t\(.value.endpoint // "")"' "$DISPATCH" 2>/dev/null |
    while IFS=$'\t' read -r name endpoint; do
      endpoint_ok "$endpoint" || echo "config/crew-dispatch.json sailor $name has endpoint '$endpoint', which is not on this machine or the local network"
    done
  line=$(first_mate_line)
  [ -n "$line" ] || return 0
  case "$line" in
    */*) ;;
    *) echo "config/privateer holds '$line', but the first mate line reads <sailor>/<model>"; return 0 ;;
  esac
  jq -e --arg s "${line%%/*}" --arg m "${line#*/}" '.sailors[$s].models | index($m) != null' "$DISPATCH" >/dev/null 2>&1 ||
    echo "config/privateer names ${line%%/*}/${line#*/}, but config/crew-dispatch.json lists no such sailor and model"
}

cmd_check() {
  local out name
  active || return 0
  command -v jq >/dev/null 2>&1 || die "jq is required"
  out=$(
    if [ ! -f "$CONFIG/crew-harness" ] || [ "$(harness_token "$CONFIG/crew-harness")" != opencode ]; then
      echo "config/crew-harness must hold opencode"
    fi
    if [ -f "$CONFIG/secondmate-harness" ] && [ "$(harness_token "$CONFIG/secondmate-harness")" != opencode ]; then
      echo "config/secondmate-harness names $(harness_token "$CONFIG/secondmate-harness"), a harness other than opencode"
    fi
    [ ! -e "$CONFIG/supervision-host" ] || echo "config/supervision-host exists, and the supervision host runs on Claude"
    [ ! -e "$CONFIG/claude-account" ] || echo "config/claude-account exists, and it pins a Claude login"
    [ ! -e "$CONFIG/pi-account" ] || echo "config/pi-account exists, and it pins a Pi login"
    for name in inbox-ask-model inbox-stt-model inbox-region inbox-profile voice-model voice-region voice-profile; do
      [ ! -e "$CONFIG/$name" ] || echo "config/$name exists, and the inbox and voice side channels send the captain's words to Bedrock"
    done
    [ -e "$CONFIG/sailor-sandbox" ] || echo "config/sailor-sandbox is absent; every Privateer sailor runs inside the sandbox"
    env_file_violations
    allowlist_violations
    dispatch_violations
    forge_violations
  )
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
  return 1
}

cmd_launch_env() {
  local port proxy
  port=$(cat "$EGRESS/port" 2>/dev/null) || port=
  case "$port" in
    '' | *[!0-9]*) refuse "the Privateer egress proxy is not running; start the session with fm-privateer.sh start" ;;
  esac
  proxy="http://127.0.0.1:$port"
  printf 'XDG_CONFIG_HOME=%s\n' "$OPENCODE_ROOT/config"
  printf 'XDG_DATA_HOME=%s\n' "$OPENCODE_ROOT/data"
  printf 'XDG_STATE_HOME=%s\n' "$OPENCODE_ROOT/state"
  printf 'XDG_CACHE_HOME=%s\n' "$OPENCODE_ROOT/cache"
  printf 'OPENCODE_DISABLE_AUTOUPDATE=1\n'
  printf 'TREEHOUSE_ROOT=%s\n' "$POOL"
  printf 'HTTP_PROXY=%s\nHTTPS_PROXY=%s\nhttp_proxy=%s\nhttps_proxy=%s\n' "$proxy" "$proxy" "$proxy" "$proxy"
  printf "GIT_SSH_COMMAND=ssh -o ProxyCommand='/usr/bin/nc -X connect -x 127.0.0.1:%s %%h %%p'\n" "$port"
}

# socket_name: one tmux server per Privateer home, keyed by the home's path.
socket_name() {
  fm_privateer_socket_name "$FM_HOME"
}

tmux_socket_path() {  # <socket-name>
  fm_privateer_socket_path "$1"
}

# records_socket: the record writer's socket, beside the session's tmux socket.
records_socket() {
  fm_privateer_records_socket "$FM_HOME"
}

session_running() {  # <socket-name>
  fm_privateer_session_running "$1"
}

# forge_origins: one `<host>:<port>\t<repo>` line per forge origin: the origin
# of this checkout and of every clone under projects/. A forge URL's userinfo
# (the part of its authority before the last @) is its login, not its host.
forge_origins() {
  local repo url rest authority hostport
  for repo in "$FM_ROOT" "$PROJECTS"/*/; do
    [ -d "$repo" ] || continue
    url=$(git -C "$repo" remote get-url origin 2>/dev/null) || continue
    hostport=
    case "$url" in
      https://* | http://*)
        rest=${url#*://}
        authority=${rest%%[/?#]*}
        hostport=$(url_hostport "${url%%://*}://${authority##*@}${rest#"$authority"}") || hostport=
        ;;
      ssh://*)
        hostport=${url#ssh://}
        hostport=${hostport%%/*}
        hostport=${hostport##*@}
        case "$hostport" in
          *:*) ;;
          ?*) hostport=$hostport:22 ;;
        esac
        ;;
      /* | file://*) ;;
      *@*:* | *:*/*)
        hostport=${url%%:*}
        hostport=${hostport##*@}
        [ -z "$hostport" ] || hostport=$hostport:22
        ;;
    esac
    [ -z "$hostport" ] || printf '%s\t%s\n' "$(printf '%s' "$hostport" | tr '[:upper:]' '[:lower:]')" "${repo%/}"
  done
}

# anthropic_host <host:port>: whether the host is, or is under, anthropic.com,
# claude.ai, or claude.com.
anthropic_host() {
  local host=${1%:*}
  while [ "${host%.}" != "$host" ]; do host=${host%.}; done
  case "$host" in
    anthropic.com | *.anthropic.com | claude.ai | *.claude.ai | claude.com | *.claude.com) return 0 ;;
  esac
  return 1
}

forge_violations() {
  local dest repo
  forge_origins | while IFS=$'\t' read -r dest repo; do
    ! anthropic_host "$dest" || echo "the origin of $repo is on $dest, an Anthropic or Claude host"
  done
}

# egress_allowlist: the egress proxy's destinations, one `<host>:<port>` per
# line: every sailor endpoint, and every forge origin that is not an Anthropic
# or Claude host.
egress_allowlist() {
  local url dest
  {
    jq -r '(.sailors // {}) | to_entries[] | .value.endpoint? // empty' "$DISPATCH" 2>/dev/null |
      while IFS= read -r url; do url_hostport "$url" || true; done
    forge_origins | cut -f1
  } | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u | while IFS= read -r dest; do
    anthropic_host "$dest" || printf '%s\n' "$dest"
  done
}

# proxy_running: the proxy this home last started is alive.
proxy_running() {
  local pid
  pid=$(cat "$EGRESS/pid" 2>/dev/null) || return 1
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  case "$(ps -p "$pid" -o command= 2>/dev/null)" in
    *fm-privateer-proxy.py*) return 0 ;;
  esac
  return 1
}

# stop_egress_proxy: stop the proxy this home last started, if it still runs.
stop_egress_proxy() {
  if proxy_running; then kill "$(cat "$EGRESS/pid")" 2>/dev/null || true; fi
  rm -f "$EGRESS/port" "$EGRESS/pid" "$EGRESS/allow"
}

# write_allow_file: the current allowlist into $EGRESS/allow, by temp-file-and-
# rename so the proxy never reads a half-written file.
write_allow_file() {
  local tmp
  tmp=$(mktemp "$EGRESS/allow.XXXXXX") || die "cannot write $EGRESS/allow"
  if ! egress_allowlist > "$tmp" || ! mv -f "$tmp" "$EGRESS/allow"; then
    rm -f "$tmp"
    die "cannot write $EGRESS/allow"
  fi
}

# start_egress_proxy: the proxy as its own process, outside the session and its
# sandbox, started with cmd_start's env_args; prints its port once it has
# bound, or fails.
start_egress_proxy() {
  local port pid
  mkdir -p "$EGRESS" || die "cannot create $EGRESS"
  stop_egress_proxy
  write_allow_file
  /usr/bin/env -i "${env_args[@]}" nohup python3 "$SCRIPT_DIR/fm-privateer-proxy.py" "$EGRESS/port" "$EGRESS/log" \
    "$EGRESS/allow" </dev/null >>"$EGRESS/proxy.err" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$EGRESS/pid"
  for _ in $(seq 100); do
    port=$(cat "$EGRESS/port" 2>/dev/null) || port=
    case "$port" in
      '' | *[!0-9]*) ;;
      *) printf '%s\n' "$port"; return 0 ;;
    esac
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  stop_egress_proxy
  return 1
}

# records_running: the record writer this home last started is alive.
records_running() {
  local pid
  pid=$(cat "$EGRESS/records.pid" 2>/dev/null) || return 1
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  case "$(ps -p "$pid" -o command= 2>/dev/null)" in
    *fm-privateer-records.py*) return 0 ;;
  esac
  return 1
}

# stop_record_writer: stop the record writer this home last started, if it
# still runs, and retire its socket.
stop_record_writer() {
  local pid _
  if records_running; then
    pid=$(cat "$EGRESS/records.pid")
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  rm -f "$EGRESS/records.pid" "$EGRESS/records.ready" "$(records_socket)"
}

# start_record_writer <anchor-pid> <anchor-start>: the record writer as its own
# process, outside the session and its sandbox, started with cmd_start's
# env_args and serving cmd_start's home_real state directory for the first
# mate's process <anchor-pid>, started at <anchor-start>; fails unless it
# listens.
start_record_writer() {
  local pid _
  stop_record_writer
  /usr/bin/env -i "${env_args[@]}" nohup python3 -I "$SCRIPT_DIR/fm-privateer-records.py" serve "$(records_socket)" \
    "$home_real/state" "$EGRESS" "$1" "$2" </dev/null >>"$EGRESS/records.err" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$EGRESS/records.pid"
  for _ in $(seq 100); do
    [ ! -e "$EGRESS/records.ready" ] || return 0
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  stop_record_writer
  return 1
}

# deny_entries <path>: deny writes to <path> and to each directory entry above
# it up to, but not including, this home, so none can be renamed or created;
# a path outside the home needs nothing. Uses cmd_start's home_real and
# sandbox_args.
deny_entries() {
  local p=$1
  while :; do
    case "$p" in
      "$home_real"/*) ;;
      *) return 0 ;;
    esac
    sandbox_args+=(--deny-write-regex "^$(regex_quote "$p")\$")
    p=${p%/*}
  done
}

# deny_gitfile <dir> <checkout>: deny the .git entry of <checkout>, a path
# relative to <dir> or absolute, and each directory entry leading to it, as
# deny_entries does; a checkout that does not resolve needs nothing.
deny_gitfile() {
  local checkout
  checkout=$(cd "$1" 2>/dev/null && cd "$2" 2>/dev/null && pwd -P) || return 0
  deny_entries "$checkout/.git"
}

# deny_module_entries <modules-dir>: below a modules directory whose own entry
# and entries are denied already, deny every entry inside each intermediate
# directory, and the modules and worktrees directories and their entries of
# each submodule git dir (a directory holding HEAD), recursing into its modules,
# so none can be renamed, replaced, removed, or created, and the gitfile of the
# checkout its core.worktree names. Uses cmd_start's sandbox_args.
deny_module_entries() {
  local d checkout
  [ -d "$1" ] && [ ! -L "$1" ] || return 0
  for d in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    if [ -f "$d/HEAD" ]; then
      sandbox_args+=(--deny-write-regex "^$(regex_quote "$d")/(modules|worktrees)(/[^/]+)?\$")
      checkout=$(git config -f "$d/config" --get core.worktree 2>/dev/null) && deny_gitfile "$d" "$checkout"
      deny_module_entries "$d/modules"
    else
      sandbox_args+=(--deny-write-regex "^$(regex_quote "$d")/[^/]+\$")
      deny_module_entries "$d"
    fi
  done
}

# render_helm <checkout>: build the helm afresh from the checkout's tracked
# Privateer sources, as the header describes; fails on any error.
render_helm() {
  local root=$1 entry name
  rm -rf "$HELM" && mkdir -p "$HELM/.opencode/agents" "$HELM/.opencode/skills" "$HELM/bin" || return 1
  git init -q --template= "$HELM" >/dev/null 2>&1 || return 1
  cp "$RULEBOOK/AGENTS.md" "$HELM/AGENTS.md" &&
    cp "$RULEBOOK/agents/privateer.md" "$HELM/.opencode/agents/privateer.md" || return 1
  for entry in "$RULEBOOK"/skills/*/SKILL.md; do
    [ -f "$entry" ] || continue
    name=${entry%/SKILL.md}
    name=${name##*/}
    mkdir -p "$HELM/.opencode/skills/$name" && cp "$entry" "$HELM/.opencode/skills/$name/SKILL.md" || return 1
  done
  for name in plugins commands; do
    if [ -d "$root/.opencode/$name" ]; then
      cp -R "$root/.opencode/$name" "$HELM/.opencode/$name" || return 1
    fi
  done
  for entry in "$root"/bin/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    case "$name" in
      *.sh)
        if [ -f "$entry" ] && [ -x "$entry" ]; then
          printf '#!/bin/sh\nexec %s "$@"\n' "$(shell_quote "$entry")" > "$HELM/bin/$name" &&
            chmod 755 "$HELM/bin/$name" || return 1
          continue
        fi
        ;;
    esac
    ln -s "$entry" "$HELM/bin/$name" || return 1
  done
  printf 'node_modules\npackage.json\npackage-lock.json\nbun.lock\n.gitignore' > "$HELM/.opencode/.gitignore"
}

cmd_start() {
  local line sailor model check provider config socket socket_path primary port
  local name value launch tmp_real home_real root_real egress_real root_git projects_real git_meta pool_real wt_git wt_gitfile helm_real modules_dir
  local anchor anchor_start records
  local -a env_args session_env sandbox_args
  env_args=()
  session_env=()
  sandbox_args=()
  [ "$#" -eq 0 ] || usage
  active || refuse "config/privateer is absent; this launcher starts only a Privateer home"
  if ! check=$(cmd_check); then
    printf 'fm-privateer: refused: the quarantine is not satisfied:\n%s\n' "$check" >&2
    exit 1
  fi
  line=$(first_mate_line)
  [ -n "$line" ] || refuse "config/privateer names no first mate; write one line <sailor>/<model> naming the sailor and model the first mate runs on"
  sailor=${line%%/*}
  model=${line#*/}
  [ -f "$RULEBOOK/AGENTS.md" ] && [ -f "$RULEBOOK/agents/privateer.md" ] ||
    refuse "the checkout at $FM_ROOT carries no Privateer rulebook (docs/privateer/AGENTS.md and docs/privateer/agents/privateer.md); update the checkout first"
  command -v tmux >/dev/null 2>&1 || refuse "tmux is required to run the Privateer session"
  command -v python3 >/dev/null 2>&1 || refuse "python3 is required to run the Privateer egress proxy and record writer"
  "$SCRIPT_DIR/fm-sandbox-exec.sh" available || refuse "the Privateer sandbox needs sandbox-exec, which cannot run on this machine"
  primary=opencode
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_PRIVATEER_PRIMARY:-}" ]; then
    primary=$FM_PRIVATEER_PRIMARY
  else
    command -v opencode >/dev/null 2>&1 || refuse "opencode is not on PATH"
  fi
  socket=$(socket_name)
  ! session_running "$socket" || refuse "the Privateer session is already running; attach to it, or stop it first"
  if ! check=$(FM_CONFIG_OVERRIDE="$CONFIG" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-sailor.sh" check "$sailor" "$model" 2>&1); then
    refuse "the first mate's sailor cannot take the session: ${check#refused: }"
  fi
  provider=$(FM_CONFIG_OVERRIDE="$CONFIG" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-sailor.sh" provider-json "$sailor" "$model") ||
    die "the first mate's OpenCode provider entry could not be built"
  config=$(jq -cn --argjson provider "$provider" --arg model "$sailor/$model" \
    '{autoupdate: false, share: "disabled", default_agent: "privateer", model: $model, permission: {"*": "allow"}, provider: $provider}') ||
    die "the first mate's OpenCode configuration could not be composed"
  mkdir -p "$OPENCODE_ROOT/config" "$OPENCODE_ROOT/data" "$OPENCODE_ROOT/state" "$OPENCODE_ROOT/cache" "$POOL" ||
    die "cannot create $OPENCODE_ROOT"
  # The allowlist: the launcher's own values, captured once, and nothing else.
  for name in HOME PATH USER LOGNAME SHELL TERM TERMINFO TERMINFO_DIRS COLORTERM LANG LC_ALL LC_CTYPE TMPDIR TMP TEMP TMUX_TMPDIR; do
    [ -n "${!name+x}" ] || continue
    value=${!name}
    env_args+=("$name=$value")
  done
  # zsh writes a here-document under $TMPPREFIX (/tmp/zsh* by default), which
  # the sandbox denies, so a zsh captain's slash commands would fail; point it
  # into the temporary directory the sandbox allows.
  tmp_real=$(cd "${TMPDIR:-/tmp}" && pwd -P) || die "cannot resolve ${TMPDIR:-/tmp}"
  env_args+=("TMPPREFIX=$tmp_real/zsh")
  home_real=$(cd "$FM_HOME" && pwd -P) || die "cannot resolve $FM_HOME"
  env_args+=("FM_HOME=$home_real")
  root_real=$(cd "$FM_ROOT" && pwd -P) || die "cannot resolve $FM_ROOT"
  render_helm "$root_real" || refuse "the helm could not be rendered at $HELM from $RULEBOOK; nothing was started"
  helm_real=$(cd "$HELM" && pwd -P) || die "cannot resolve $HELM"
  port=$(start_egress_proxy) ||
    refuse "the Privateer egress proxy could not bind a loopback port; nothing was started"
  egress_real=$(cd "$EGRESS" && pwd -P) || die "cannot resolve $EGRESS"
  pool_real=$(cd "$POOL" && pwd -P) || die "cannot resolve $POOL"
  session_env=("${env_args[@]}")
  while IFS= read -r line; do
    [ -z "$line" ] || session_env+=("$line")
  done < <(cmd_launch_env)
  # The sandbox holds the whole tmux server, so every pane, the first mate, its
  # workers, and every command any of them starts inherit it: writes to this
  # home but never its egress record, this checkout's OpenCode scratch, the
  # worktree pool, the per-task temp roots, and the server's own socket;
  # connections to the egress proxy and that socket only; and signals only
  # within the sandbox, so nothing inside can stop the proxy.
  socket_path=$(tmux_socket_path "$socket")
  [ -d "${socket_path%/*}" ] || mkdir -m 700 "${socket_path%/*}" 2>/dev/null || true
  sandbox_args=(run --write "$home_real" --deny-write "$egress_real" --write-prefix /tmp/fm- --write-prefix "$socket_path"
    --write /dev/ptmx --unix-socket "$socket_path" --connect "http://127.0.0.1:$port" --confine-signals)
  # Nothing inside may write, at its known paths, what runs outside the
  # sandbox: this home's config and scripts, or any Git config or hook of this
  # checkout, of a clone under projects/, or of a worker's worktree.
  sandbox_args+=(--deny-write "$home_real/config" --deny-write "$home_real/bin")
  # The grant ledger widens a worker's permissions at its next launch, so only
  # the captain's own shell outside the session writes it.
  sandbox_args+=(--deny-write "$home_real/state/permission-grants.jsonl")
  # The task records steer relaunch, landing, and cleanup, so only the record
  # writer outside the session writes them, for the first mate's own processes;
  # everything inside may reach its socket but never replace it.
  records=$(records_socket)
  sandbox_args+=(--deny-write-regex "^$(regex_quote "$home_real/state")/[^/]+\\.meta\$"
    --unix-socket "$records" --deny-write "$records")
  # The helm is the first mate's whole instruction surface, so nothing inside
  # may write it or move aside any directory that leads to it.
  sandbox_args+=(--deny-write "$helm_real")
  deny_entries "$helm_real"
  # The proxy re-reads the egress allowlist by path, so no directory leading
  # to it may be moved aside, rewritten, and moved back either.
  deny_entries "$egress_real"
  # The directory entries leading to the top-level git dir of the checkout and
  # of each clone are denied too, and so is every entry inside it that leads to
  # a Git config or hooks: its modules directory and everything leading to a
  # submodule's git dir, which nothing inside creates, and its worktrees
  # directory, which the session's first pool worktree may create but nothing
  # inside may move, remove, or replace with a symlink; so none of them can be
  # moved aside, written, and moved back. Nor can a commondir be written into
  # that git dir or a submodule's, which would point Git at another directory's
  # config and hooks; a linked worktree's is left to the outside rule below,
  # because a pool worktree writes its own.
  git_meta='($|/(modules(/[^/]+)?$|(modules/.+/)?commondir$|(worktrees/[^/]+/|modules/.+/)?(hooks(/|$)|config)))'
  root_git=$(cd "$FM_ROOT" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || root_git=
  if [ -n "$root_git" ]; then
    sandbox_args+=(--deny-write-regex "^$(regex_quote "$root_git")$git_meta"
      --deny-move-regex "^$(regex_quote "$root_git")/worktrees\$")
    deny_entries "$root_git"
    deny_module_entries "$root_git/modules"
  fi
  deny_entries "$root_real/.git"
  if projects_real=$(cd "$PROJECTS" 2>/dev/null && pwd -P); then
    sandbox_args+=(--deny-write-regex "^$(regex_quote "$projects_real")/[^/]+\$"
      --deny-write-regex "^$(regex_quote "$projects_real")/[^/]+/(.+/)?\.git$git_meta"
      --deny-move-regex "^$(regex_quote "$projects_real")/[^/]+/(.+/)?\.git/worktrees\$")
    deny_entries "$projects_real"
    for modules_dir in "$projects_real"/*/.git/modules; do
      deny_module_entries "$modules_dir"
    done
  fi
  # A linked worktree that lives outside this home's pool is used outside the
  # session, so its git dir can be neither redirected nor swapped, nor its
  # gitfile rewritten, and neither can the git dirs of its submodules or their
  # config, hooks, or commondir; the pool's own worktrees are created inside the
  # session and used only there.
  for wt_git in "$root_git"/worktrees/*/ "${projects_real:-/nonexistent}"/*/.git/worktrees/*/; do
    [ -d "$wt_git" ] || continue
    wt_git=${wt_git%/}
    wt_gitfile=$(cat "$wt_git/gitdir" 2>/dev/null)
    case "$wt_gitfile" in
      "$pool_real"/*) ;;
      *)
        sandbox_args+=(--deny-write-regex "^$(regex_quote "$wt_git")(\$|/(commondir|gitdir)\$|/modules(\$|/[^/]+\$|/.+/(hooks(/|\$)|config|commondir\$)))")
        [ -z "$wt_gitfile" ] || deny_gitfile "$wt_git" "${wt_gitfile%/*}"
        deny_module_entries "$wt_git/modules"
        ;;
    esac
  done
  # A checkout inside the home is writable, so its scripts, which the captain
  # runs outside the session, and everything its first mate's OpenCode loads
  # from it are taken back: instructions, docs, config, skills, agents,
  # commands, modes, plugins, and tools, with the .opencode and .claude
  # entries above them and the .claude/skills link itself, which --deny-write
  # would resolve; the rest of .opencode stays OpenCode's scratch.
  case "$root_real" in
    "$home_real" | "$home_real"/*)
      for name in AGENTS.md CLAUDE.md CONTEXT.md opencode.json opencode.jsonc tui.json tui.jsonc .agents docs \
        .opencode/{opencode,tui}.{json,jsonc} .opencode/{agent,command,mode,plugin,skill,tool}{,s}; do
        sandbox_args+=(--deny-write "$root_real/$name")
      done
      sandbox_args+=(--deny-write "$root_real/bin")
      sandbox_args+=(--deny-write-regex "^$(regex_quote "$root_real/.opencode")\$"
        --deny-write-regex "^$(regex_quote "$root_real/.claude")(/skills)?\$")
      ;;
    *) sandbox_args+=(--write "$root_real/.opencode") ;;
  esac
  # The primary's own boundary: the pane shell tmux starts may have read the
  # captain's profile, so the environment is cleared again here, keeping only
  # the TMUX names the server itself set for this pane.
  # shellcheck disable=SC2016
  launch='/usr/bin/env -i ${TMUX+"TMUX=$TMUX"} ${TMUX_PANE+"TMUX_PANE=$TMUX_PANE"}'
  for value in "${session_env[@]}" "OPENCODE_CONFIG_CONTENT=$config" "FM_ROOT_OVERRIDE=$root_real" \
    OPENCODE_DISABLE_EXTERNAL_SKILLS=1 OPENCODE_DISABLE_CLAUDE_CODE=1; do
    launch="$launch $(shell_quote "$value")"
  done
  launch="$launch $(shell_quote "$primary") --agent privateer"
  if ! /usr/bin/env -i "${session_env[@]}" "$SCRIPT_DIR/fm-sandbox-exec.sh" "${sandbox_args[@]}" -- \
    tmux -L "$socket" new-session -d -s "$SESSION" -n firstmate -c "$helm_real" -- "$launch"; then
    stop_egress_proxy
    refuse "tmux could not start the Privateer session"
  fi
  # Never copy a variable from a client that attaches later.
  tmux -L "$socket" set-option -g update-environment '' >/dev/null 2>&1 || true
  # The first mate's pane process, taken before any worker can exist, is the
  # one lineage the record writer serves; its start time rules out a reused pid.
  anchor=$(tmux -L "$socket" list-panes -t "$SESSION:firstmate" -F '#{pane_pid}' 2>/dev/null | head -1)
  anchor_start=
  case "$anchor" in
    '' | *[!0-9]*) ;;
    *) anchor_start=$(LC_ALL=C ps -o lstart= -p "$anchor" 2>/dev/null) || anchor_start= ;;
  esac
  if [ -z "$anchor_start" ] || ! start_record_writer "$anchor" "$anchor_start"; then
    tmux -L "$socket" kill-server 2>/dev/null || true
    stop_egress_proxy
    refuse "the Privateer record writer could not start for the first mate's process; nothing was left running"
  fi
  echo "privateer: started session $SESSION on tmux socket $socket (first mate $sailor/$model, egress proxy 127.0.0.1:$port); attach with: FM_HOME=$(shell_quote "$home_real") $(shell_quote "$SCRIPT_DIR/fm-privateer.sh") attach"
}

cmd_attach() {
  local socket
  active || refuse "config/privateer is absent; this launcher attaches only to a Privateer home"
  command -v tmux >/dev/null 2>&1 || refuse "tmux is required"
  socket=$(socket_name)
  session_running "$socket" || refuse "the Privateer session is not running; start it first"
  exec tmux -L "$socket" attach-session -t "$SESSION"
}

refuse_work_in_flight() {
  local meta
  local -a live
  live=()
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    meta=${meta##*/}
    live+=("${meta%.meta}")
  done
  if [ "${#live[@]}" -gt 0 ]; then
    refuse "work is in flight (${live[*]}); finish or clean it up before stopping the session"
  fi
}

# first_mate_reads <target> <deadline> <poll> <state> <reads>: 0 once the
# first mate's pane reads <state> (busy or idle) <reads> times in a row, 1 at
# the deadline (in SECONDS). Needs bin/fm-tmux-lib.sh and the stow_session tmux
# wrapper.
first_mate_reads() {
  local target=$1 deadline=$2 poll=$3 state=$4 reads=$5 streak=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(fm_pane_busy_state "$target" opencode)" = "$state" ]; then
      streak=$((streak + 1))
      [ "$streak" -lt "$reads" ] || return 0
    else
      streak=0
    fi
    sleep "$poll"
  done
  return 1
}

# stow_session <socket>: /stow delivered to the first mate's own pane and its
# turn waited out, as the header describes; refuses (exit 1) otherwise.
stow_session() {
  local socket=$1 wait=${FM_PRIVATEER_STOW_WAIT:-600} poll=${FM_PRIVATEER_STOW_POLL:-2} status
  case "$wait" in '' | *[!0-9]*) die "FM_PRIVATEER_STOW_WAIT must be a whole number of seconds: $wait" ;; esac
  case "$poll" in '' | . | *[!0-9.]* | *.*.*) die "FM_PRIVATEER_STOW_POLL must be a number of seconds: $poll" ;; esac
  (
    # shellcheck source=bin/fm-tmux-lib.sh
    . "$SCRIPT_DIR/fm-tmux-lib.sh"
    # Every pane read and keystroke the library makes goes to this home's server.
    # shellcheck disable=SC2329
    tmux() { command tmux -L "$socket" "$@"; }
    target="$SESSION:firstmate"
    deadline=$((SECONDS + wait))
    first_mate_reads "$target" "$deadline" "$poll" idle "$STOW_IDLE_READS" || exit 3
    [ "$(fm_tmux_composer_state "$target")" = empty ] || exit 4
    [ "$(fm_tmux_submit_core "$target" /stow 3 0.5 0.3)" = empty ] || exit 5
    first_mate_reads "$target" "$deadline" "$poll" busy 1 || exit 7
    first_mate_reads "$target" "$deadline" "$poll" idle "$STOW_IDLE_READS" || exit 6
  )
  status=$?
  case "$status" in
    0) return 0 ;;
    3) refuse "the first mate stayed busy for ${wait}s, so /stow was not delivered; the session is still running" ;;
    4) refuse "the first mate's input line holds text or cannot be read, so /stow was not typed; the session is still running" ;;
    5) refuse "the first mate did not take /stow; the session is still running" ;;
    7) refuse "the first mate's /stow did not start within ${wait}s; the session is still running" ;;
    6) refuse "the first mate's /stow did not finish within ${wait}s; the session is still running" ;;
    *) refuse "the stow could not be run; the session is still running" ;;
  esac
}

cmd_stop() {  # [--stow]
  local socket stow=0 where
  [ "${1:-}" != --stow ] || stow=1
  active || refuse "config/privateer is absent; this launcher stops only a Privateer home"
  command -v tmux >/dev/null 2>&1 || refuse "tmux is required"
  socket=$(socket_name)
  where=" on tmux socket $socket"
  [ "$stow" -eq 0 ] || where=
  if ! session_running "$socket"; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
    [ -e "$EGRESS/pid" ] || [ -e "$EGRESS/records.pid" ] ||
      refuse "the Privateer session is not running, and no egress proxy or record writer was left behind"
    stop_egress_proxy
    stop_record_writer
    echo "privateer: the session$where had already ended; stopped its watcher, its egress proxy, and its record writer"
    return 0
  fi
  refuse_work_in_flight
  if [ "$stow" -eq 1 ]; then
    stow_session "$socket"
    refuse_work_in_flight
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  tmux -L "$socket" kill-server 2>/dev/null || refuse "the Privateer tmux server could not be stopped"
  stop_egress_proxy
  stop_record_writer
  if [ "$stow" -eq 1 ]; then
    echo "privateer: the first mate stowed; stopped session $SESSION"
  else
    echo "privateer: stopped session $SESSION$where"
  fi
}

cmd_project() {  # [<name> | --clear]
  local name target tmp
  active || refuse "config/privateer is absent; the active project is set only in a Privateer home"
  if [ "$#" -eq 0 ]; then
    fm_privateer_projects_view "$CONFIG" "${FM_DATA_OVERRIDE:-$FM_HOME/data}" "$PROJECTS" "$SCRIPT_DIR"
    return 0
  fi
  if fm_privateer_inside_session "$FM_HOME"; then
    refuse "the session cannot write config/, so the active project is set by the captain outside it: run bin/fm-privateer.sh project <name> from a terminal outside the session"
  fi
  target="$CONFIG/active-project"
  if [ "$1" = --clear ]; then
    rm -f "$target" || refuse "config/active-project could not be removed"
    echo "privateer: no active project"
    return 0
  fi
  name=$1
  case "$name" in
    --* | */* | .* | -* | *[!A-Za-z0-9._-]*) refuse "'$name' is not a project name; give the name of a project under projects/" ;;
  esac
  FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-$FM_HOME/data}" "$SCRIPT_DIR/fm-project-mode.sh" --registered "$name" ||
    refuse "'$name' is not registered in data/projects.md"
  [ -d "$PROJECTS/$name" ] || refuse "'$name' has no clone under projects/"
  tmp="$target.tmp.$$"
  { printf '%s\n' "$name" > "$tmp" && mv -f "$tmp" "$target"; } || {
    rm -f "$tmp"
    refuse "config/active-project could not be written"
  }
  echo "privateer: the active project is now $name"
}

cmd_reload() {
  local old new
  active || refuse "config/privateer is absent; this launcher reloads only a Privateer home"
  fm_privateer_inside_session "$FM_HOME" &&
    refuse "reload is the captain's command and runs outside the Privateer session"
  proxy_running || refuse "the Privateer egress proxy is not running; start the session with fm-privateer.sh start"
  old=$(cat "$EGRESS/allow" 2>/dev/null) || old=
  write_allow_file
  new=$(cat "$EGRESS/allow")
  comm -13 <(printf '%s\n' "$old" | LC_ALL=C sort -u) <(printf '%s\n' "$new" | LC_ALL=C sort -u) | sed '/^$/d; s/^/privateer: added /'
  comm -23 <(printf '%s\n' "$old" | LC_ALL=C sort -u) <(printf '%s\n' "$new" | LC_ALL=C sort -u) | sed '/^$/d; s/^/privateer: removed /'
  [ "$old" != "$new" ] || echo "privateer: the egress allowlist is unchanged"
  echo "privateer: reloaded the egress allowlist"
}

[ "$#" -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  check)
    [ "$#" -eq 0 ] || usage
    cmd_check
    ;;
  inside)
    [ "$#" -eq 0 ] || usage
    active || exit 3
    fm_privateer_inside_session "$FM_HOME" ||
      refuse "this is a sealed Privateer home, and this process runs outside its session, so it may act on nothing here; stop, and tell the captain to attach with bin/fm-privateer.sh attach and give the ask to the Privateer first mate there; never drive the Privateer session from outside"
    ;;
  launch-env)
    [ "$#" -eq 0 ] || usage
    fm_privateer_inside_session "$FM_HOME" ||
      refuse "launch-env runs only inside the Privateer session, whose sandbox every worker inherits; $FM_PRIVATEER_SEALED_REFUSAL"
    cmd_launch_env
    ;;
  start) cmd_start "$@" ;;
  attach)
    [ "$#" -eq 0 ] || usage
    cmd_attach
    ;;
  stop)
    case "$*" in
      '' | --stow) ;;
      *) usage ;;
    esac
    cmd_stop "$@"
    ;;
  project)
    [ "$#" -le 1 ] || usage
    cmd_project "$@"
    ;;
  reload)
    [ "$#" -eq 0 ] || usage
    cmd_reload
    ;;
  -h | --help)
    sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    ;;
  *) usage ;;
esac
