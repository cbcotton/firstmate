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
#   fm-privateer.sh endpoint-ok <url>
#   fm-privateer.sh launch-env
#   fm-privateer.sh start [--audit-proxy <http://127.0.0.1:port>]
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
#   - config/sailor-sandbox must exist, so every sailor's egress is confined;
#   - .env must set no FMX_PAIRING_TOKEN or TYPESAFE_API_KEY (Relay and typed
#     resolution reach outside services) and no ANTHROPIC_*, CLAUDE_*, or
#     CLAUDECODE line;
#   - config/launch-env-allowlist must list no ANTHROPIC_*, CLAUDE_*, or
#     CLAUDECODE name;
#   - config/crew-dispatch.json must exist and parse, declare no sailor_fallback,
#     give every rule and default profile the opencode harness and a sailor, and
#     give every sailor a private endpoint: localhost, a loopback, RFC 1918, or
#     tailnet (100.64/10) IPv4 address, an IPv6 loopback or unique-local
#     address, or a name ending in .local or .ts.net;
#   - a non-empty config/privateer must read <sailor>/<model> with that model
#     listed for that sailor.
#
# endpoint-ok exits 0 when <url> passes the endpoint rule above and 1 otherwise.
#
# launch-env prints the OpenCode isolation assignments, one NAME=value per
# line, for bin/fm-spawn.sh to export into every Privateer worker launch:
# XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, and XDG_CACHE_HOME under
# state/privateer/opencode/, so the captain's own OpenCode config, logins,
# sessions, and cache are invisible, plus OPENCODE_DISABLE_AUTOUPDATE=1.
#
# start refuses without config/privateer, on any check violation, without a
# first-mate line in config/privateer, and while the session already runs. It
# probes the first mate's sailor with bin/fm-sailor.sh check, then starts a
# dedicated tmux server (socket fm-privateer-<home hash>) whose session
# `privateer` runs the OpenCode primary in this checkout with FM_HOME set to
# this home. The server, and again the primary itself, start from an empty
# environment plus exactly: HOME PATH USER LOGNAME SHELL TERM COLORTERM LANG
# LC_ALL LC_CTYPE TMPDIR TMP TEMP TMUX_TMPDIR as the launcher saw them; FM_HOME; the
# launch-env assignments above; and OPENCODE_CONFIG_CONTENT, which pins the
# model to the first mate's sailor as the only provider, allows every tool as a
# secondmate primary is allowed, turns auto-update off, and disables sharing.
# The primary also keeps the TMUX and TMUX_PANE names its own server sets. No
# ANTHROPIC_*, CLAUDE_*, or CLAUDECODE variable can reach the tree, because
# nothing outside that list does; the server copies no variable from a later
# attaching client either. A worker pane's login shell may still read the
# captain's shell profile, so bin/fm-spawn.sh clears the environment again at
# each worker's command boundary.
# The primary runs inside bin/fm-sandbox-exec.sh: it may write only to this
# home, this checkout's .opencode/ scratch, the worktree pool under
# ~/.treehouse, and firstmate's per-task temp roots under /tmp/fm-*; it may
# connect only to each live sailor's endpoint, the origin of this checkout and
# of every clone under projects/ (the forge, by port: the URL's port, 443 for
# https, 22 for ssh), the DNS resolver, and its own tmux server socket. A
# Seatbelt rule names only localhost or any host, so a forge on 443 leaves every
# host on 443 reachable; the configuration and environment refusals are what
# keep Anthropic out of that path, and the egress audit is what proves it.
# --audit-proxy <url> serves that audit: a loopback http proxy that the
# session's HTTP_PROXY and HTTPS_PROXY name and the sandbox may connect to, so
# the proxy records every outbound request and tunnel the primary attempts.
#
# attach attaches this terminal to the running session. stop refuses while any
# task record (state/<id>.meta) exists, because a running worker's copy would
# be orphaned, and otherwise stops this home's watcher and the whole server.
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
FORBIDDEN_NAME_RE='^(ANTHROPIC_[A-Za-z0-9_]*|CLAUDE_[A-Za-z0-9_]*|CLAUDECODE)$'

usage() {
  echo "usage: fm-privateer.sh check | endpoint-ok <url> | launch-env | start [--audit-proxy <url>] | attach | stop" >&2
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

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# url_host <url>: the host of an http(s) URL, without brackets or port; empty
# when the URL has no host.
url_host() {
  local rest=$1 hostport
  case "$rest" in
    http://* | https://*) ;;
    *) return 0 ;;
  esac
  rest=${rest#*://}
  hostport=${rest%%/*}
  hostport=${hostport##*@}
  case "$hostport" in
    \[*\]*) hostport=${hostport#[}; printf '%s\n' "${hostport%%]*}" ;;
    *) printf '%s\n' "${hostport%%:*}" ;;
  esac
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
  host=$(url_host "$1")
  [ -n "$host" ] || return 1
  private_host "$host"
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
  local out
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
    [ -e "$CONFIG/sailor-sandbox" ] || echo "config/sailor-sandbox is absent; every Privateer sailor runs inside the sandbox"
    env_file_violations
    allowlist_violations
    dispatch_violations
  )
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
  return 1
}

cmd_launch_env() {
  printf 'XDG_CONFIG_HOME=%s\n' "$OPENCODE_ROOT/config"
  printf 'XDG_DATA_HOME=%s\n' "$OPENCODE_ROOT/data"
  printf 'XDG_STATE_HOME=%s\n' "$OPENCODE_ROOT/state"
  printf 'XDG_CACHE_HOME=%s\n' "$OPENCODE_ROOT/cache"
  printf 'OPENCODE_DISABLE_AUTOUPDATE=1\n'
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

# forge_connects: one --connect value per distinct forge origin the first mate
# fetches from: this checkout and every clone under projects/.
forge_connects() {
  local repo url hostport host port
  for repo in "$FM_ROOT" "$PROJECTS"/*/; do
    [ -d "$repo" ] || continue
    url=$(git -C "$repo" remote get-url origin 2>/dev/null) || continue
    case "$url" in
      https://* | http://*)
        hostport=${url#*://}
        hostport=${hostport%%/*}
        hostport=${hostport##*@}
        [ -n "$hostport" ] || continue
        printf '%s://%s\n' "${url%%://*}" "$hostport"
        ;;
      ssh://*)
        hostport=${url#ssh://}
        hostport=${hostport%%/*}
        hostport=${hostport##*@}
        case "$hostport" in
          *:*) host=${hostport%:*}; port=${hostport##*:} ;;
          *) host=$hostport; port=22 ;;
        esac
        [ -n "$host" ] || continue
        printf '%s:%s\n' "$host" "$port"
        ;;
      *@*:* | *:*/*)
        case "$url" in
          /* | file://*) continue ;;
        esac
        host=${url%%:*}
        host=${host##*@}
        [ -n "$host" ] || continue
        printf '%s:22\n' "$host"
        ;;
    esac
  done | LC_ALL=C sort -u
}

live_sailor_endpoints() {
  jq -r '(.sailors // {}) | to_entries[] | select(.value.status == "live") | .value.endpoint' "$DISPATCH" 2>/dev/null
}

cmd_start() {
  local audit_proxy='' line sailor model check provider config socket socket_path primary
  local name value launch sandbox home_real root_real endpoint connect
  local -a env_args inner sandbox_args
  env_args=()
  inner=()
  sandbox_args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --audit-proxy)
        [ "$#" -ge 2 ] || die "--audit-proxy requires a value"
        audit_proxy=$2
        shift 2
        ;;
      *) usage ;;
    esac
  done
  active || refuse "config/privateer is absent; this launcher starts only a Privateer home"
  if ! check=$(cmd_check); then
    printf 'fm-privateer: refused: the quarantine is not satisfied:\n%s\n' "$check" >&2
    exit 1
  fi
  if [ -n "$audit_proxy" ]; then
    case "$(url_host "$audit_proxy")" in
      localhost | 127.* | ::1) ;;
      *) die "--audit-proxy must be an http URL on this machine, got '$audit_proxy'" ;;
    esac
  fi
  line=$(first_mate_line)
  [ -n "$line" ] || refuse "config/privateer names no first mate; write one line <sailor>/<model> naming the sailor and model the first mate runs on"
  sailor=${line%%/*}
  model=${line#*/}
  command -v tmux >/dev/null 2>&1 || refuse "tmux is required to run the Privateer session"
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
  while IFS= read -r line; do
    [ -z "$line" ] || env_args+=("$line")
  done < <(cmd_launch_env)
  env_args+=("OPENCODE_CONFIG_CONTENT=$config")
  if [ -n "$audit_proxy" ]; then
    env_args+=("HTTP_PROXY=$audit_proxy" "HTTPS_PROXY=$audit_proxy" "http_proxy=$audit_proxy" "https_proxy=$audit_proxy")
  fi
  # The sandbox: writes to this home, this checkout's OpenCode scratch, the
  # worktree pool, and the per-task temp roots; connections to the sailors,
  # the forges, the audit proxy, and this server's socket.
  root_real=$(cd "$FM_ROOT" && pwd -P) || die "cannot resolve $FM_ROOT"
  socket_path=$(tmux_socket_path "$socket")
  sandbox_args=(run --write "$home_real" --write-prefix /tmp/fm- --unix-socket "$socket_path")
  [ -z "${HOME:-}" ] || sandbox_args+=(--write "$HOME/.treehouse")
  case "$root_real" in
    "$home_real" | "$home_real"/*) ;;
    *) sandbox_args+=(--write "$root_real/.opencode") ;;
  esac
  while IFS= read -r endpoint; do
    [ -z "$endpoint" ] || sandbox_args+=(--connect "$endpoint")
  done < <(live_sailor_endpoints)
  while IFS= read -r connect; do
    [ -z "$connect" ] || sandbox_args+=(--connect "$connect")
  done < <(forge_connects)
  [ -z "$audit_proxy" ] || sandbox_args+=(--connect "$audit_proxy")
  sandbox=$(shell_quote "$SCRIPT_DIR/fm-sandbox-exec.sh")
  for value in "${sandbox_args[@]}"; do sandbox="$sandbox $(shell_quote "$value")"; done
  # The primary's own boundary: the pane shell tmux starts may have read the
  # captain's profile, so the environment is cleared again here, keeping only
  # the TMUX names the server itself set for this pane.
  # shellcheck disable=SC2016
  launch='/usr/bin/env -i ${TMUX+"TMUX=$TMUX"} ${TMUX_PANE+"TMUX_PANE=$TMUX_PANE"}'
  for value in "${env_args[@]}"; do launch="$launch $(shell_quote "$value")"; done
  launch="$launch $sandbox -- $(shell_quote "$primary")"
  inner=(/usr/bin/env -i "${env_args[@]}" tmux -L "$socket" new-session -d -s "$SESSION" -n firstmate -c "$root_real" -- "$launch")
  "${inner[@]}" || refuse "tmux could not start the Privateer session"
  # Never copy a variable from a client that attaches later.
  tmux -L "$socket" set-option -g update-environment '' >/dev/null 2>&1 || true
  echo "privateer: started session $SESSION on tmux socket $socket (first mate $sailor/$model); attach with: FM_HOME=$(shell_quote "$home_real") $(shell_quote "$SCRIPT_DIR/fm-privateer.sh") attach"
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
  session_running "$socket" || refuse "the Privateer session is not running"
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
  endpoint-ok)
    [ "$#" -eq 1 ] || usage
    endpoint_ok "$1"
    ;;
  launch-env)
    [ "$#" -eq 0 ] || usage
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
