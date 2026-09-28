#!/usr/bin/env bash
# fm-sailor.sh - named local sailors: the `sailors` map in config/crew-dispatch.json.
#
# docs/configuration.md ("Crew dispatch profiles", "Named sailors") owns the
# schema and what firstmate does with each answer. This header owns the checks:
# map and reference validation, the placeholder lock, the per-sailor capacity
# count, the endpoint probe, and the OpenCode provider fragment.
#
# Usage:
#   fm-sailor.sh validate
#   fm-sailor.sh list
#   fm-sailor.sh check <sailor> <model> [--task <id>]
#   fm-sailor.sh provider-json <sailor> <model>
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
# It prints `ok: ...` and exits 0, or prints `refused: ...` and exits 1.
#
# provider-json prints the compact OpenCode `provider` entry for the sailor
# with just that model, keyed by the sailor's name, for bin/fm-spawn.sh to put
# inside the OPENCODE_CONFIG_CONTENT it writes; OpenCode then addresses the
# model as <sailor>/<model>.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE resolve the
# home exactly as the other bin/ scripts do.
#
# Exit status: 0 success, 1 invalid (validate) or refused (check), 2 usage or
# configuration error (including a missing or unparseable file, or missing jq
# or curl).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FILE="$CONFIG/crew-dispatch.json"

usage() {
  echo "usage: fm-sailor.sh validate | list | check <sailor> <model> [--task <id>] | provider-json <sailor> <model>" >&2
  exit 2
}

die() {
  echo "fm-sailor: $*" >&2
  exit 2
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

# load_file: the dispatch file must exist and parse for every subcommand but
# validate, which treats an absent file as nothing to check.
load_file() {
  [ -f "$FILE" ] || die "no config/crew-dispatch.json in this home"
  jq -e . "$FILE" >/dev/null 2>&1 || die "config/crew-dispatch.json is not valid JSON"
}

# sailor_field <sailor> <jq-path>: one field of one sailor, empty when absent.
sailor_field() {
  jq -r --arg s "$1" ".sailors[\$s]$2 // empty" "$FILE"
}

cmd_validate() {
  need_jq
  [ -f "$FILE" ] || return 0
  jq -e . "$FILE" >/dev/null 2>&1 || { echo "malformed JSON"; return 1; }
  local err
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
  ' "$FILE" 2>/dev/null) || err="unreadable sailor configuration"
  [ -z "$err" ] && return 0
  printf '%s\n' "$err"
  return 1
}

cmd_list() {
  need_jq
  load_file
  jq -r '(.sailors // {}) | to_entries[]
    | "\(.key) status=\(.value.status) endpoint=\(.value.endpoint) max_concurrent=\(.value.max_concurrent // 1) models=\(.value.models | join(","))"' "$FILE"
}

# sailor_load <sailor> <model>: shared lookup for check and provider-json.
sailor_load() {
  local sailor=$1 model=$2 err
  need_jq
  load_file
  err=$(cmd_validate) || die "invalid config/crew-dispatch.json - $err"
  [ -n "$(sailor_field "$sailor" '.endpoint')" ] || { echo "refused: unknown sailor $sailor"; exit 1; }
  jq -e --arg s "$sailor" --arg m "$model" '.sailors[$s].models | index($m) != null' "$FILE" >/dev/null ||
    { echo "refused: model $model is not listed for sailor $sailor"; exit 1; }
}

# busy_count <sailor> <exclude-task>: live task records dispatched to the sailor.
busy_count() {
  local sailor=$1 exclude=$2 meta id n=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ "$id" != "$exclude" ] || continue
    grep -qxF "sailor=$sailor" "$meta" && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

cmd_check() {
  local sailor=$1 model=$2 exclude=$3 endpoint status max busy timeout body
  sailor_load "$sailor" "$model"
  endpoint=$(sailor_field "$sailor" '.endpoint')
  status=$(sailor_field "$sailor" '.status')
  if [ "$status" != live ]; then
    echo "refused: sailor $sailor is a placeholder; it is dispatched only after the captain marks it live"
    exit 1
  fi
  max=$(sailor_field "$sailor" '.max_concurrent')
  max=${max:-1}
  busy=$(busy_count "$sailor" "$exclude")
  if [ "$busy" -ge "$max" ]; then
    echo "refused: sailor $sailor is at capacity ($busy of $max tasks)"
    exit 1
  fi
  command -v curl >/dev/null 2>&1 || die "curl is required to probe a sailor"
  timeout=${FM_SAILOR_PROBE_TIMEOUT:-3}
  case "$timeout" in '' | *[!0-9]*) die "FM_SAILOR_PROBE_TIMEOUT must be whole seconds" ;; esac
  if ! body=$(curl -fsS --max-time "$timeout" "${endpoint%/}/models" 2>/dev/null); then
    echo "refused: sailor $sailor is not answering at $endpoint"
    exit 1
  fi
  if ! printf '%s' "$body" | jq -e --arg m "$model" '[.data[]?.id] | index($m) != null' >/dev/null 2>&1; then
    echo "refused: sailor $sailor at $endpoint does not serve $model"
    exit 1
  fi
  echo "ok: sailor $sailor serves $model at $endpoint ($busy of $max tasks busy)"
}

cmd_provider_json() {
  local sailor=$1 model=$2
  sailor_load "$sailor" "$model"
  jq -c --arg s "$sailor" --arg m "$model" '
    .sailors[$s] as $x
    | {($s): {npm: "@ai-sdk/openai-compatible", name: ($x.title // $s),
              options: {baseURL: $x.endpoint}, models: {($m): {name: $m}}}}' "$FILE"
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
    sailor=$1 model=$2 exclude=
    shift 2
    if [ "$#" -gt 0 ]; then
      [ "$#" -eq 2 ] && [ "$1" = --task ] && [ -n "$2" ] || usage
      exclude=$2
    fi
    cmd_check "$sailor" "$model" "$exclude"
    ;;
  provider-json)
    [ "$#" -eq 3 ] || usage
    cmd_provider_json "$2" "$3"
    ;;
  -h | --help)
    sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    ;;
  *) usage ;;
esac
