#!/usr/bin/env bash
# fm-sailor.sh - named local sailors: the `sailors` map in config/crew-dispatch.json.
#
# docs/configuration.md ("Crew dispatch profiles", "Named sailors") owns the
# schema and what firstmate does with each answer. This header owns the checks:
# map and reference validation, the placeholder lock, the per-sailor capacity
# count, the endpoint probe and warm-up, the OpenCode provider fragment, and
# the status view; and the registry commands that edit the map, with their
# refusals.
#
# Usage:
#   fm-sailor.sh validate
#   fm-sailor.sh list
#   fm-sailor.sh check <sailor> <model> [--task <id>]
#   fm-sailor.sh provider-json <sailor> <model>
#   fm-sailor.sh status [--all]
#   fm-sailor.sh add <sailor> --endpoint <url> --models <id>[,<id>...]
#                    [--title <text>] [--host <text>] [--max-concurrent <n>]
#                    [--live | --placeholder]
#   fm-sailor.sh add <sailor> --from-mlx-serve <server-id> [--models <id>[,<id>...]]
#                    [--title <text>] [--host <text>] [--max-concurrent <n>]
#                    [--live | --placeholder]
#   fm-sailor.sh set <sailor> [--endpoint <url>] [--title <text>] [--host <text>]
#                    [--max-concurrent <n>] [--live | --placeholder]
#   fm-sailor.sh set-model <sailor> <model> [--replace <old>] [--first-mate]
#                    [--warm] [--dry-run]
#   fm-sailor.sh retire <sailor>
#
# validate is silent and exits 0 when config/crew-dispatch.json is absent or
# declares no sailor anywhere; otherwise it checks the `sailors` map, every
# profile's `sailor` reference (in rules, default, and sailor_fallback), and the
# `sailor_fallback` shape, and prints one reason on stdout with exit 1 when any
# is malformed. bin/fm-bootstrap.sh reports that reason as a CREW_DISPATCH
# diagnostic.
#
# list prints one line per sailor: name, status, endpoint, capacity, models.
#
# check answers "may a worker be dispatched to this sailor and model right
# now?" in this order, stopping at the first refusal:
#   1. the sailor exists and the model is listed in its `models`;
#   2. its status is `live` - a `placeholder` is never dispatched, even when
#      something answers at its address;
#   3. fewer than max_concurrent (default 1) task records in state/ carry
#      sailor=<name>, not counting --task <id>, the task being relaunched;
#   4. GET <endpoint>/models answers within FM_SAILOR_PROBE_TIMEOUT seconds
#      (default 3) with an OpenAI-style model list that includes <model>.
# It prints `ok: ...` and exits 0, or prints `refused: ...` and exits 1. When
# the model list carries a `loaded` flag, the ok line says whether the model
# is loaded or only listed.
#
# provider-json prints the compact OpenCode `provider` entry for the sailor
# with just that model, keyed by the sailor's name, for bin/fm-spawn.sh to put
# inside the OPENCODE_CONFIG_CONTENT it writes; OpenCode then addresses the
# model as <sailor>/<model>.
#
# status prints one line per live sailor, or per sailor with --all: its status,
# whether GET <endpoint>/models answers, this home's tasks on it against its
# capacity, the server's running and waiting requests when <endpoint's
# origin>/metrics exposes vLLM-style gauges (vllm:num_requests_running and
# vllm:num_requests_waiting), and each listed model as loaded, unloaded
# (listed with loaded=false), listed (the server reports no loaded flag), or
# missing. It exits 0 whatever the sailors answer.
#
# The registry commands edit config/crew-dispatch.json and nothing else,
# except that set-model --first-mate also writes config/privateer. Each builds
# the whole changed file first and writes nothing unless it passes `validate`
# and, in a Privateer home (config/privateer present), unless
# bin/fm-privateer.sh check, the one owner of the quarantine rules, reports no
# violation for it that it does not already report for the current files.
# They stop, as a configuration error, on a current map validate rejects.
# A written file keeps a dated copy beside it (<file>.bak-<YYYYMMDD-HHMMSS>)
# and is replaced atomically.
# The file is rewritten in jq's formatting, and a missing file is never
# created, because its presence changes how every spawn is dispatched. Inside a
# Privateer session config/ is unwritable, so run them from the captain's own
# shell. A change reaches each worker at its next spawn; running workers keep
# what they launched with, and a Privateer session keeps its first mate's model
# and its egress allowlist until it is stopped and started again.
#
# add registers a new sailor, a `placeholder` unless --live. It refuses a name
# already in the map. --from-mlx-serve <server-id> reads that server's entry in
# the mlx-serve registry (FM_MLX_SERVE_SERVERS, default
# ~/.mlx-serve/servers.json): the endpoint is its baseURL plus /v1, and the
# models are the ids GET <baseURL><modelsPath> (default /v1/models) lists now,
# or the --models subset of them. It refuses an unknown or duplicated server
# id, a baseURL that is not http(s), and a server that does not answer or lists
# nothing. It only reads the registry and that list: it never writes
# servers.json and never loads, unloads, or starts a server.
#
# set changes the given fields of an existing sailor; its models change only
# through set-model. In a Privateer home it refuses --placeholder on the
# sailor config/privateer names for the first mate, which runs only on a live
# sailor.
#
# set-model adds <model> to the sailor's models. With --replace <old> it takes
# <old> out of the list and rewrites every rule and default profile naming
# <sailor> with <old> to name <model>, dropping a profile that then repeats
# another in the same list. With --first-mate it writes <sailor>/<model> as the
# first mate line of config/privateer, in place of the current one. With
# --warm, POST <endpoint>/chat/completions asking <model> for one token must
# answer with a completion within FM_SAILOR_WARM_TIMEOUT seconds (default 600),
# so a server that loads models on demand (mlx-serve lists every pulled model,
# each with a `loaded` flag) loads it now, and a load or memory refusal
# surfaces here rather than in a worker's first request. --dry-run prints the
# change and writes nothing. It refuses:
#   - an unknown sailor, or --replace naming a model the sailor does not list
#     or <model> itself;
#   - --replace while a task record carries sailor=<sailor> and model=<old>,
#     since relaunching that task needs <old> listed;
#   - --replace of the first mate's own <sailor>/<old> without --first-mate;
#   - --first-mate outside a Privateer home, or on a placeholder sailor;
#   - --warm on a placeholder sailor;
#   - for a live sailor, an endpoint that does not answer or does not list
#     <model>, and with --warm, a failed warm-up.
# A placeholder is not probed. When the server lists <model> as not loaded
# and --warm is absent, it says so and names --warm.
#
# retire removes a sailor and every rule and default profile naming it. A rule
# left with no profile is removed, as is a default left empty, and each is
# reported. It refuses while any task record carries sailor=<name>.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE resolve the
# home exactly as the other bin/ scripts do.
#
# Exit status: 0 success, 1 invalid (validate) or refused (check and the
# registry commands), 2 usage or configuration error (including a missing or
# unparseable file, an unwritable config/, or missing jq or curl).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FILE="$CONFIG/crew-dispatch.json"
FLAG="$CONFIG/privateer"
SERVERS_FILE="${FM_MLX_SERVE_SERVERS:-$HOME/.mlx-serve/servers.json}"
WORK=
DRY_RUN=0

usage() {
  cat >&2 <<'EOF'
usage: fm-sailor.sh validate | list | status [--all]
       fm-sailor.sh check <sailor> <model> [--task <id>]
       fm-sailor.sh provider-json <sailor> <model>
       fm-sailor.sh add <sailor> (--endpoint <url> --models <ids> | --from-mlx-serve <server-id> [--models <ids>])
                    [--title <text>] [--host <text>] [--max-concurrent <n>] [--live | --placeholder]
       fm-sailor.sh set <sailor> [--endpoint <url>] [--title <text>] [--host <text>] [--max-concurrent <n>] [--live | --placeholder]
       fm-sailor.sh set-model <sailor> <model> [--replace <old>] [--first-mate] [--warm] [--dry-run]
       fm-sailor.sh retire <sailor>
EOF
  exit 2
}

die() {
  echo "fm-sailor: $*" >&2
  exit 2
}

refuse() {
  echo "refused: $*"
  exit 1
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

need_curl() {
  command -v curl >/dev/null 2>&1 || die "curl is required to probe a sailor"
}

# load_timeouts: the probe and warm-up bounds, in whole seconds.
load_timeouts() {
  PROBE_TIMEOUT=${FM_SAILOR_PROBE_TIMEOUT:-3}
  WARM_TIMEOUT=${FM_SAILOR_WARM_TIMEOUT:-600}
  case "$PROBE_TIMEOUT" in '' | *[!0-9]*) die "FM_SAILOR_PROBE_TIMEOUT must be whole seconds" ;; esac
  case "$WARM_TIMEOUT" in '' | *[!0-9]*) die "FM_SAILOR_WARM_TIMEOUT must be whole seconds" ;; esac
}

# load_file: the dispatch file must exist and parse for every subcommand but
# validate, which treats an absent file as nothing to check.
load_file() {
  [ -f "$FILE" ] || die "no config/crew-dispatch.json in this home"
  jq -e . "$FILE" >/dev/null 2>&1 || die "config/crew-dispatch.json is not valid JSON"
}

# load_valid: load_file, and stop on a map validate rejects.
load_valid() {
  local err
  need_jq
  load_file
  err=$(validate_file "$FILE") || die "invalid config/crew-dispatch.json - $err"
}

# sailor_field <sailor> <jq-path>: one field of one sailor, empty when absent.
sailor_field() {
  jq -r --arg s "$1" ".sailors[\$s]$2 // empty" "$FILE"
}

# validate_file <file>: the validate checks on one dispatch file.
validate_file() {
  local err
  jq -e . "$1" >/dev/null 2>&1 || { echo "malformed JSON"; return 1; }
  err=$(jq -r '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    def uses: [(.rules // [])[]? | profiles(.use?)[]?] + [profiles(.default?)[]?];
    def safe_text: type == "string" and length > 0 and (test("[[:space:][:cntrl:]\"'"'"'\\\\]") | not);
    def sailor_bad($n; $s):
      if ($n | test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$") | not) then "sailor name \($n) must be lowercase letters, digits and single dashes"
      elif ($s | type) != "object" then "sailor \($n) must be an object"
      elif (($s.endpoint | safe_text) and ($s.endpoint | test("^https?://[^/]+"))) | not then "sailor \($n) needs an http(s) endpoint"
      elif (["live", "placeholder"] | index($s.status)) == null then "sailor \($n) status must be live or placeholder"
      elif ($s.models | type) != "array" or ($s.models | length) == 0 then "sailor \($n) needs a non-empty models list"
      elif ($s.models | all(safe_text)) | not then "sailor \($n) models must be non-empty strings without spaces or quotes"
      elif ($s | has("max_concurrent")) and ((($s.max_concurrent | type) != "number") or $s.max_concurrent < 1 or ($s.max_concurrent | floor) != $s.max_concurrent) then "sailor \($n) max_concurrent must be a positive whole number"
      elif ($s | has("title")) and (($s.title | type) != "string") then "sailor \($n) title must be a string"
      elif ($s | has("host")) and (($s.host | type) != "string") then "sailor \($n) host must be a string"
      else empty
      end;
    def ref_bad($map):
      .sailor as $n
      | .model as $m
      | if ($n | type) != "string" then "profile sailor must be a string"
        elif ($map | has($n)) | not then "profile names unknown sailor \($n)"
        elif .harness != "opencode" then "sailor \($n) profile must use harness opencode"
        elif ($m | type) != "string" then "sailor \($n) profile needs a model"
        elif (($map[$n].models | type) != "array") or (($map[$n].models | index($m)) == null) then "model \($m) is not listed for sailor \($n)"
        else empty
        end;
    (.sailors // {}) as $map
    | if has("sailors") and (.sailors | type) != "object" then "sailors must be an object"
      else
        ([($map | to_entries[] | sailor_bad(.key; .value))]
         + [uses[] | select(type == "object" and has("sailor")) | ref_bad($map)]
         + (if has("sailor_fallback") then
              (profiles(.sailor_fallback)) as $fb
              | if (.sailor_fallback | type) == "array" and (.sailor_fallback | length) == 0 then ["sailor_fallback needs at least one profile"]
                elif ($fb | length) == 0 then ["sailor_fallback must be a profile object or non-empty profile array"]
                elif ($fb | any(type != "object")) then ["each sailor_fallback profile must be an object"]
                elif ($fb | any((.harness | type) != "string" or (.harness | length) == 0)) then ["each sailor_fallback profile needs harness"]
                elif ($fb | any(has("sailor"))) then ["sailor_fallback must not name a sailor"]
                elif ($fb | any((has("model") and ((.model | type) != "string" or (.model | length) == 0)) or (has("effort") and ((.effort | type) != "string" or (.effort | length) == 0)))) then ["sailor_fallback model and effort must be non-empty strings when present"]
                else [] end
            else [] end))
        | first // empty
      end
  ' "$1" 2>/dev/null) || err="unreadable sailor configuration"
  [ -z "$err" ] && return 0
  printf '%s\n' "$err"
  return 1
}

cmd_validate() {
  need_jq
  [ -f "$FILE" ] || return 0
  validate_file "$FILE"
}

cmd_list() {
  need_jq
  load_file
  jq -r '(.sailors // {}) | to_entries[]
    | "\(.key) status=\(.value.status) endpoint=\(.value.endpoint) max_concurrent=\(.value.max_concurrent // 1) models=\(.value.models | join(","))"' "$FILE"
}

# sailor_load <sailor> <model>: shared lookup for check and provider-json.
sailor_load() {
  local sailor=$1 model=$2
  load_valid
  [ -n "$(sailor_field "$sailor" '.endpoint')" ] || refuse "unknown sailor $sailor"
  jq -e --arg s "$sailor" --arg m "$model" '.sailors[$s].models | index($m) != null' "$FILE" >/dev/null ||
    refuse "model $model is not listed for sailor $sailor"
}

# sailor_tasks <sailor> <exclude-task> [<model>]: ids of the live task records
# dispatched to the sailor, and to that model when one is given.
sailor_tasks() {
  local sailor=$1 exclude=$2 model=${3:-} meta id
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ "$id" != "$exclude" ] || continue
    grep -qxF "sailor=$sailor" "$meta" || continue
    [ -z "$model" ] || grep -qxF "model=$model" "$meta" || continue
    printf '%s\n' "$id"
  done
}

busy_count() {
  sailor_tasks "$1" "$2" | awk 'END { print NR }'
}

task_count() {
  local meta n=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# fetch_models <endpoint>: the endpoint's model list, or failure.
fetch_models() {
  curl -fsS --proto '=http,https' --max-time "$PROBE_TIMEOUT" "${1%/}/models" 2>/dev/null
}

# model_state <models-body> <model>: loaded, unloaded, listed (no loaded
# flag), or missing.
model_state() {
  printf '%s' "$1" | jq -r --arg m "$2" '
    [.data[]? | select(.id? == $m)] | first
    | if . == null then "missing"
      elif .loaded? == true then "loaded"
      elif .loaded? == false then "unloaded"
      else "listed" end' 2>/dev/null || echo missing
}

# warm_model <endpoint> <model>: one one-token chat completion; on failure
# prints the reason and returns 1.
warm_model() {
  local endpoint=$1 model=$2 out code body reason
  if ! out=$(jq -nc --arg m "$model" '{model: $m, messages: [{role: "user", content: "Reply with OK."}], max_tokens: 1, stream: false}' |
    curl -sS --proto '=http,https' --max-time "$WARM_TIMEOUT" -H 'Content-Type: application/json' \
      --data-binary @- -w '\n%{http_code}' "${endpoint%/}/chat/completions" 2>/dev/null); then
    echo "no completion from $endpoint within $WARM_TIMEOUT seconds"
    return 1
  fi
  code=${out##*$'\n'}
  body=${out%$'\n'*}
  case "$code" in
    2??) printf '%s' "$body" | jq -e '.choices | type == "array"' >/dev/null 2>&1 && return 0 ;;
  esac
  reason=$(printf '%s' "$body" | jq -r '(.error.message? // .error? // .detail? // .message?) | select(type == "string")' 2>/dev/null | head -1)
  [ -n "$reason" ] || reason=$(printf '%s' "$body" | tr -s '[:space:]' ' ' | cut -c1-200)
  echo "HTTP $code: $reason"
  return 1
}

# origin_of <url>: scheme and authority, without the path.
origin_of() {
  local rest=${1#*://}
  printf '%s://%s\n' "${1%%://*}" "${rest%%[/?#]*}"
}

# server_queue <endpoint>: `running=<n> waiting=<n>` from the server's vLLM
# gauges, or nothing.
server_queue() {
  curl -fsS --proto '=http,https' --max-time "$PROBE_TIMEOUT" "$(origin_of "$1")/metrics" 2>/dev/null | awk '
    $1 ~ /^vllm:num_requests_running($|[{])/ { r += $2; hr = 1 }
    $1 ~ /^vllm:num_requests_waiting($|[{])/ { w += $2; hw = 1 }
    END { if (hr && hw) printf "running=%d waiting=%d\n", r, w }'
}

cmd_check() {
  local sailor=$1 model=$2 exclude=$3 endpoint status max busy body state note
  sailor_load "$sailor" "$model"
  endpoint=$(sailor_field "$sailor" '.endpoint')
  status=$(sailor_field "$sailor" '.status')
  if [ "$status" != live ]; then
    refuse "sailor $sailor is a placeholder; it is dispatched only after the captain marks it live"
  fi
  max=$(sailor_field "$sailor" '.max_concurrent')
  max=${max:-1}
  busy=$(busy_count "$sailor" "$exclude")
  if [ "$busy" -ge "$max" ]; then
    refuse "sailor $sailor is at capacity ($busy of $max tasks)"
  fi
  need_curl
  load_timeouts
  body=$(fetch_models "$endpoint") || refuse "sailor $sailor is not answering at $endpoint"
  state=$(model_state "$body" "$model")
  [ "$state" != missing ] || refuse "sailor $sailor at $endpoint does not serve $model"
  case "$state" in
    loaded) note="; model loaded" ;;
    unloaded) note="; model listed but not loaded, so the first request loads it" ;;
    *) note= ;;
  esac
  echo "ok: sailor $sailor serves $model at $endpoint ($busy of $max tasks busy$note)"
}

cmd_provider_json() {
  local sailor=$1 model=$2
  sailor_load "$sailor" "$model"
  jq -c --arg s "$sailor" --arg m "$model" '
    .sailors[$s] as $x
    | {($s): {npm: "@ai-sdk/openai-compatible", name: ($x.title // $s),
              options: {baseURL: $x.endpoint}, models: {($m): {name: $m}}}}' "$FILE"
}

cmd_status() {
  local all=$1 names name status endpoint max busy body queue models m states
  load_valid
  need_curl
  load_timeouts
  names=$(jq -r --argjson all "$all" '(.sailors // {}) | to_entries[] | select($all or .value.status == "live") | .key' "$FILE")
  if [ -z "$names" ]; then
    if [ "$all" = true ]; then echo "no sailors"; else echo "no live sailors"; fi
    return 0
  fi
  while IFS= read -r name; do
    status=$(sailor_field "$name" '.status')
    endpoint=$(sailor_field "$name" '.endpoint')
    max=$(sailor_field "$name" '.max_concurrent')
    busy=$(busy_count "$name" "")
    if ! body=$(fetch_models "$endpoint"); then
      echo "$name $status not-answering endpoint=$endpoint tasks=$busy/${max:-1}"
      continue
    fi
    queue=$(server_queue "$endpoint")
    models=$(jq -r --arg s "$name" '.sailors[$s].models[]' "$FILE")
    states=
    while IFS= read -r m; do
      states="$states${states:+,}$m($(model_state "$body" "$m"))"
    done <<<"$models"
    echo "$name $status answering endpoint=$endpoint tasks=$busy/${max:-1}${queue:+ $queue} models=$states"
  done <<<"$names"
}

# --- registry commands -------------------------------------------------------

cleanup() {
  [ -z "$WORK" ] || rm -rf "$WORK"
}

# begin_edit: a scratch directory for the candidate files.
begin_edit() {
  load_valid
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-sailor.XXXXXX") || die "cannot create a scratch directory"
  trap cleanup EXIT
}

# compose [jq options...] <program>: the candidate dispatch file.
compose() {
  jq "$@" "$FILE" > "$WORK/crew-dispatch.json" 2>/dev/null ||
    die "could not edit config/crew-dispatch.json; fix its shape by hand first"
}

privateer_on() {
  [ -e "$FLAG" ] || [ -L "$FLAG" ]
}

# first_mate_line: the <sailor>/<model> line of config/privateer, or empty
# (bin/fm-privateer.sh owns the format).
first_mate_line() {
  [ -f "$FLAG" ] || return 0
  sed -e 's/#.*//' "$FLAG" 2>/dev/null | awk 'NF { print $1; exit }'
}

privateer_check() {  # <config-dir>
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$1" "$SCRIPT_DIR/fm-privateer.sh" check 2>&1
}

# guard_candidate: validate the candidate, and in a Privateer home refuse any
# quarantine violation it adds; bin/fm-privateer.sh check stays the rules' one
# owner by checking a shadow config/ holding the candidate files.
guard_candidate() {
  local err shadow="$WORK/config" entry
  err=$(validate_file "$WORK/crew-dispatch.json") || refuse "$err"
  privateer_on || return 0
  mkdir "$shadow" || die "cannot create a scratch directory"
  for entry in "$CONFIG"/* "$CONFIG"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    ln -s "$entry" "$shadow/${entry##*/}"
  done
  for entry in crew-dispatch.json privateer; do
    [ -f "$WORK/$entry" ] || continue
    rm -f "$shadow/$entry"
    cp "$WORK/$entry" "$shadow/$entry"
  done
  privateer_check "$CONFIG" > "$WORK/before"
  privateer_check "$shadow" > "$WORK/after"
  if grep -vxF -f "$WORK/before" "$WORK/after" > "$WORK/added"; then
    echo "refused: the change would break this home's Privateer quarantine:"
    sed 's/^/  /' "$WORK/added"
    exit 1
  fi
}

# backup_of <file>: a dated backup name not yet taken.
backup_of() {
  local base n=1 bak
  base="$1.bak-$(date +%Y%m%d-%H%M%S)"
  bak=$base
  while [ -e "$bak" ]; do
    n=$((n + 1))
    bak="$base-$n"
  done
  printf '%s\n' "$bak"
}

# replace_file <target> <content>: back up, then swap in atomically; prints the
# backup path.
replace_file() {
  local target=$1 content=$2 bak tmp dir
  dir=$(dirname "$target")
  bak=$(backup_of "$target")
  cp -p "$target" "$bak" 2>/dev/null ||
    die "cannot write in $dir; inside a Privateer session config/ is unwritable, so run this from your own shell"
  tmp=$(mktemp "$dir/.${target##*/}.XXXXXX" 2>/dev/null) || die "cannot write in $dir"
  if ! { cp -p "$target" "$tmp" && cat "$content" > "$tmp" && mv -f "$tmp" "$target"; }; then
    rm -f "$tmp"
    die "could not replace $target; it is unchanged"
  fi
  printf '%s\n' "$bak"
}

# commit: print the change on --dry-run; otherwise write each changed file,
# recording what it wrote in WROTE_DISPATCH and WROTE_PRIVATEER. Returns 1
# when nothing would change.
WROTE_DISPATCH=0
WROTE_PRIVATEER=0
commit() {
  local dispatch_changed=0 privateer_changed=0 bak dispatch_bak
  jq . "$FILE" > "$WORK/current.json"
  cmp -s "$WORK/current.json" "$WORK/crew-dispatch.json" || dispatch_changed=1
  [ ! -f "$WORK/privateer" ] || cmp -s "$FLAG" "$WORK/privateer" || privateer_changed=1
  [ "$dispatch_changed$privateer_changed" != 00 ] || return 1
  if [ "$DRY_RUN" = 1 ]; then
    [ "$dispatch_changed" = 0 ] ||
      diff -u -L config/crew-dispatch.json -L 'config/crew-dispatch.json (after)' "$WORK/current.json" "$WORK/crew-dispatch.json"
    [ "$privateer_changed" = 0 ] ||
      diff -u -L config/privateer -L 'config/privateer (after)' "$FLAG" "$WORK/privateer"
    echo "dry run: nothing written"
    return 0
  fi
  if [ "$dispatch_changed" = 1 ]; then
    dispatch_bak=$(replace_file "$FILE" "$WORK/crew-dispatch.json") || exit 2
    WROTE_DISPATCH=1
    echo "wrote config/crew-dispatch.json (previous copy: ${dispatch_bak#"$CONFIG"/})"
  fi
  if [ "$privateer_changed" = 1 ]; then
    if ! bak=$(replace_file "$FLAG" "$WORK/privateer"); then
      [ "$WROTE_DISPATCH" = 0 ] || cp -p "$dispatch_bak" "$FILE" 2>/dev/null ||
        die "config/privateer is unchanged, and config/crew-dispatch.json could not be restored from ${dispatch_bak#"$CONFIG"/}"
      die "config/privateer is unchanged, so config/crew-dispatch.json was restored"
    fi
    WROTE_PRIVATEER=1
    echo "wrote config/privateer (previous copy: ${bak#"$CONFIG"/})"
  fi
}

# first_mate_view <dispatch-file> <line>: what of the file the first mate on
# <line> depends on: its sailor's endpoint and status, and whether it lists
# the model.
first_mate_view() {
  jq -c --arg s "${2%%/*}" --arg m "${2#*/}" '
    (.sailors // {})[$s] // {} | {endpoint, status, serves: ((.models // []) | index($m) != null)}' "$1"
}

# report_effects: when a written change applies, and what the quarantine
# still reports. The first mate needs a restart when its line changed or its
# sailor's endpoint, status, or listing of its model did.
report_effects() {
  local line
  [ "$WROTE_DISPATCH$WROTE_PRIVATEER" != 00 ] || return 0
  [ "$WROTE_DISPATCH" = 0 ] ||
    echo "workers: the change applies from each worker's next spawn; running workers keep what they launched with"
  privateer_on || return 0
  line=$(first_mate_line)
  if [ "$WROTE_PRIVATEER" = 1 ] || { [ -n "$line" ] &&
    [ "$(first_mate_view "$WORK/current.json" "$line")" != "$(first_mate_view "$FILE" "$line")" ]; }; then
    echo "first mate: restart the Privateer session to switch (fm-privateer.sh stop, then start; stop waits until no task is in flight, $(task_count) now)"
  fi
  if ! cmp -s <(jq -c '[(.sailors // {})[] | .endpoint] | sort' "$WORK/current.json") <(jq -c '[(.sailors // {})[] | .endpoint] | sort' "$FILE"); then
    echo "egress: a running Privateer session allows a new endpoint only after fm-privateer.sh stop and start"
  fi
  if [ -s "$WORK/after" ]; then
    echo "note: the Privateer quarantine still reports:"
    sed 's/^/  /' "$WORK/after"
  fi
}

# models_json <comma-list>: a JSON array of the ids, in order, without repeats.
models_json() {
  printf '%s' "$1" | jq -Rc 'split(",") | map(select(length > 0)) | reduce .[] as $m ([]; if any(.[]; . == $m) then . else . + [$m] end)'
}

# mlx_server <server-id>: sets ENDPOINT and LIVE_MODELS (a JSON array) from
# the mlx-serve registry and the server's live model list.
mlx_server() {
  local id=$1 count base path url enabled body hint=
  [ -f "$SERVERS_FILE" ] || refuse "no mlx-serve registry at $SERVERS_FILE"
  jq -e '.servers | type == "array"' "$SERVERS_FILE" >/dev/null 2>&1 || refuse "$SERVERS_FILE holds no servers list"
  count=$(jq --arg id "$id" '[.servers[] | select(.id? == $id)] | length' "$SERVERS_FILE")
  case "$count" in
    0) refuse "$SERVERS_FILE has no server $id (it lists: $(jq -r '[.servers[].id? | strings] | join(", ")' "$SERVERS_FILE"))" ;;
    1) ;;
    *) refuse "$SERVERS_FILE lists server $id more than once" ;;
  esac
  base=$(jq -r --arg id "$id" '.servers[] | select(.id? == $id) | .baseURL | strings' "$SERVERS_FILE")
  path=$(jq -r --arg id "$id" '.servers[] | select(.id? == $id) | .modelsPath // "/v1/models" | strings' "$SERVERS_FILE")
  enabled=$(jq -r --arg id "$id" '.servers[] | select(.id? == $id) | .enabled != false' "$SERVERS_FILE")
  case "$base" in http://?* | https://?*) ;; *) refuse "mlx-serve server $id has baseURL '$base', which is not an http(s) URL" ;; esac
  [ "$enabled" = true ] || hint=" (servers.json marks it disabled)"
  base=${base%/}
  url="$base/${path#/}"
  need_curl
  load_timeouts
  body=$(curl -fsS --proto '=http,https' --max-time "$PROBE_TIMEOUT" "$url" 2>/dev/null) ||
    refuse "mlx-serve server $id is not answering at $url$hint; fm-sailor.sh never starts a server"
  LIVE_MODELS=$(printf '%s' "$body" | jq -c '[.data[]?.id? | strings]' 2>/dev/null) || LIVE_MODELS='[]'
  [ "$LIVE_MODELS" != '[]' ] || refuse "mlx-serve server $id lists no models at $url"
  ENDPOINT="$base/v1"
}

cmd_add() {
  local name title='' host='' endpoint='' models='' max='' status=placeholder from='' has_title=0 has_host=0 entry models_array missing
  [ "$#" -ge 1 ] || usage
  name=$1
  shift
  case "$name" in '' | -*) usage ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --endpoint) [ "$#" -ge 2 ] || usage; endpoint=$2; shift 2 ;;
      --models) [ "$#" -ge 2 ] || usage; models=$2; shift 2 ;;
      --title) [ "$#" -ge 2 ] || usage; title=$2; has_title=1; shift 2 ;;
      --host) [ "$#" -ge 2 ] || usage; host=$2; has_host=1; shift 2 ;;
      --max-concurrent) [ "$#" -ge 2 ] || usage; max=$2; shift 2 ;;
      --from-mlx-serve) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; from=$2; shift 2 ;;
      --live) status=live; shift ;;
      --placeholder) status=placeholder; shift ;;
      *) usage ;;
    esac
  done
  if [ -n "$from" ]; then
    [ -z "$endpoint" ] || usage
  else
    [ -n "$endpoint" ] && [ -n "$models" ] || usage
  fi
  case "$max" in '' | *[!0-9]*) [ -z "$max" ] || refuse "--max-concurrent must be a positive whole number" ;; esac
  begin_edit
  [ -z "$(sailor_field "$name" '.endpoint')" ] || refuse "sailor $name already exists; change it with set or set-model"
  models_array=$(models_json "$models")
  if [ -n "$from" ]; then
    mlx_server "$from"
    endpoint=$ENDPOINT
    if [ -n "$models" ]; then
      missing=$(jq -rn --argjson want "$models_array" --argjson live "$LIVE_MODELS" '[$want[] | select(. as $m | $live | index($m) | not)] | join(", ")')
      [ -z "$missing" ] || refuse "mlx-serve server $from does not list $missing"
    else
      models_array=$LIVE_MODELS
    fi
  fi
  entry=$(jq -nc --arg title "$title" --argjson has_title "$has_title" --arg host "$host" --argjson has_host "$has_host" \
    --arg endpoint "$endpoint" --arg status "$status" --argjson models "$models_array" --arg max "$max" '
    (if $has_title == 1 then {title: $title} else {} end)
    + (if $has_host == 1 then {host: $host} else {} end)
    + {endpoint: $endpoint, status: $status, models: $models}
    + (if $max != "" then {max_concurrent: ($max | tonumber)} else {} end)')
  # shellcheck disable=SC2016 # jq, not the shell, expands the $ names.
  compose --arg s "$name" --argjson e "$entry" '.sailors = ((.sailors // {}) + {($s): $e})'
  guard_candidate
  commit || true
  echo "added sailor $name ($status) at $endpoint serving $(jq -r 'join(",")' <<<"$models_array")"
  report_effects
}

cmd_set() {
  local name patch='{}' key value runs line
  [ "$#" -ge 2 ] || usage
  name=$1
  shift
  case "$name" in '' | -*) usage ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --endpoint | --title | --host)
        [ "$#" -ge 2 ] || usage
        key=${1#--}
        patch=$(jq -c --arg k "$key" --arg v "$2" '. + {($k): $v}' <<<"$patch")
        shift 2
        ;;
      --max-concurrent)
        [ "$#" -ge 2 ] || usage
        case "$2" in '' | *[!0-9]*) refuse "--max-concurrent must be a positive whole number" ;; esac
        patch=$(jq -c --arg v "$2" '. + {max_concurrent: ($v | tonumber)}' <<<"$patch")
        shift 2
        ;;
      --live | --placeholder)
        value=${1#--}
        patch=$(jq -c --arg v "$value" '. + {status: $v}' <<<"$patch")
        shift
        ;;
      *) usage ;;
    esac
  done
  [ "$patch" != '{}' ] || usage
  begin_edit
  [ -n "$(sailor_field "$name" '.endpoint')" ] || refuse "unknown sailor $name"
  line=$(first_mate_line)
  if [ "$(jq -r '.status // empty' <<<"$patch")" = placeholder ] && privateer_on && [ "${line%%/*}" = "$name" ]; then
    refuse "the first mate runs on $line, and the first mate runs only on a live sailor"
  fi
  # shellcheck disable=SC2016 # jq, not the shell, expands the $ names.
  compose --arg s "$name" --argjson p "$patch" '.sailors[$s] += $p'
  guard_candidate
  if ! commit; then
    echo "sailor $name already reads that way; nothing written"
    return 0
  fi
  if [ "$(jq -r '.status // empty' <<<"$patch")" = placeholder ]; then
    runs=$(busy_count "$name" "")
    [ "$runs" = 0 ] || echo "note: $runs task(s) still run on $name; as a placeholder it takes no new work"
  fi
  report_effects
}

cmd_set_model() {
  local name model old='' first_mate=0 warm=0 status endpoint replaced ids body state='' reason line
  [ "$#" -ge 2 ] || usage
  name=$1 model=$2
  shift 2
  case "$name$model" in -*) usage ;; esac
  case "$model" in '' | -*) usage ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --replace) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; old=$2; shift 2 ;;
      --first-mate) first_mate=1; shift ;;
      --warm) warm=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      *) usage ;;
    esac
  done
  begin_edit
  status=$(sailor_field "$name" '.status')
  [ -n "$status" ] || refuse "unknown sailor $name"
  endpoint=$(sailor_field "$name" '.endpoint')
  if [ -n "$old" ]; then
    [ "$old" != "$model" ] || refuse "--replace names $model itself"
    jq -e --arg s "$name" --arg m "$old" '.sailors[$s].models | index($m) != null' "$FILE" >/dev/null ||
      refuse "model $old is not listed for sailor $name"
    ids=$(sailor_tasks "$name" "" "$old" | paste -sd, -)
    [ -z "$ids" ] || refuse "task(s) $ids run $name/$old, and relaunching them needs it listed; replace it once they land, or add $model without --replace"
    line=$(first_mate_line)
    if [ "$line" = "$name/$old" ] && [ "$first_mate" = 0 ]; then
      refuse "the first mate runs on $name/$old; add --first-mate to move it too, or drop --replace"
    fi
  fi
  if [ "$first_mate" = 1 ]; then
    privateer_on || refuse "--first-mate needs a Privateer home; config/privateer is absent, and this command never creates it"
    [ "$status" = live ] || refuse "sailor $name is a placeholder, and the first mate runs only on a live sailor"
  fi
  [ "$warm" = 0 ] || [ "$status" = live ] || refuse "sailor $name is a placeholder, and a placeholder is never probed or warmed"
  replaced=$(jq --arg s "$name" --arg old "$old" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    [((.rules // [])[]? | profiles(.use?)[]?), profiles(.default?)[]?
     | select(type == "object" and .sailor == $s and .model == $old)] | length' "$FILE")
  # shellcheck disable=SC2016 # jq, not the shell, expands the $ names.
  compose --arg s "$name" --arg m "$model" --arg old "$old" '
    def dedupe: reduce .[] as $p ([]; if any(.[]; . == $p) then . else . + [$p] end);
    def swap: if type == "object" and .sailor == $s and .model == $old then .model = $m else . end;
    def fix: if type == "array" then map(swap) | dedupe else swap end;
    .sailors[$s].models |= ((if $old != "" then map(if . == $old then $m else . end) else . end) + [$m] | dedupe)
    | if $old == "" then .
      else (if (.rules | type) == "array" then .rules |= map(if type == "object" and has("use") then .use |= fix else . end) else . end)
        | (if has("default") then .default |= fix else . end)
      end'
  if [ "$first_mate" = 1 ]; then
    awk -v v="$name/$model" '
      { line = $0; sub(/#.*/, "", line) }
      !done && line ~ /[^[:space:]]/ { print v; done = 1; next }
      { print }
      END { if (!done) print v }' "$FLAG" > "$WORK/privateer"
  fi
  guard_candidate
  if [ "$status" = live ]; then
    need_curl
    load_timeouts
    body=$(fetch_models "$endpoint") || refuse "sailor $name is not answering at $endpoint"
    state=$(model_state "$body" "$model")
    [ "$state" != missing ] || refuse "sailor $name at $endpoint does not serve $model"
    if [ "$warm" = 1 ]; then
      reason=$(warm_model "$endpoint" "$model") || refuse "sailor $name could not load $model: $reason"
      state=warmed
    fi
  else
    echo "note: $name is a placeholder, so $model was not probed"
  fi
  if ! commit; then
    echo "sailor $name already lists $model; nothing written"
  elif [ "$DRY_RUN" = 0 ]; then
    echo "sailor $name lists $model${old:+ in place of $old}"
    [ -z "$old" ] || echo "replaced $name/$old with $name/$model in $replaced profile(s)"
    [ "$first_mate" = 0 ] || echo "config/privateer names $name/$model for the first mate"
  fi
  [ "$state" != unloaded ] || echo "note: $name lists $model but has not loaded it, so the first request loads it; rerun with --warm to load it now"
  [ "$state" != warmed ] || echo "$name has loaded $model"
  report_effects
}

cmd_retire() {
  local name ids removed
  [ "$#" -eq 1 ] || usage
  name=$1
  case "$name" in '' | -*) usage ;; esac
  begin_edit
  [ -n "$(sailor_field "$name" '.endpoint')" ] || refuse "unknown sailor $name"
  ids=$(sailor_tasks "$name" "" | paste -sd, -)
  [ -z "$ids" ] || refuse "task(s) $ids run on $name; retire it once they land"
  removed=$(jq --arg s "$name" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    [((.rules // [])[]? | profiles(.use?)[]?), profiles(.default?)[]?
     | select(type == "object" and .sailor == $s)] | length' "$FILE")
  jq -r --arg s "$name" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    def gone: type == "object" and .sailor == $s;
    ([(.rules // [])[]? | select(type == "object")
      | select((profiles(.use?) | length) > 0 and (profiles(.use?) | all(gone)))
      | "removed rule \"\(.when)\", which offered only \($s)"]
     + (if (profiles(.default?) | length) > 0 and (profiles(.default?) | all(gone))
        then ["removed the default, which offered only \($s)"] else [] end))[]' "$FILE" > "$WORK/emptied"
  # shellcheck disable=SC2016 # jq, not the shell, expands the $ names.
  compose --arg s "$name" '
    def gone: type == "object" and .sailor == $s;
    def strip: if type == "array" then map(select(gone | not)) elif gone then [] else . end;
    def emptied: type == "array" and length == 0;
    del(.sailors[$s])
    | (if (.rules | type) == "array" then
         .rules |= map(if type == "object" and has("use") and ((.use | emptied) | not) and (.use | strip | emptied) then empty
                       elif type == "object" and has("use") then .use |= strip
                       else . end)
       else . end)
    | (if has("default") and ((.default | emptied) | not) and (.default | strip | emptied) then del(.default)
       elif has("default") then .default |= strip
       else . end)'
  guard_candidate
  commit || true
  echo "retired sailor $name and the $removed profile(s) naming it"
  cat "$WORK/emptied"
  report_effects
}

[ "$#" -ge 1 ] || usage
case "$1" in
  validate)
    [ "$#" -eq 1 ] || usage
    cmd_validate
    ;;
  list)
    [ "$#" -eq 1 ] || usage
    cmd_list
    ;;
  check)
    shift
    [ "$#" -ge 2 ] || usage
    sailor=$1 model=$2 exclude=''
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; exclude=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    cmd_check "$sailor" "$model" "$exclude"
    ;;
  provider-json)
    [ "$#" -eq 3 ] || usage
    cmd_provider_json "$2" "$3"
    ;;
  status)
    case "$#:${2:-}" in
      1:) cmd_status false ;;
      2:--all) cmd_status true ;;
      *) usage ;;
    esac
    ;;
  add) shift; cmd_add "$@" ;;
  set) shift; cmd_set "$@" ;;
  set-model) shift; cmd_set_model "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  -h | --help)
    sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    ;;
  *) usage ;;
esac
