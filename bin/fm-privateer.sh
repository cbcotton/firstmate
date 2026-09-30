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
#   fm-privateer.sh launch-env
#   fm-privateer.sh start
#   fm-privateer.sh attach
#   fm-privateer.sh stop
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
# for https, 80 for http, 22 for ssh).
#
# start refuses without config/privateer, on any check violation, without a
# first-mate line in config/privateer, and while the session already runs. It
# probes the first mate's sailor with bin/fm-sailor.sh check, starts the egress
# proxy, refusing and starting nothing else if the proxy cannot bind, then
# starts a dedicated tmux server (the socket bin/fm-privateer-lib.sh names) inside
# bin/fm-sandbox-exec.sh, whose session `privateer` runs the OpenCode primary
# in window `firstmate`, in this checkout with FM_HOME set to this home. The
# server, and again the primary itself, start from an empty environment plus
# exactly: HOME PATH USER LOGNAME SHELL TERM TERMINFO TERMINFO_DIRS COLORTERM LANG
# LC_ALL LC_CTYPE TMPDIR TMP TEMP TMUX_TMPDIR as the launcher saw them (TERMINFO
# and TERMINFO_DIRS only name where terminal descriptions are read from), FM_HOME, and the
# launch-env assignments above; the primary adds OPENCODE_CONFIG_CONTENT, which
# pins the model to the first mate's sailor as the only provider, allows every
# tool as a secondmate primary is allowed, turns auto-update off, and disables
# sharing. The primary also keeps the TMUX and TMUX_PANE names its own server
# sets. No ANTHROPIC_*, CLAUDE_*, or CLAUDECODE variable can reach the tree,
# because nothing outside that list does; the server copies no variable from a
# later attaching client either. A worker pane's login shell may still read
# the captain's shell profile, so bin/fm-spawn.sh clears the environment again
# at each worker's command boundary.
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
# directory, config/, or bin/; when this checkout is inside this home, any
# path in it the first mate's OpenCode loads from: its AGENTS.md, CLAUDE.md,
# CONTEXT.md, opencode.json(c), tui.json(c), .agents/, docs/, the .claude
# entry and its skills link, the .opencode entry, and, under .opencode/, the
# opencode.json(c) and tui.json(c) files and the agent(s), command(s),
# mode(s), plugin(s), skill(s), and tool(s) directories, so no worker can
# rewrite the first mate's instructions, docs, config, skills, agents,
# commands, modes, plugins, or tools there; the Git config or hooks of this
# checkout, of any clone under projects/, or of any linked worktree or
# submodule of those
# (git dirs under .git/worktrees/<name>/ and .git/modules/<path>/); the git
# dir, commondir, or gitdir of a linked worktree that lives outside this
# home's pool, so none can be redirected or relabeled as a pool worktree;
# any .git entry inside a clone, or the checkout's own .git; or the projects
# directory, any clone's directory, or any directory between this home and the
# checkout's git dir, so none of those directory entries can be moved aside,
# changed, and moved back; of the git dirs, only the top-level git dir of the
# checkout and of each clone has its entry denied, and the directory entries
# inside it are not all covered (see the remaining limits below).
# It may connect only to the egress proxy, the DNS resolver, and that socket,
# so a client that ignores the proxy variables reaches nothing remote at all,
# and may signal only processes inside the same sandbox, so it can neither
# stop the proxy nor rewrite its record. Process information stays readable,
# as bin/fm-sandbox-exec.sh states, so the first mate finds its own OpenCode
# process and owns this home's session lock, while a plain shell started in
# the session finds no harness and stays read-only.
#
# Remaining limits, by design:
#   - macOS cannot apply a second sandbox inside the first, so one session
#     sandbox covers the first mate and every worker alike, in place of a
#     per-task sailor sandbox;
#   - a worker can therefore still write what the first mate's own fm-spawn
#     and fm-permission-grant write from inside it: the task records
#     state/<id>.meta and the grant ledger state/permission-grants.jsonl;
#   - the per-task temp roots under /tmp/fm-*, the user's own temporary
#     directory ($TMPDIR), and the here-document files stock macOS Bash
#     writes as /var/tmp/sh-thd* are namespaces shared by every home on this
#     machine;
#   - clones under projects/ are added, moved, and removed outside the
#     session, and a worktree the session creates in its own pool is meant
#     for use only inside it;
#   - the directory entries denied are the projects directory, each clone's
#     directory, the top-level git dir of the checkout and of each clone, and
#     the directories between this home and the checkout's git dir; the
#     worktrees and modules directories inside a git dir, a submodule's own
#     git dir (modules/<path>), the intermediate directories under modules,
#     and a symlink placed over any of them can still be moved aside and back
#     from inside the session, so a linked worktree's or submodule's Git config
#     or hooks can be planted that way; closing that class is follow-up work;
#   - OpenCode also loads plugins and configuration from its own directories
#     under state/privateer/opencode/, which stay writable, so a worker can
#     still add one there that the first mate loads at its next start; and a
#     checkout nested below this home, rather than being it, keeps its own
#     bin/ writable;
#   - as bin/fm-sandbox-exec.sh states, the sandbox is not a boundary against
#     same-user system services that start programs outside it.
#
# attach attaches this terminal to the running session. stop refuses while any
# task record (state/<id>.meta) exists, because a running worker's copy would
# be orphaned, and otherwise stops this home's watcher and the whole server,
# and then the egress proxy. When the session has already ended, stop still
# stops the watcher and any egress proxy left behind and says so, and refuses
# only when there was no proxy to stop.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, and
# FM_PROJECTS_OVERRIDE resolve the home exactly as the other bin/ scripts do. With FM_TEST_SEAM=1, FM_PRIVATEER_PRIMARY names a command to launch in
# place of opencode, so a test can prove the launch environment with a stub.
#
# Exit status: 0 success, 1 refused (a violation, a missing prerequisite, or
# work in flight), 2 usage or configuration error.
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
SESSION=privateer
OPENCODE_ROOT="$STATE/privateer/opencode"
EGRESS="$STATE/privateer/egress"
POOL="$STATE/privateer/treehouse"
FORBIDDEN_NAME_RE='^(ANTHROPIC_[A-Za-z0-9_]*|CLAUDE_[A-Za-z0-9_]*|CLAUDECODE)$'

usage() {
  echo "usage: fm-privateer.sh check | launch-env | start | attach | stop" >&2
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
  printf '%s/tmux-%s/%s\n' "${TMUX_TMPDIR:-/tmp}" "$(id -u)" "$1"
}

session_running() {  # <socket-name>
  tmux -L "$1" has-session -t "$SESSION" 2>/dev/null
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

# stop_egress_proxy: stop the proxy this home last started, if it still runs.
stop_egress_proxy() {
  local pid
  pid=$(cat "$EGRESS/pid" 2>/dev/null) || pid=
  case "$pid" in
    '' | *[!0-9]*) ;;
    *)
      case "$(ps -p "$pid" -o command= 2>/dev/null)" in
        *fm-privateer-proxy.py*) kill "$pid" 2>/dev/null || true ;;
      esac
      ;;
  esac
  rm -f "$EGRESS/port" "$EGRESS/pid"
}

# start_egress_proxy: the proxy as its own process, outside the session and its
# sandbox, started with cmd_start's env_args; prints its port once it has
# bound, or fails.
start_egress_proxy() {
  local dest port pid
  local -a allow
  allow=()
  while IFS= read -r dest; do
    [ -z "$dest" ] || allow+=("$dest")
  done < <(egress_allowlist)
  mkdir -p "$EGRESS" || die "cannot create $EGRESS"
  stop_egress_proxy
  /usr/bin/env -i "${env_args[@]}" nohup python3 "$SCRIPT_DIR/fm-privateer-proxy.py" "$EGRESS/port" "$EGRESS/log" \
    "${allow[@]+"${allow[@]}"}" </dev/null >>"$EGRESS/proxy.err" 2>&1 &
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

cmd_start() {
  local line sailor model check provider config socket socket_path primary port
  local name value launch home_real root_real egress_real root_git projects_real git_meta pool_real wt_git
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
  command -v tmux >/dev/null 2>&1 || refuse "tmux is required to run the Privateer session"
  command -v python3 >/dev/null 2>&1 || refuse "python3 is required to run the Privateer egress proxy"
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
    '{autoupdate: false, share: "disabled", model: $model, permission: {"*": "allow"}, provider: $provider}') ||
    die "the first mate's OpenCode configuration could not be composed"
  mkdir -p "$OPENCODE_ROOT/config" "$OPENCODE_ROOT/data" "$OPENCODE_ROOT/state" "$OPENCODE_ROOT/cache" "$POOL" ||
    die "cannot create $OPENCODE_ROOT"
  # The allowlist: the launcher's own values, captured once, and nothing else.
  for name in HOME PATH USER LOGNAME SHELL TERM TERMINFO TERMINFO_DIRS COLORTERM LANG LC_ALL LC_CTYPE TMPDIR TMP TEMP TMUX_TMPDIR; do
    [ -n "${!name+x}" ] || continue
    value=${!name}
    env_args+=("$name=$value")
  done
  home_real=$(cd "$FM_HOME" && pwd -P) || die "cannot resolve $FM_HOME"
  env_args+=("FM_HOME=$home_real")
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
  root_real=$(cd "$FM_ROOT" && pwd -P) || die "cannot resolve $FM_ROOT"
  socket_path=$(tmux_socket_path "$socket")
  [ -d "${socket_path%/*}" ] || mkdir -m 700 "${socket_path%/*}" 2>/dev/null || true
  sandbox_args=(run --write "$home_real" --deny-write "$egress_real" --write-prefix /tmp/fm- --write-prefix "$socket_path"
    --write /dev/ptmx --unix-socket "$socket_path" --connect "http://127.0.0.1:$port" --confine-signals)
  # Nothing inside may write, at its known paths, what runs outside the
  # sandbox: this home's config and scripts, or any Git config or hook of this
  # checkout, of a clone under projects/, or of a worker's worktree.
  sandbox_args+=(--deny-write "$home_real/config" --deny-write "$home_real/bin")
  # The directory entries leading to the top-level git dir of the checkout and
  # of each clone are denied too, so none of them can be moved aside, written,
  # and moved back; the worktrees and modules directories inside a git dir and
  # a submodule's own git dir are not, a remaining limit the header names.
  git_meta='($|/(worktrees/[^/]+/|modules/.+/)?(hooks(/|$)|config))'
  root_git=$(cd "$FM_ROOT" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || root_git=
  if [ -n "$root_git" ]; then
    sandbox_args+=(--deny-write-regex "^$(regex_quote "$root_git")$git_meta")
    deny_entries "$root_git"
  fi
  deny_entries "$root_real/.git"
  if projects_real=$(cd "$PROJECTS" 2>/dev/null && pwd -P); then
    sandbox_args+=(--deny-write-regex "^$(regex_quote "$projects_real")/[^/]+\$"
      --deny-write-regex "^$(regex_quote "$projects_real")/[^/]+/(.+/)?\.git$git_meta")
    deny_entries "$projects_real"
  fi
  # A linked worktree that lives outside this home's pool is used outside the
  # session, so its git dir can be neither redirected nor swapped; the pool's
  # own worktrees are created inside the session and used only there.
  for wt_git in "$root_git"/worktrees/*/ "${projects_real:-/nonexistent}"/*/.git/worktrees/*/; do
    [ -d "$wt_git" ] || continue
    wt_git=${wt_git%/}
    case "$(cat "$wt_git/gitdir" 2>/dev/null)" in
      "$pool_real"/*) ;;
      *) sandbox_args+=(--deny-write-regex "^$(regex_quote "$wt_git")(\$|/(commondir|gitdir)\$)") ;;
    esac
  done
  # A checkout inside the home is writable, so everything its first mate's
  # OpenCode loads from it is taken back: instructions, docs, config, skills,
  # agents, commands, modes, plugins, and tools, with the .opencode and .claude
  # entries above them and the .claude/skills link itself, which --deny-write
  # would resolve; the rest of .opencode stays OpenCode's scratch.
  case "$root_real" in
    "$home_real" | "$home_real"/*)
      for name in AGENTS.md CLAUDE.md CONTEXT.md opencode.json opencode.jsonc tui.json tui.jsonc .agents docs \
        .opencode/{opencode,tui}.{json,jsonc} .opencode/{agent,command,mode,plugin,skill,tool}{,s}; do
        sandbox_args+=(--deny-write "$root_real/$name")
      done
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
  for value in "${session_env[@]}" "OPENCODE_CONFIG_CONTENT=$config"; do launch="$launch $(shell_quote "$value")"; done
  launch="$launch $(shell_quote "$primary")"
  if ! /usr/bin/env -i "${session_env[@]}" "$SCRIPT_DIR/fm-sandbox-exec.sh" "${sandbox_args[@]}" -- \
    tmux -L "$socket" new-session -d -s "$SESSION" -n firstmate -c "$root_real" -- "$launch"; then
    stop_egress_proxy
    refuse "tmux could not start the Privateer session"
  fi
  # Never copy a variable from a client that attaches later.
  tmux -L "$socket" set-option -g update-environment '' >/dev/null 2>&1 || true
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

cmd_stop() {
  local socket meta
  local -a live
  live=()
  active || refuse "config/privateer is absent; this launcher stops only a Privateer home"
  command -v tmux >/dev/null 2>&1 || refuse "tmux is required"
  socket=$(socket_name)
  if ! session_running "$socket"; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
    [ -e "$EGRESS/pid" ] || refuse "the Privateer session is not running, and no egress proxy was left behind"
    stop_egress_proxy
    echo "privateer: the session on tmux socket $socket had already ended; stopped its watcher and its egress proxy"
    return 0
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    meta=${meta##*/}
    live+=("${meta%.meta}")
  done
  if [ "${#live[@]}" -gt 0 ]; then
    refuse "work is in flight (${live[*]}); finish or clean it up before stopping the session"
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  tmux -L "$socket" kill-server 2>/dev/null || refuse "the Privateer tmux server could not be stopped"
  stop_egress_proxy
  echo "privateer: stopped session $SESSION on tmux socket $socket"
}

[ "$#" -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  check)
    [ "$#" -eq 0 ] || usage
    cmd_check
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
    [ "$#" -eq 0 ] || usage
    cmd_stop
    ;;
  -h | --help)
    sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    ;;
  *) usage ;;
esac
