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
# (exit 1) unless it runs inside this home's Privateer session (its TMUX names
# the session's socket) and the session's egress proxy runs: XDG_CONFIG_HOME,
# XDG_DATA_HOME, XDG_STATE_HOME, and XDG_CACHE_HOME under
# state/privateer/opencode/, so the captain's own OpenCode config, logins,
# sessions, and cache are invisible; OPENCODE_DISABLE_AUTOUPDATE=1; HTTP_PROXY,
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
# starts a dedicated tmux server (socket fm-privateer-<home hash>) inside
# bin/fm-sandbox-exec.sh, whose session `privateer` runs the OpenCode primary
# in window `firstmate`, in this checkout with FM_HOME set to this home. The
# server, and again the primary itself, start from an empty environment plus
# exactly: HOME PATH USER LOGNAME SHELL TERM COLORTERM LANG LC_ALL LC_CTYPE
# TMPDIR TMP TEMP TMUX_TMPDIR as the launcher saw them, FM_HOME, and the
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
# write only to this home, this checkout's .opencode/ scratch, the worktree
# pool under ~/.treehouse, firstmate's per-task temp roots under /tmp/fm-*, and
# the server's own socket, and never to this home's egress directory, config/,
# or bin/, or to the Git config or hooks of this checkout, of any clone under
# projects/, or of any worktree of those (its git dir under
# .git/worktrees/<name>/), so nothing inside can plant what later runs outside
# the sandbox; a new clone under projects/ is therefore made outside the
# session. It may connect
# only to the egress proxy, the DNS resolver, and that socket; and may signal
# only processes inside the same sandbox, so it can neither stop the proxy nor
# rewrite its record. A client that ignores the proxy variables therefore
# reaches nothing remote at all. macOS cannot apply a second sandbox inside
# the first, so a Privateer worker runs in this session sandbox rather than a
# per-task sailor sandbox. One session sandbox therefore covers the first mate
# and every worker alike, so a worker can still write what the first mate's own
# fm-spawn and fm-permission-grant write from inside it: the task records
# state/<id>.meta and the grant ledger state/permission-grants.jsonl. As
# bin/fm-sandbox-exec.sh states, the sandbox is not a boundary against
# same-user system services that start programs outside it.
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
FLAG="$CONFIG/privateer"
DISPATCH="$CONFIG/crew-dispatch.json"
SESSION=privateer
OPENCODE_ROOT="$STATE/privateer/opencode"
EGRESS="$STATE/privateer/egress"
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
  printf 'HTTP_PROXY=%s\nHTTPS_PROXY=%s\nhttp_proxy=%s\nhttps_proxy=%s\n' "$proxy" "$proxy" "$proxy" "$proxy"
  printf "GIT_SSH_COMMAND=ssh -o ProxyCommand='/usr/bin/nc -X connect -x 127.0.0.1:%s %%h %%p'\n" "$port"
}

# socket_name: one tmux server per Privateer home, keyed by the home's path.
socket_name() {
  local root hash
  root=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || root=$FM_HOME
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | cut -c1-12)
  else
    hash=$(printf '%s' "$root" | sha256sum | cut -c1-12)
  fi
  printf 'fm-privateer-%s\n' "$hash"
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
  case "${1%:*}" in
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

cmd_start() {
  local line sailor model check provider config socket socket_path primary port
  local name value launch home_real root_real egress_real root_git projects_real
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
  mkdir -p "$OPENCODE_ROOT/config" "$OPENCODE_ROOT/data" "$OPENCODE_ROOT/state" "$OPENCODE_ROOT/cache" ||
    die "cannot create $OPENCODE_ROOT"
  # The allowlist: the launcher's own values, captured once, and nothing else.
  for name in HOME PATH USER LOGNAME SHELL TERM COLORTERM LANG LC_ALL LC_CTYPE TMPDIR TMP TEMP TMUX_TMPDIR; do
    [ -n "${!name+x}" ] || continue
    value=${!name}
    env_args+=("$name=$value")
  done
  home_real=$(cd "$FM_HOME" && pwd -P) || die "cannot resolve $FM_HOME"
  env_args+=("FM_HOME=$home_real")
  port=$(start_egress_proxy) ||
    refuse "the Privateer egress proxy could not bind a loopback port; nothing was started"
  egress_real=$(cd "$EGRESS" && pwd -P) || die "cannot resolve $EGRESS"
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
  [ -z "${HOME:-}" ] || sandbox_args+=(--write "$HOME/.treehouse")
  # Nothing inside may plant what runs outside the sandbox: this home's config
  # and scripts, or any Git config or hook of this checkout, of a clone under
  # projects/, or of a worker's worktree.
  sandbox_args+=(--deny-write "$home_real/config" --deny-write "$home_real/bin")
  root_git=$(cd "$FM_ROOT" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || root_git=
  [ -z "$root_git" ] || sandbox_args+=(--deny-write-regex "^$(regex_quote "$root_git")/(worktrees/[^/]+/)?(hooks(/|\$)|config)")
  if projects_real=$(cd "$PROJECTS" 2>/dev/null && pwd -P); then
    sandbox_args+=(--deny-write-regex "^$(regex_quote "$projects_real")/[^/]+/\.git/(worktrees/[^/]+/)?(hooks(/|\$)|config)")
  fi
  case "$root_real" in
    "$home_real" | "$home_real"/*) ;;
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
    socket=$(socket_name)
    tmux_socket=${TMUX:-}
    tmux_socket=${tmux_socket%%,*}
    [ "${tmux_socket##*/}" = "$socket" ] ||
      refuse "launch-env runs only inside the Privateer session (tmux socket $socket), whose sandbox every worker inherits"
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
