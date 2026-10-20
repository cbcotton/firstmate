#!/usr/bin/env bash
# fm-sailor.sh - named sailors: the `sailors` map in config/crew-dispatch.json.
#
# docs/configuration.md ("Crew dispatch profiles", "Named sailors") owns the
# schema and what firstmate does with each answer. This header owns the checks:
# map and reference validation, the placeholder lock, the per-sailor capacity
# count, the endpoint's model-list and message-shape probes, the warm-up, the
# sign-in check of a login sailor, the choice by grade, the OpenCode provider
# fragment, the status view, and the health probe; and the registry commands
# that edit the map, with their refusals.
#
# A sailor is either an endpoint sailor, an OpenAI-compatible `endpoint` that
# OpenCode drives, or a login sailor, a worker app (`harness`: codex, kimi,
# or grok) run on the subscription login already stored on this machine. A
# login sailor has no endpoint, auth_env, unlisted_models, model_settings, or
# host; its `models` are the model ids the worker app takes, and its optional
# `login` is a label for the account, never a credential. This script never
# reads, prints, or copies a stored login: every sign-in check runs the worker
# app itself, under `env -i` with HOME, PATH, and, when set, TMPDIR, USER, and
# LOGNAME, so an ambient API key never stands in for the login. check, before
# a spawn, runs the full check:
#   codex: `codex login status` exits 0 within FM_SAILOR_LOGIN_TIMEOUT seconds
#     (default 30);
#   grok: ${GROK_HOME:-~/.grok}/auth.json exists and `grok models` exits 0
#     within that bound;
#   kimi: a credentials file ~/.kimi-code/credentials/kimi-code-env-*.json
#     exists and `kimi -p` answers one test prompt with exit 0 within
#     FM_SAILOR_SMOKE_TIMEOUT seconds (default 120), from an empty scratch
#     directory, so a stale login surfaces before a worker is launched on it
#     rather than inside its first turn. That prompt is the one request these
#     commands send a login sailor.
# health and status read only local, network-free sign-in evidence, so a
# periodic tick never waits on a vendor endpoint: `codex login status` exits 0
# within FM_SAILOR_PROBE_TIMEOUT seconds, and for grok and kimi the auth.json
# or credentials file above exists.
# An app that is not installed, times out, or exits non-zero reads as signed
# out, and every reason names the app and never a value.
# Before dispatching to an endpoint sailor, check also sends one tiny chat
# completion in the shape OpenCode sends once its plugins add system text:
# max_tokens 1, two leading system messages, then the user message. A refusal
# names the endpoint's error, so a server that lists a model but rejects that
# shape is refused rather than reported live. status and health never ask for
# a completion.
#
# Usage:
#   fm-sailor.sh validate
#   fm-sailor.sh list
#   fm-sailor.sh grades
#   fm-sailor.sh check <sailor> <model> [--task <id>]
#   fm-sailor.sh pick (--grade <grade> | --sailor <sailor> [--model <model>])
#                     [--grade <grade>] [--facet <facet>] [--spend] [--task <id>]
#   fm-sailor.sh provider-json <sailor> <model>
#   fm-sailor.sh status [--all]
#   fm-sailor.sh health
#   fm-sailor.sh with-token <variable> <env-file> -- <command> [<arg>...]
#   fm-sailor.sh add <sailor> --endpoint <url> --models <id>[,<id>...]
#                    [--title <text>] [--host <text>] [--max-concurrent <n>]
#                    [--auth-env <variable>] [--unlisted-models] [--live | --placeholder]
#   fm-sailor.sh add <sailor> --from-mlx-serve <server-id> [--models <id>[,<id>...]]
#                    [--title <text>] [--host <text>] [--max-concurrent <n>]
#                    [--auth-env <variable>] [--unlisted-models] [--live | --placeholder]
#   fm-sailor.sh add <sailor> --harness <codex|kimi|grok> --models <id>[,<id>...]
#                    [--login <label>] [--title <text>] [--max-concurrent <n>]
#                    [--live | --placeholder]
#   fm-sailor.sh set <sailor> [--endpoint <url>] [--title <text>] [--host <text>]
#                    [--max-concurrent <n>] [--auth-env <variable> | --no-auth-env]
#                    [--unlisted-models | --no-unlisted-models] [--live | --placeholder]
#   fm-sailor.sh set-model <sailor> <model> [--replace <old>] [--first-mate]
#                    [--model-limit <context>:<output>] [--model-options <json>]
#                    [--warm] [--dry-run]
#   fm-sailor.sh retire <sailor>
#   fm-sailor.sh sync <registry> --home <key> [--dry-run]
#
# `model_settings` maps a listed model id to {limit, options}: limit holds both
# context and output and nothing else, each a positive whole number; options is an object of
# string, number, or boolean values (for example reasoningEffort, temperature,
# top_p, top_k, enable_thinking). validate refuses any other shape, and a
# sailor without model_settings behaves as it always has.
#
# `auth_env` names the environment variable holding the sailor's bearer token,
# a POSIX name such as HF_TOKEN. Its value is read at use time: the
# environment's when set and non-empty, otherwise the last assignment in this
# home's .env (bin/fm-env-lib.sh). Every request this script sends to the
# sailor carries `Authorization: Bearer <value>` on a header curl reads from a
# pipe, never from its command line, and the value is never printed, logged,
# or written anywhere. A variable set nowhere, or holding whitespace or a
# control character, is a missing token: check refuses, health reads the
# sailor as down, and status reads it as no-token, each naming the variable
# and never its value. `unlisted_models: true` says the endpoint also serves
# model ids its model list leaves out, as a router that takes provider-routed
# ids does, so check, status, and set-model need that list to answer but not
# to name the model. validate refuses an auth_env that is not such a name and
# an unlisted_models that is not true or false.
#
# A sailor's optional `grade` is one of deckhand, sailor, specialist, expert,
# lowest to highest. It describes the sailor's one bound model, so a graded
# sailor lists exactly one model. Its optional `facets` is a list of distinct
# lowercase words joined by single dashes, and its optional `paid` is true or
# false.
#
# validate is silent and exits 0 when config/crew-dispatch.json is absent or
# declares no sailor anywhere; otherwise it checks the `sailors` map, every
# profile's `sailor` or `grade` reference (in rules, default, and
# sailor_fallback, which names neither), each rule's `spend`, and the
# `sailor_fallback` shape, and prints one reason on stdout with exit 1 when any
# is malformed. A sailor has exactly one of `endpoint` and `harness`, and a
# login sailor's harness is codex, kimi, or grok. A profile naming a sailor
# uses that sailor's harness, opencode for an endpoint sailor, and without a
# model needs that sailor to list exactly one model; a profile naming a grade
# uses harness opencode and names no model, and the sailor the pick chooses
# for it brings its own harness, which bin/fm-spawn.sh --sailor then requires;
# a rule's `spend`, when present, is "allowed".
# bin/fm-bootstrap.sh reports that reason as a CREW_DISPATCH diagnostic.
#
# list prints one line per sailor: name, status, endpoint or harness,
# capacity, grade (a graded sailor only), models, and login (a login sailor
# with a label only).
#
# grades prints the grades, lowest first, one per line.
#
# check answers "may a worker be dispatched to this sailor and model right
# now?" in this order, stopping at the first refusal:
#   1. the sailor exists and the model is listed in its `models`;
#   2. its status is `live` - a `placeholder` is never dispatched, even when
#      something answers at its address;
#   3. fewer than max_concurrent (default 1) task records in state/ carry
#      sailor=<name>, not counting --task <id>, the task being relaunched;
#   4. a sailor with auth_env has its token;
#   5. GET <endpoint>/models answers within FM_SAILOR_PROBE_TIMEOUT seconds
#      (default 3) with an OpenAI-style model list that includes <model>, or,
#      for a sailor with unlisted_models, with any model list;
#   6. POST <endpoint>/chat/completions answers a one-token request in
#      OpenCode's message shape, two leading system messages then the user
#      message, within FM_SAILOR_SMOKE_TIMEOUT seconds (default 120), or
#      within FM_SAILOR_WARM_TIMEOUT seconds (default 600) when the model list
#      flags the model as not loaded, since that probe loads it.
# For a login sailor, steps 4 and 5 are its full sign-in check (above); step 6
# is for an endpoint sailor alone. It prints `ok: ...` and exits 0, or prints
# `refused: ...` and exits 1. When the model list carries a `loaded` flag, the
# ok line says whether the model is loaded or only listed. Step 6 is the one
# request check sends that asks for a completion, so a check spends at most
# one tiny request on a paid endpoint; status and health never ask for one.
#
# pick chooses the sailor and model that may take a task now, and prints them
# as `<sailor> <model>` with exit 0, or prints `refused: ...` and exits 1.
# With --sailor it weighs that one sailor, on --model or, without it, on its
# one listed model, and any --grade or --facet is a gate that sailor must
# meet. Otherwise the candidates are the live sailors whose grade is at least
# the --grade floor (a repeated --grade takes the highest), lowest sufficient
# grade first, then free before paid, then in map order; an ungraded sailor is
# never picked by grade. --facet keeps only sailors whose facets list it. A
# `paid` sailor is a candidate only with --spend, which the
# caller passes when the matched rule says "spend": "allowed" or the captain
# okays spend for this one task. The first candidate that check passes, with
# --task <id> handed to it, is printed; a refusal lists each candidate's
# reason.
#
# provider-json prints the compact OpenCode `provider` entry for the sailor
# with just that model, keyed by the sailor's name, for bin/fm-spawn.sh and
# bin/fm-privateer.sh to put inside the OpenCode configuration they write;
# OpenCode then addresses the model as <sailor>/<model>. The model carries the
# sailor's optional `model_settings` for it: a `limit` object (context, output)
# and an `options` object, in OpenCode's own field names. A sailor with
# auth_env gets `apiKey: "{env:<variable>}"`, which OpenCode resolves from its
# own environment and sends as the bearer token, so the entry never holds the
# value. It refuses a login sailor, which runs as its own worker app and takes
# no OpenCode provider.
#
# with-token puts <variable> into <command>'s environment and execs it: the
# environment's value when set and non-empty, otherwise <env-file>'s, read as
# auth_env is. It refuses (exit 1), naming the variable and never its value,
# when neither sets it or it holds whitespace or a control character. It reads
# no dispatch file, so bin/fm-spawn.sh and bin/fm-privateer.sh put it before an
# OpenCode launch on a sailor with auth_env, and the value reaches OpenCode
# through its environment alone, never a command line or a file.
#
# status prints one line per live sailor, or per sailor with --all: its status,
# whether it is answering by the same probe health uses (below), this home's
# tasks on it against its capacity, and, for an answering sailor, the server's
# running and waiting requests when <endpoint's origin>/metrics exposes
# vLLM-style gauges (vllm:num_requests_running and vllm:num_requests_waiting),
# and, when GET <endpoint>/models answers, each listed model as loaded,
# unloaded (listed with loaded=false), listed (the server reports no loaded
# flag), unlisted (left out of the list of a sailor with unlisted_models), or
# missing. A graded sailor's line carries grade=<grade> right after its tasks,
# and an ungraded sailor's line omits it. A sailor missing its token is not
# probed: its line reads no-token in place of the answer and ends with
# auth_env=<variable>. A login sailor's line carries harness=<harness> in
# place of endpoint=<url>, answering or not-answering by its local sign-in
# evidence (above), each model as signed-in or signed-out, and
# ends with login=<label> when it has one. Every sailor is
# probed at once, so the run takes about one probe timeout however many are
# down. It exits 0 whatever the sailors answer.
#
# health prints `<sailor> up <url>` or `<sailor> down <url>` for each live
# sailor, and nothing when there is none. A sailor whose endpoint lies under
# the baseURL of a server in the mlx-serve registry (FM_MLX_SERVE_SERVERS,
# default ~/.mlx-serve/servers.json) that names a healthPath is up when GET
# <baseURL><healthPath> answers without an HTTP error status within
# FM_SAILOR_PROBE_TIMEOUT seconds, the longest matching baseURL winning; any
# other sailor is up when GET <endpoint>/models does. A sailor missing its
# token is down without a probe. A login sailor's line reads `<sailor> up
# login:<harness>` or `<sailor> down login:<harness>` by its local sign-in
# evidence (above), so the periodic watch sends no prompt and no request. Every
# sailor is probed at once, so the whole run takes about one probe timeout
# however many there are. bin/fm-watch.sh turns its changes into wakes. It
# exits 0 whatever the sailors answer.
#
# The registry commands edit config/crew-dispatch.json and nothing else,
# except that set-model --first-mate and sync also write config/privateer. Each builds
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
# what they launched with. A Privateer session keeps its first mate's model
# until it is stopped and started again, and its egress allowlist until the
# captain runs bin/fm-privateer.sh reload. In a home whose
# config/sailor-registry exists, add, set, set-model, and retire add a note
# after a write that the next sync rewrites the sailors from the slot registry.
#
# add registers a new sailor, a `placeholder` unless --live. It refuses a name
# already in the map. --from-mlx-serve <server-id> reads that server's entry in
# the mlx-serve registry (FM_MLX_SERVE_SERVERS, default
# ~/.mlx-serve/servers.json): the endpoint is its baseURL plus /v1, and the
# models are the ids GET <baseURL><modelsPath> (default /v1/models) lists now,
# or the --models subset of them. It refuses an unknown or duplicated server
# id, a baseURL that is not http(s), and a server that does not answer or lists
# nothing. It only reads the registry and that list: it never writes
# servers.json and never loads, unloads, or starts a server. --auth-env records
# the sailor's auth_env, and with --from-mlx-serve its token also rides that
# list request; --unlisted-models records unlisted_models, and with
# --from-mlx-serve lets --models name ids the list leaves out. --harness
# <codex|kimi|grok> registers a login sailor on that worker app with the
# --models it takes and the optional --login label, probing nothing; it takes
# no --endpoint, --from-mlx-serve, --host, --auth-env, or --unlisted-models.
#
# set changes the given fields of an existing sailor; its models change only
# through set-model. --no-auth-env and --no-unlisted-models remove those
# fields. In a Privateer home it refuses --placeholder on the
# sailor config/privateer names for the first mate, which runs only on a live
# sailor.
#
# set-model adds <model> to the sailor's models. --model-limit <context>:<output>
# and --model-options <json object> record that model's model_settings, each
# replacing the same field already recorded. With --replace <old> it takes
# <old> out of the list, along with its model_settings, and rewrites every rule and default profile naming
# <sailor> with <old> to name <model>, dropping a profile that then repeats
# another in the same list. With --first-mate it writes <sailor>/<model> as the
# first mate line of config/privateer, in place of the current one. With
# --warm, POST <endpoint>/chat/completions asking <model> for one token must
# answer with a completion within FM_SAILOR_WARM_TIMEOUT seconds (default 600),
# so a server that loads models on demand (mlx-serve lists every pulled model,
# each with a `loaded` flag) loads it now, and a load or memory refusal
# surfaces here rather than in a worker's first request. The warm-up and
# check's message-shape probe are the two requests this script sends that ask
# for a completion, so each spends one token on a paid endpoint. --dry-run prints the
# change and writes nothing. It refuses:
#   - --warm with --dry-run, since a warm-up loads the model;
#   - an unknown sailor, or --replace naming a model the sailor does not list
#     or <model> itself;
#   - --replace while a task record carries sailor=<sailor> and model=<old>,
#     since relaunching that task needs <old> listed;
#   - --replace of the first mate's own <sailor>/<old> without --first-mate;
#   - --first-mate outside a Privateer home, or on a placeholder sailor;
#   - --warm on a placeholder sailor;
#   - for a live sailor, a missing token, an endpoint that does not answer or
#     does not list <model> (unless the sailor has unlisted_models), and with
#     --warm, a failed warm-up.
# A placeholder is not probed, and neither is a login sailor, whose model id
# cannot be checked against a list; set-model refuses --warm and --first-mate
# on a login sailor. When the server lists <model> as not loaded and --warm
# is absent, it says so and names --warm.
#
# retire removes a sailor and every rule and default profile naming it. A rule
# left with no profile is removed, as is a default left empty, and each is
# reported. It refuses while any task record carries sailor=<name>.
#
# sync rewrites this home's sailors from a slot registry, the JSON file MLX
# Serve keeps beside the mlx-serve registry, and in a Privateer home the first
# mate line of config/privateer. It runs only in a home whose
# config/sailor-registry names <registry> (its first line that is not a
# comment, an absolute path or one starting ~/); without that file the home's
# sailors are managed by hand and sync refuses. It reads from the registry:
# `schema`, which must be 1; `homes`, which must map <key> to this home's
# directory; `slots`, each a pre-named sailor that is blank (no `server`,
# `harness`, or `model`) or bound to one `model` on one `server`, an id in
# the mlx-serve registry, or on one `harness` (codex, kimi, or grok), with
# optional `title`, `status` (default placeholder), `capacity` (default 1),
# `homes` (each home's share of that capacity, whole numbers summing to at
# most it), `grade` (one of SAILOR_GRADES below), `facets` (names), `paid`,
# and, on a server, `auth_env`, `unlisted_models`, and `model_settings`, or,
# on a harness, `login` (a label); and `privateer_first_mate`, a slot name. A
# bound slot with a share for <key> becomes the sailor of the same name, in
# registry order: on a server, endpoint the server's baseURL plus /v1, host
# the server's name, models [model], max_concurrent the share, and the other
# fields copied as given; on a harness, that harness, the login label, models
# [model], max_concurrent the share, and grade, facets, and paid as given.
# Every other sailor leaves the map with every rule and default profile naming
# it, as retire removes them, and each removal is reported. In a home with
# config/privateer, privateer_first_mate becomes the first mate line
# <slot>/<model>, written as set-model --first-mate writes it; elsewhere it is
# ignored. sync reads the mlx-serve registry only for each server's baseURL
# and name, probes nothing, and never writes the slot registry, the mlx-serve
# registry, .env, or the Keychain. --dry-run prints the change and writes
# nothing. It refuses, writing nothing:
#   - without config/sailor-registry, when it names another file, or when
#     `homes` does not map <key> to this home;
#   - a registry that is not schema 1 JSON with `homes` and `slots` objects,
#     a privateer_first_mate that is not a string, and, naming the slot, a
#     server or harness without a model or a model without either, a slot
#     with both, a harness outside codex, kimi, and grok, a login slot with
#     auth_env, unlisted_models, or model_settings, a login label on a slot
#     without a harness or that is not safe text (no spaces or quotes), a server the
#     mlx-serve registry does not list exactly once or whose baseURL is not
#     http(s), a capacity or share that is not a whole number, a share for a
#     home `homes` does not name, shares above the capacity, a grade outside
#     SAILOR_GRADES, or facets that are not a list of names;
#   - a sailor leaving the map while a task record carries sailor=<it>, or a
#     model leaving a sailor while one carries sailor=<it> and model=<that>;
#   - a rule or default profile naming a sailor that stays, with a model it
#     no longer lists;
#   - in a Privateer home, a privateer_first_mate that is not a slot, or is
#     a login slot, blank, not shared with <key>, without the `helm` facet,
#     or a placeholder, and a first mate line left on a placeholder sailor;
#   - whatever validate or the Privateer check refuses, as for every registry
#     command.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE resolve the
# home exactly as the other bin/ scripts do.
#
# Exit status: 0 success, 1 invalid (validate) or refused (check, pick, and
# the registry commands), 2 usage or configuration error (including a missing
# or unparseable file, an unknown grade, an unwritable config/, or missing jq
# or curl).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FILE="$CONFIG/crew-dispatch.json"
FLAG="$CONFIG/privateer"
REGISTRY_FLAG="$CONFIG/sailor-registry"
SERVERS_FILE="${FM_MLX_SERVE_SERVERS:-$HOME/.mlx-serve/servers.json}"
# The grades a sailor slot may carry, lowest reasoning class first.
SAILOR_GRADES='["deckhand","sailor","specialist","expert"]'
WORK=
DRY_RUN=0
SAILOR_TOKEN=
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# The grades, lowest first.
GRADES='["deckhand","sailor","specialist","expert"]'
# The worker apps a login sailor runs on, each on its own subscription login.
LOGIN_HARNESSES='["codex","kimi","grok"]'
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-sailor.sh validate | list | grades | status [--all] | health
       fm-sailor.sh check <sailor> <model> [--task <id>]
       fm-sailor.sh pick (--grade <grade> | --sailor <sailor> [--model <model>]) [--grade <grade>] [--facet <facet>] [--spend] [--task <id>]
       fm-sailor.sh provider-json <sailor> <model>
       fm-sailor.sh with-token <variable> <env-file> -- <command> [<arg>...]
       fm-sailor.sh add <sailor> (--endpoint <url> --models <ids> | --from-mlx-serve <server-id> [--models <ids>])
                    [--title <text>] [--host <text>] [--max-concurrent <n>] [--auth-env <variable>] [--unlisted-models]
                    [--live | --placeholder]
       fm-sailor.sh add <sailor> --harness <codex|kimi|grok> --models <ids> [--login <label>]
                    [--title <text>] [--max-concurrent <n>] [--live | --placeholder]
       fm-sailor.sh set <sailor> [--endpoint <url>] [--title <text>] [--host <text>] [--max-concurrent <n>]
                    [--auth-env <variable> | --no-auth-env] [--unlisted-models | --no-unlisted-models] [--live | --placeholder]
       fm-sailor.sh set-model <sailor> <model> [--replace <old>] [--first-mate] [--model-limit <context>:<output>]
                    [--model-options <json>] [--warm] [--dry-run]
       fm-sailor.sh retire <sailor>
       fm-sailor.sh sync <registry> --home <key> [--dry-run]
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

# load_timeouts: the probe, warm-up, sign-in check, and test-prompt and
# message-shape bounds, in whole seconds.
load_timeouts() {
  PROBE_TIMEOUT=${FM_SAILOR_PROBE_TIMEOUT:-3}
  WARM_TIMEOUT=${FM_SAILOR_WARM_TIMEOUT:-600}
  LOGIN_TIMEOUT=${FM_SAILOR_LOGIN_TIMEOUT:-30}
  SMOKE_TIMEOUT=${FM_SAILOR_SMOKE_TIMEOUT:-120}
  case "$PROBE_TIMEOUT" in '' | *[!0-9]*) die "FM_SAILOR_PROBE_TIMEOUT must be whole seconds" ;; esac
  case "$WARM_TIMEOUT" in '' | *[!0-9]*) die "FM_SAILOR_WARM_TIMEOUT must be whole seconds" ;; esac
  case "$LOGIN_TIMEOUT" in '' | *[!0-9]*) die "FM_SAILOR_LOGIN_TIMEOUT must be whole seconds" ;; esac
  case "$SMOKE_TIMEOUT" in '' | *[!0-9]*) die "FM_SAILOR_SMOKE_TIMEOUT must be whole seconds" ;; esac
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

# sailor_exists <sailor>: whether the map holds an entry of that name.
sailor_exists() {
  jq -e --arg s "$1" '.sailors[$s] | type == "object"' "$FILE" >/dev/null 2>&1
}

# token_lookup <variable> <env-file>: sets TOKEN_VALUE as the header describes
# for auth_env; returns 1 with TOKEN_REASON naming the variable, never its
# value. printenv reads the inherited environment, never this script's own
# variables.
token_lookup() {
  local name=$1 file=$2
  TOKEN_VALUE=$(printenv "$name" 2>/dev/null) || TOKEN_VALUE=
  [ -n "$TOKEN_VALUE" ] || TOKEN_VALUE=$(fmx_env_get "$name" "$file")
  if [ -z "$TOKEN_VALUE" ]; then
    TOKEN_REASON="$name is set in neither the environment nor $file"
    return 1
  fi
  case "$TOKEN_VALUE" in
    *[[:space:][:cntrl:]]*)
      TOKEN_VALUE=
      TOKEN_REASON="$name holds whitespace or a control character"
      return 1
      ;;
  esac
}

# sailor_auth <sailor>: sets SAILOR_TOKEN to the sailor's token, empty for a
# sailor without auth_env; returns 1 with AUTH_ENV and TOKEN_REASON set when
# its token is missing.
sailor_auth() {
  SAILOR_TOKEN=
  AUTH_ENV=$(sailor_field "$1" '.auth_env')
  [ -n "$AUTH_ENV" ] || return 0
  token_lookup "$AUTH_ENV" "$FM_HOME/.env" || return 1
  SAILOR_TOKEN=$TOKEN_VALUE
}

# sailor_curl <curl args...>: curl, with SAILOR_TOKEN as the bearer token on a
# header read from a pipe, so it never appears on a command line.
sailor_curl() {
  if [ -n "$SAILOR_TOKEN" ]; then
    curl -H @<(printf 'Authorization: Bearer %s\n' "$SAILOR_TOKEN") "$@"
  else
    curl "$@"
  fi
}

unlisted_models() {  # <sailor>
  [ "$(sailor_field "$1" '.unlisted_models')" = true ]
}

# validate_file <file>: the validate checks on one dispatch file.
validate_file() {
  local err
  jq -e . "$1" >/dev/null 2>&1 || { echo "malformed JSON"; return 1; }
  err=$(jq -r --argjson grades "$GRADES" --argjson login "$LOGIN_HARNESSES" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    def uses: [(.rules // [])[]? | profiles(.use?)[]?] + [profiles(.default?)[]?];
    def safe_text: type == "string" and length > 0 and (test("[[:space:][:cntrl:]\"'"'"'\\\\]") | not);
    def scalar: type == "string" or type == "number" or type == "boolean";
    def word: type == "string" and test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$");
    def is_grade: type == "string" and (. as $g | $grades | index($g)) != null;
    def not_a_grade($who; $g): "\($who) grade \($g | tojson) is not a grade; the grades, lowest first, are \($grades | join(", "))";
    def settings_bad($n; $s):
      ($s.model_settings) as $ms
      | if ($ms | type) != "object" then "sailor \($n) model_settings must be an object"
        else ([$ms | to_entries[] | . as $e | "sailor \($n) model_settings for \($e.key)" as $who
          | if ($s.models | index($e.key)) == null then "sailor \($n) model_settings names \($e.key), which its models do not list"
            elif ($e.value | type) != "object" then "\($who) must be an object"
            elif (($e.value | keys) - ["limit", "options"] | length) > 0 then "\($who) may hold only limit and options"
            elif ($e.value | has("limit")) and (($e.value.limit | type) != "object" or ($e.value.limit | keys) != ["context", "output"] or ([$e.value.limit[] | (type == "number" and . >= 1 and . == floor)] | all | not)) then "\($who) limit must hold both context and output and nothing else, each a positive whole number"
            elif ($e.value | has("options")) and (($e.value.options | type) != "object" or ([$e.value.options[] | scalar] | all | not) or ($e.value.options | keys | any(length == 0))) then "\($who) options must be an object of strings, numbers and booleans"
            else empty
            end] | first // "")
        end;
    def sailor_bad($n; $s):
      if ($n | test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$") | not) then "sailor name \($n) must be lowercase letters, digits and single dashes"
      elif ($s | type) != "object" then "sailor \($n) must be an object"
      elif ($s | has("endpoint")) == ($s | has("harness")) then "sailor \($n) needs an http(s) endpoint or a login harness, not both"
      elif ($s | has("endpoint")) and ((($s.endpoint | safe_text) and ($s.endpoint | test("^https?://[^/]+"))) | not) then "sailor \($n) needs an http(s) endpoint"
      elif ($s | has("harness")) and (($s.harness | type) != "string" or ($login | index($s.harness)) == null) then "sailor \($n) harness must be one of \($login | join(", "))"
      elif ($s | has("harness")) and ($s | has("auth_env") or has("unlisted_models") or has("model_settings") or has("host")) then "sailor \($n) is a login sailor, which takes no auth_env, unlisted_models, model_settings, or host"
      elif ($s | has("login")) and (($s | has("harness")) | not) then "sailor \($n) login names a sign-in label, which only a login sailor carries"
      elif ($s | has("login")) and (($s.login | safe_text) | not) then "sailor \($n) login must be a non-empty string without spaces or quotes"
      elif (["live", "placeholder"] | index($s.status)) == null then "sailor \($n) status must be live or placeholder"
      elif ($s.models | type) != "array" or ($s.models | length) == 0 then "sailor \($n) needs a non-empty models list"
      elif ($s.models | all(safe_text)) | not then "sailor \($n) models must be non-empty strings without spaces or quotes"
      elif ($s | has("max_concurrent")) and ((($s.max_concurrent | type) != "number") or $s.max_concurrent < 1 or ($s.max_concurrent | floor) != $s.max_concurrent) then "sailor \($n) max_concurrent must be a positive whole number"
      elif ($s | has("title")) and (($s.title | type) != "string") then "sailor \($n) title must be a string"
      elif ($s | has("host")) and (($s.host | type) != "string") then "sailor \($n) host must be a string"
      elif ($s | has("auth_env")) and ((($s.auth_env | type) != "string") or ($s.auth_env | test("^[A-Za-z_][A-Za-z0-9_]*$") | not)) then "sailor \($n) auth_env must name an environment variable"
      elif ($s | has("unlisted_models")) and (($s.unlisted_models | type) != "boolean") then "sailor \($n) unlisted_models must be true or false"
      elif ($s | has("grade")) and ($s.grade | is_grade | not) then not_a_grade("sailor \($n)"; $s.grade)
      elif ($s | has("grade")) and ($s.models | length) != 1 then "sailor \($n) has a grade, which describes one bound model, so it must list exactly one model"
      elif ($s | has("facets")) and ((($s.facets | type) != "array") or ($s.facets | all(word) | not) or (($s.facets | unique | length) != ($s.facets | length))) then "sailor \($n) facets must be a list of distinct lowercase words joined by single dashes"
      elif ($s | has("paid")) and (($s.paid | type) != "boolean") then "sailor \($n) paid must be true or false"
      elif ($s | has("model_settings")) and (settings_bad($n; $s) != "") then settings_bad($n; $s)
      else empty
      end;
    def ref_bad($map):
      .sailor as $n
      | .model as $m
      | if ($n | type) != "string" then "profile sailor must be a string"
        elif ($map | has($n)) | not then "profile names unknown sailor \($n)"
        elif .harness != ($map[$n].harness // "opencode") then "sailor \($n) profile must use harness \($map[$n].harness // "opencode")"
        elif has("grade") then "sailor \($n) profile names a grade too; a profile names a sailor or a grade, not both"
        elif (has("model") | not) and ($map[$n].models | length) != 1 then "sailor \($n) profile names no model, and \($n) lists several; name one"
        elif (has("model") | not) then empty
        elif ($m | type) != "string" then "sailor \($n) profile needs a model"
        elif (($map[$n].models | type) != "array") or (($map[$n].models | index($m)) == null) then "model \($m) is not listed for sailor \($n)"
        else empty
        end;
    def grade_ref_bad:
      if (.grade | is_grade | not) then not_a_grade("profile"; .grade)
      elif .harness != "opencode" then "grade \(.grade) profile must use harness opencode"
      elif has("model") then "grade \(.grade) profile names a model; the sailor bin/fm-sailor.sh pick chooses brings its own"
      else empty
      end;
    (.sailors // {}) as $map
    | if has("sailors") and (.sailors | type) != "object" then "sailors must be an object"
      else
        ([($map | to_entries[] | sailor_bad(.key; .value))]
         + [uses[] | select(type == "object" and has("sailor")) | ref_bad($map)]
         + [uses[] | select(type == "object" and has("grade") and (has("sailor") | not)) | grade_ref_bad]
         + [(.rules // [])[]? | select(type == "object" and has("spend") and .spend != "allowed") | "rule \(.when | tojson) spend must be \"allowed\" when present"]
         + (if has("sailor_fallback") then
              (profiles(.sailor_fallback)) as $fb
              | if (.sailor_fallback | type) == "array" and (.sailor_fallback | length) == 0 then ["sailor_fallback needs at least one profile"]
                elif ($fb | length) == 0 then ["sailor_fallback must be a profile object or non-empty profile array"]
                elif ($fb | any(type != "object")) then ["each sailor_fallback profile must be an object"]
                elif ($fb | any((.harness | type) != "string" or (.harness | length) == 0)) then ["each sailor_fallback profile needs harness"]
                elif ($fb | any(has("sailor"))) then ["sailor_fallback must not name a sailor"]
                elif ($fb | any(has("grade"))) then ["sailor_fallback must not name a grade"]
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
    | "\(.key) status=\(.value.status) \(if .value.harness then "harness=\(.value.harness)" else "endpoint=\(.value.endpoint)" end) max_concurrent=\(.value.max_concurrent // 1)\(if .value.grade then " grade=\(.value.grade)" else "" end) models=\(.value.models | join(","))\(if .value.login then " login=\(.value.login)" else "" end)\(if .value.auth_env then " auth_env=\(.value.auth_env)" else "" end)\(if .value.unlisted_models then " unlisted_models=true" else "" end)"' "$FILE"
}

# sailor_load <sailor> <model>: shared lookup for check and provider-json.
sailor_load() {
  local sailor=$1 model=$2
  load_valid
  sailor_exists "$sailor" || refuse "unknown sailor $sailor"
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
  sailor_curl -fsS --proto '=http,https' --max-time "$PROBE_TIMEOUT" "${1%/}/models" 2>/dev/null
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

# chat_completion <endpoint> <payload> <bound>: POST <payload> to
# <endpoint>/chat/completions and read a completion within <bound> seconds; on
# failure prints the reason and returns 1.
chat_completion() {
  local endpoint=$1 payload=$2 bound=$3 out code body reason
  if ! out=$(printf '%s' "$payload" |
    sailor_curl -sS --proto '=http,https' --max-time "$bound" -H 'Content-Type: application/json' \
      --data-binary @- -w '\n%{http_code}' "${endpoint%/}/chat/completions" 2>/dev/null); then
    echo "no completion from $endpoint within $bound seconds"
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

# warm_model <endpoint> <model>: one one-token chat completion; on failure
# prints the reason and returns 1.
warm_model() {
  local payload
  payload=$(jq -nc --arg m "$2" '{model: $m, messages: [{role: "user", content: "Reply with OK."}], max_tokens: 1, stream: false}')
  chat_completion "$1" "$payload" "$WARM_TIMEOUT"
}

# probe_completion <endpoint> <model> <bound>: one one-token chat completion in the
# message shape OpenCode sends, two leading system messages then the user
# message, within <bound> seconds; on failure prints the reason and returns 1.
probe_completion() {
  local payload
  payload=$(jq -nc --arg m "$2" '{model: $m, messages: [
    {role: "system", content: "You are a helpful assistant."},
    {role: "system", content: "Reply with the single word OK."},
    {role: "user", content: "Reply with the single word OK."}], max_tokens: 1, stream: false}')
  chat_completion "$1" "$payload" "$3"
}

# origin_of <url>: scheme and authority, without the path.
origin_of() {
  local rest=${1#*://}
  printf '%s://%s\n' "${1%%://*}" "${rest%%[/?#]*}"
}

# server_queue <endpoint>: `running=<n> waiting=<n>` from the server's vLLM
# gauges, or nothing.
server_queue() {
  sailor_curl -fsS --proto '=http,https' --max-time "$PROBE_TIMEOUT" "$(origin_of "$1")/metrics" 2>/dev/null | awk '
    $1 ~ /^vllm:num_requests_running($|[{])/ { r += $2; hr = 1 }
    $1 ~ /^vllm:num_requests_waiting($|[{])/ { w += $2; hw = 1 }
    END { if (hr && hw) printf "running=%d waiting=%d\n", r, w }'
}

# login_env: CLEAN_ENV, the `env -i` prefix a sign-in check runs under: HOME
# and PATH, plus TMPDIR, USER, and LOGNAME when set, so the worker app sees
# the login it will run on and never an ambient API key, as
# bin/fm-worker-account-lib.sh clears the environment for a pinned account.
login_env() {
  CLEAN_ENV=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}")
  [ -z "${TMPDIR:-}" ] || CLEAN_ENV+=("TMPDIR=$TMPDIR")
  [ -z "${USER:-}" ] || CLEAN_ENV+=("USER=$USER")
  [ -z "${LOGNAME:-}" ] || CLEAN_ENV+=("LOGNAME=$LOGNAME")
}

# login_up <harness> [full]: whether the worker app is signed in, by its local
# sign-in evidence within the probe timeout, or with `full` by the full check
# the header describes. Returns 1 with LOGIN_REASON set when it is not.
login_up() {
  local harness=$1 full=${2:-} bin rc grok_home scratch bound=$PROBE_TIMEOUT
  LOGIN_REASON=
  [ "$full" != full ] || bound=$LOGIN_TIMEOUT
  login_env
  bin=$(command -v "$harness" 2>/dev/null) || { LOGIN_REASON="$harness is not installed"; return 1; }
  case "$harness" in
    codex)
      fm_run_timed "$bound" "${CLEAN_ENV[@]}" "$bin" login status >/dev/null 2>&1 </dev/null
      rc=$?
      if fm_timed_out "$rc"; then
        LOGIN_REASON="codex login status did not answer within $bound seconds"
        return 1
      fi
      [ "$rc" = 0 ] || { LOGIN_REASON="codex login status reports no login (exit $rc)"; return 1; }
      ;;
    grok)
      grok_home=${GROK_HOME:-${HOME:-}/.grok}
      [ -f "$grok_home/auth.json" ] || { LOGIN_REASON="no $grok_home/auth.json, so grok holds no login"; return 1; }
      [ "$full" = full ] || return 0
      fm_run_timed "$LOGIN_TIMEOUT" "${CLEAN_ENV[@]}" "GROK_HOME=$grok_home" "$bin" models >/dev/null 2>&1 </dev/null
      rc=$?
      if fm_timed_out "$rc"; then
        LOGIN_REASON="grok models did not answer within $LOGIN_TIMEOUT seconds"
        return 1
      fi
      [ "$rc" = 0 ] || { LOGIN_REASON="grok models failed (exit $rc), so its login is not usable"; return 1; }
      ;;
    kimi)
      set -- "${HOME:-}"/.kimi-code/credentials/kimi-code-env-*.json
      [ -f "$1" ] || { LOGIN_REASON="no credentials file under ${HOME:-}/.kimi-code/credentials, so kimi holds no login"; return 1; }
      [ "$full" = full ] || return 0
      scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-sailor-smoke.XXXXXX") || { LOGIN_REASON="cannot create a scratch directory for the kimi test prompt"; return 1; }
      (cd "$scratch" && fm_run_timed "$SMOKE_TIMEOUT" "${CLEAN_ENV[@]}" "$bin" -p "Reply with the single word OK." --output-format text >/dev/null 2>&1 </dev/null)
      rc=$?
      rm -rf "$scratch"
      if fm_timed_out "$rc"; then
        LOGIN_REASON="kimi did not answer a test prompt within $SMOKE_TIMEOUT seconds"
        return 1
      fi
      [ "$rc" = 0 ] || { LOGIN_REASON="kimi refused a test prompt (exit $rc), so its login is not usable"; return 1; }
      ;;
    *) LOGIN_REASON="$harness takes no login sailor"; return 1 ;;
  esac
}

cmd_check() {
  local sailor=$1 model=$2 exclude=$3 endpoint harness status max busy body state note reason bound
  sailor_load "$sailor" "$model"
  endpoint=$(sailor_field "$sailor" '.endpoint')
  harness=$(sailor_field "$sailor" '.harness')
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
  if [ -n "$harness" ]; then
    load_timeouts
    login_up "$harness" full || refuse "sailor $sailor is signed out of $harness: $LOGIN_REASON"
    echo "ok: sailor $sailor runs $model on its $harness login ($busy of $max tasks busy; signed in)"
    return 0
  fi
  need_curl
  load_timeouts
  sailor_auth "$sailor" || refuse "sailor $sailor has no token: $TOKEN_REASON"
  body=$(fetch_models "$endpoint") || refuse "sailor $sailor is not answering at $endpoint"
  state=$(model_state "$body" "$model")
  [ "$state" != missing ] || ! unlisted_models "$sailor" || state=unlisted
  [ "$state" != missing ] || refuse "sailor $sailor at $endpoint does not serve $model"
  bound=$SMOKE_TIMEOUT
  case "$state" in
    loaded) note="; model loaded" ;;
    unloaded)
      bound=$WARM_TIMEOUT
      note="; model was listed but not loaded, so the probe loaded it"
      ;;
    unlisted) note="; model not in the endpoint's list, which this sailor's unlisted_models allows" ;;
    *) note= ;;
  esac
  reason=$(probe_completion "$endpoint" "$model" "$bound") || {
    [ "$state" != unloaded ] || reason="$reason (the model was listed but not loaded, so the probe also had to load it)"
    refuse "sailor $sailor at $endpoint did not answer a one-token request in OpenCode's message shape (two leading system messages, then the user message): $reason"
  }
  echo "ok: sailor $sailor serves $model at $endpoint ($busy of $max tasks busy$note)"
}

# grade_rank <grade>: the grade's place, 1 for the lowest; fails for anything
# else.
grade_rank() {
  jq -en --argjson grades "$GRADES" --arg g "$1" '$grades | index($g) | if . == null then halt_error(1) else . + 1 end' 2>/dev/null
}

# pick_candidates <sailor> <model> <floor> <facet> <spend>: one line per
# candidate, in the order pick weighs them: `try<TAB><sailor><TAB><model>`, or
# `skip<TAB><sailor>/<model><TAB><reason>` for one a gate before check refuses.
pick_candidates() {
  # shellcheck disable=SC2016 # jq, not the shell, expands the $ names.
  jq -r --argjson grades "$GRADES" --arg s "$1" --arg m "$2" --argjson floor "$3" --arg facet "$4" --argjson spend "$5" '
    (if $floor > 0 then $grades[$floor - 1] else "" end) as $fg
    | def rank: ((.grade // null) as $g | if $g == null then 0 else ($grades | index($g)) + 1 end);
      def has_facet: $facet == "" or ((.facets // []) | index($facet)) != null;
      def gates($n; $label):
        if $floor > 0 and rank == 0 then "skip\t\($label)\tsailor \($n) has no grade, so it cannot meet grade \($fg)"
        elif rank < $floor then "skip\t\($label)\tsailor \($n) is grade \(.grade), below \($fg)"
        elif has_facet | not then "skip\t\($label)\tsailor \($n) has no facet \($facet)"
        elif .paid == true and ($spend | not) then "skip\t\($label)\tsailor \($n) is paid, and spend is not allowed for this task"
        else empty end;
    (.sailors // {}) as $map
    | if $s != "" then
        $map[$s] as $x
        | if $x == null then "skip\t\($s)\tunknown sailor \($s)"
          elif $m == "" and ($x.models | length) != 1 then "skip\t\($s)\tsailor \($s) lists several models (\($x.models | join(", "))); name one with --model"
          else ($m | if . == "" then $x.models[0] else . end) as $model
            | ($x | gates($s; "\($s)/\($model)")) // "try\t\($s)\t\($model)"
          end
      else
        [$map | to_entries[] | select(.value.status == "live" and (.value | rank) >= $floor and (.value | has_facet))]
        | to_entries | map({i: .key, n: .value.key, x: .value.value})
        | sort_by([(.x | rank), (if .x.paid == true then 1 else 0 end), .i])[]
        | .n as $n | .x.models[0] as $model
        | (.x | gates($n; "\($n)/\($model)")) // "try\t\($n)\t\($model)"
      end' "$FILE"
}

cmd_pick() {
  local sailor='' model='' floor=0 facet='' spend=false task='' rank lines kind name third out rc grade
  local -a reasons=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --grade)
        [ "$#" -ge 2 ] || usage
        rank=$(grade_rank "$2") || die "unknown grade '$2'; the grades, lowest first, are $(jq -r 'join(", ")' <<<"$GRADES")"
        [ "$rank" -le "$floor" ] || floor=$rank
        shift 2
        ;;
      --sailor) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; sailor=$2; shift 2 ;;
      --model) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; model=$2; shift 2 ;;
      --facet) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; facet=$2; shift 2 ;;
      --spend) spend=true; shift ;;
      --task) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; task=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$sailor" ] || [ "$floor" -gt 0 ] || usage
  [ -z "$model" ] || [ -n "$sailor" ] || usage
  load_valid
  lines=$(pick_candidates "$sailor" "$model" "$floor" "$facet" "$spend") || die "could not read the sailors from config/crew-dispatch.json"
  while IFS=$'\t' read -r kind name third; do
    case "$kind" in
      skip) reasons+=("$name: $third") ;;
      try)
        rc=0
        out=$(cmd_check "$name" "$third" "$task" 2>&1) || rc=$?
        if [ "$rc" = 0 ]; then
          printf '%s %s\n' "$name" "$third"
          return 0
        fi
        [ "$rc" = 1 ] || die "${out#fm-sailor: }"
        reasons+=("$name/$third: ${out#refused: }")
        ;;
    esac
  done <<<"$lines"
  [ -z "$sailor" ] || refuse "${reasons[0]#*: }"
  grade=$(jq -r --argjson f "$floor" '.[$f - 1]' <<<"$GRADES")
  [ "${#reasons[@]}" -gt 0 ] || refuse "no live sailor has grade $grade or above${facet:+ and facet $facet}"
  echo "refused: no sailor of grade $grade or above${facet:+ with facet $facet} can take it now:"
  printf '  %s\n' "${reasons[@]}"
  exit 1
}

cmd_provider_json() {
  local sailor=$1 model=$2 harness
  sailor_load "$sailor" "$model"
  harness=$(sailor_field "$sailor" '.harness')
  [ -z "$harness" ] || refuse "sailor $sailor is a login sailor on $harness, which runs as its own worker app and takes no OpenCode provider"
  jq -c --arg s "$sailor" --arg m "$model" '
    .sailors[$s] as $x
    | {($s): {npm: "@ai-sdk/openai-compatible", name: ($x.title // $s),
              options: ({baseURL: $x.endpoint} + (if $x.auth_env then {apiKey: "{env:\($x.auth_env)}"} else {} end)),
              models: {($m): ({name: $m} + ($x.model_settings[$m] // {}))}}}' "$FILE"
}

# status_line <sailor> <url>: the one status line for a sailor.
status_line() {
  local name=$1 url=$2 status endpoint harness login max busy body queue models m state states grade
  status=$(sailor_field "$name" '.status')
  grade=$(sailor_field "$name" '.grade')
  grade=${grade:+ grade=$grade}
  endpoint=$(sailor_field "$name" '.endpoint')
  harness=$(sailor_field "$name" '.harness')
  max=$(sailor_field "$name" '.max_concurrent')
  busy=$(busy_count "$name" "")
  if [ -n "$harness" ]; then
    login=$(sailor_field "$name" '.login')
    login=${login:+ login=$login}
    if probe_up "$url"; then
      state=answering
      states=signed-in
    else
      state=not-answering
      states=signed-out
    fi
    models=$(jq -r --arg s "$name" --arg st "$states" '.sailors[$s].models | map("\(.)(\($st))") | join(",")' "$FILE")
    echo "$name $status $state harness=$harness tasks=$busy/${max:-1}$grade models=$models$login"
    return 0
  fi
  if ! sailor_auth "$name"; then
    echo "$name $status no-token endpoint=$endpoint tasks=$busy/${max:-1}$grade auth_env=$AUTH_ENV"
    return 0
  fi
  if ! probe_up "$url"; then
    echo "$name $status not-answering endpoint=$endpoint tasks=$busy/${max:-1}$grade"
    return 0
  fi
  queue=$(server_queue "$endpoint")
  states=
  if body=$(fetch_models "$endpoint"); then
    models=$(jq -r --arg s "$name" '.sailors[$s].models[]' "$FILE")
    while IFS= read -r m; do
      state=$(model_state "$body" "$m")
      [ "$state" != missing ] || ! unlisted_models "$name" || state=unlisted
      states="$states${states:+,}$m($state)"
    done <<<"$models"
  fi
  echo "$name $status answering endpoint=$endpoint tasks=$busy/${max:-1}$grade${queue:+ $queue}${states:+ models=$states}"
}

cmd_status() {
  local all=$1 targets name url n=0
  load_valid
  need_curl
  load_timeouts
  targets=$(health_targets "$all") || die "could not read the sailors from config/crew-dispatch.json"
  if [ -z "$targets" ]; then
    if [ "$all" = true ]; then echo "no sailors"; else echo "no live sailors"; fi
    return 0
  fi
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-sailor.XXXXXX") || die "cannot create a scratch directory"
  trap cleanup EXIT
  # Every sailor is probed at once, so a down sailor adds no time to the rest.
  while IFS=$'\t' read -r name url; do
    n=$((n + 1))
    status_line "$name" "$url" > "$WORK/$n" &
  done <<<"$targets"
  wait
  n=0
  while IFS=$'\t' read -r name url; do
    n=$((n + 1))
    cat "$WORK/$n"
  done <<<"$targets"
}

# probe_up <target>: whether a health target answers: for `login:<harness>`,
# the worker app's local sign-in evidence; otherwise whether GET <target> answers
# without an HTTP error status within the probe timeout.
probe_up() {
  case "$1" in
    login:*) login_up "${1#login:}" ;;
    *) sailor_curl -fsS -o /dev/null --proto '=http,https' --max-time "$PROBE_TIMEOUT" "$1" >/dev/null 2>&1 ;;
  esac
}

# health_targets <all>: `<sailor>\t<target>` for each live sailor, or each
# sailor when <all> is true: the URL its health probe reads (see the header),
# or `login:<harness>` for a login sailor.
health_targets() {
  local registry='{}'
  if [ -f "$SERVERS_FILE" ] && jq -e '.servers | type == "array"' "$SERVERS_FILE" >/dev/null 2>&1; then
    registry=$(jq -c . "$SERVERS_FILE")
  fi
  jq -r --argjson reg "$registry" --argjson all "$1" '
    [$reg.servers[]?
     | select(type == "object" and (.baseURL | type) == "string" and (.healthPath | type) == "string" and (.healthPath | length) > 0)
     | {base: (.baseURL | sub("/+$"; "")), health: .healthPath}] as $servers
    | (.sailors // {}) | to_entries[] | select($all or .value.status == "live")
    | if .value.harness then "\(.key)\tlogin:\(.value.harness)"
      else
        (.value.endpoint | sub("/+$"; "")) as $e
        | ([$servers[] | .base as $b | select($b != "" and ($e == $b or ($e | startswith($b + "/"))))] | max_by(.base | length)) as $m
        | "\(.key)\t\(if $m then $m.base + "/" + ($m.health | ltrimstr("/")) else $e + "/models" end)"
      end' "$FILE"
}

cmd_with_token() {
  local name=$1 file=$2
  shift 2
  case "$name" in '' | [!A-Za-z_]* | *[!A-Za-z0-9_]*) die "with-token takes an environment variable name" ;; esac
  token_lookup "$name" "$file" || refuse "$TOKEN_REASON, so the sailor's token is missing"
  export "$name=$TOKEN_VALUE"
  exec "$@"
}

cmd_health() {
  local targets name url state n=0
  load_valid
  need_curl
  load_timeouts
  targets=$(health_targets false) || die "could not read the sailors from config/crew-dispatch.json"
  [ -n "$targets" ] || return 0
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-sailor.XXXXXX") || die "cannot create a scratch directory"
  trap cleanup EXIT
  while IFS=$'\t' read -r name url; do
    n=$((n + 1))
    { sailor_auth "$name" && probe_up "$url" && echo up || echo down; } > "$WORK/$n" &
  done <<<"$targets"
  wait
  n=0
  while IFS=$'\t' read -r name url; do
    n=$((n + 1))
    state=$(cat "$WORK/$n" 2>/dev/null)
    [ "$state" = up ] || state=down
    printf '%s %s %s\n' "$name" "$state" "$url"
  done <<<"$targets"
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

# first_mate_rewrite <sailor>/<model>: config/privateer with that first mate
# line in place of the current one, keeping every comment.
first_mate_rewrite() {
  awk -v v="$1" '
    { line = $0; sub(/#.*/, "", line) }
    !done && line ~ /[^[:space:]]/ { print v; done = 1; next }
    { print }
    END { if (!done) print v }' "$FLAG"
}

# expand_home <path>: <path>, with a leading ~/ read as $HOME/.
expand_home() {
  case "$1" in
    \~/*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# registry_path: the slot registry config/sailor-registry names, or empty when
# the file is absent or names nothing.
registry_path() {
  [ -f "$REGISTRY_FLAG" ] || return 0
  sed -e 's/#.*//' "$REGISTRY_FLAG" 2>/dev/null |
    awk 'NF { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }'
}

# hand_edit_note: after a written hand edit in a home whose sailors follow a
# slot registry, say that the next sync rewrites them.
hand_edit_note() {
  local path
  [ "$WROTE_DISPATCH$WROTE_PRIVATEER" != 00 ] || return 0
  path=$(registry_path)
  [ -n "$path" ] || return 0
  echo "note: this home's sailors follow $path (config/sailor-registry), so the next sync rewrites them from it"
}

# STRIP_JQ: jq definitions for removing every profile that names a sailor in
# $gone, with any rule or default left without a profile (retire and sync).
# shellcheck disable=SC2016 # jq, not the shell, expands the $ names.
STRIP_JQ='
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def gone: type == "object" and ((.sailor | type) == "string") and (.sailor as $n | any($gone[]; . == $n));
  def strip: if type == "array" then map(select(gone | not)) elif gone then [] else . end;
  def emptied: type == "array" and length == 0;
  def drop_gone:
    (if (.rules | type) == "array" then
       .rules |= map(if type == "object" and has("use") and ((.use | emptied) | not) and (.use | strip | emptied) then empty
                     elif type == "object" and has("use") then .use |= strip
                     else . end)
     else . end)
    | (if has("default") and ((.default | emptied) | not) and (.default | strip | emptied) then del(.default)
       elif has("default") then .default |= strip
       else . end);
  def emptied_report:
    [(.rules // [])[]? | select(type == "object")
     | select((profiles(.use?) | length) > 0 and (profiles(.use?) | all(gone)))
     | "removed rule \"\(.when)\", which offered only \([profiles(.use?)[].sailor] | unique | join(", "))"]
    + (if (profiles(.default?) | length) > 0 and (profiles(.default?) | all(gone))
       then ["removed the default, which offered only \([profiles(.default?)[].sailor] | unique | join(", "))"] else [] end);
'

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
# the model, and its settings.
first_mate_view() {
  jq -c --arg s "${2%%/*}" --arg m "${2#*/}" '
    (.sailors // {})[$s] // {} | {endpoint, status, serves: ((.models // []) | index($m) != null), settings: (.model_settings[$m] // null)}' "$1"
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
    echo "egress: a running Privateer session allows a new endpoint only after fm-privateer.sh reload"
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
# the mlx-serve registry and the server's live model list, read with
# SAILOR_TOKEN when the caller set one.
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
  body=$(sailor_curl -fsS --proto '=http,https' --max-time "$PROBE_TIMEOUT" "$url" 2>/dev/null) ||
    refuse "mlx-serve server $id is not answering at $url$hint; fm-sailor.sh never starts a server"
  LIVE_MODELS=$(printf '%s' "$body" | jq -c '[.data[]?.id? | strings]' 2>/dev/null) || LIVE_MODELS='[]'
  [ "$LIVE_MODELS" != '[]' ] || refuse "mlx-serve server $id lists no models at $url"
  ENDPOINT="$base/v1"
}

cmd_add() {
  local name title='' host='' endpoint='' models='' max='' status=placeholder from='' has_title=0 has_host=0 entry models_array missing
  local auth_env='' unlisted=false harness='' login=''
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
      --auth-env) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; auth_env=$2; shift 2 ;;
      --unlisted-models) unlisted=true; shift ;;
      --harness) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; harness=$2; shift 2 ;;
      --login) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; login=$2; shift 2 ;;
      --live) status=live; shift ;;
      --placeholder) status=placeholder; shift ;;
      *) usage ;;
    esac
  done
  if [ -n "$from" ]; then
    [ -z "$endpoint" ] && [ -z "$harness" ] || usage
  elif [ -n "$harness" ]; then
    [ -z "$endpoint" ] && [ -n "$models" ] || usage
  else
    [ -n "$endpoint" ] && [ -n "$models" ] || usage
  fi
  [ -z "$login" ] || [ -n "$harness" ] || usage
  case "$max" in '' | *[!0-9]*) [ -z "$max" ] || refuse "--max-concurrent must be a positive whole number" ;; esac
  begin_edit
  ! sailor_exists "$name" || refuse "sailor $name already exists; change it with set or set-model"
  models_array=$(models_json "$models")
  if [ -n "$from" ]; then
    if [ -n "$auth_env" ]; then
      case "$auth_env" in [!A-Za-z_]* | *[!A-Za-z0-9_]*) refuse "sailor $name auth_env must name an environment variable" ;; esac
      token_lookup "$auth_env" "$FM_HOME/.env" || refuse "sailor $name has no token: $TOKEN_REASON"
      SAILOR_TOKEN=$TOKEN_VALUE
    fi
    mlx_server "$from"
    endpoint=$ENDPOINT
    if [ -n "$models" ]; then
      missing=$(jq -rn --argjson want "$models_array" --argjson live "$LIVE_MODELS" '[$want[] | select(. as $m | $live | index($m) | not)] | join(", ")')
      [ -z "$missing" ] || [ "$unlisted" = true ] || refuse "mlx-serve server $from does not list $missing"
    else
      models_array=$LIVE_MODELS
    fi
  fi
  entry=$(jq -nc --arg title "$title" --argjson has_title "$has_title" --arg host "$host" --argjson has_host "$has_host" \
    --arg endpoint "$endpoint" --arg harness "$harness" --arg login "$login" \
    --arg status "$status" --argjson models "$models_array" --arg max "$max" \
    --arg auth_env "$auth_env" --argjson unlisted "$unlisted" '
    (if $has_title == 1 then {title: $title} else {} end)
    + (if $has_host == 1 then {host: $host} else {} end)
    + (if $harness != "" then {harness: $harness} + (if $login != "" then {login: $login} else {} end) else {endpoint: $endpoint} end)
    + {status: $status, models: $models}
    + (if $max != "" then {max_concurrent: ($max | tonumber)} else {} end)
    + (if $auth_env != "" then {auth_env: $auth_env} else {} end)
    + (if $unlisted then {unlisted_models: true} else {} end)')
  # shellcheck disable=SC2016 # jq, not the shell, expands the $ names.
  compose --arg s "$name" --argjson e "$entry" '.sailors = ((.sailors // {}) + {($s): $e})'
  guard_candidate
  commit || true
  if [ -n "$harness" ]; then
    echo "added sailor $name ($status) on its $harness login serving $(jq -r 'join(",")' <<<"$models_array")"
  else
    echo "added sailor $name ($status) at $endpoint serving $(jq -r 'join(",")' <<<"$models_array")"
  fi
  report_effects
  hand_edit_note
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
      --auth-env)
        [ "$#" -ge 2 ] && [ -n "$2" ] || usage
        patch=$(jq -c --arg v "$2" '. + {auth_env: $v}' <<<"$patch")
        shift 2
        ;;
      --no-auth-env) patch=$(jq -c '. + {auth_env: null}' <<<"$patch"); shift ;;
      --unlisted-models) patch=$(jq -c '. + {unlisted_models: true}' <<<"$patch"); shift ;;
      --no-unlisted-models) patch=$(jq -c '. + {unlisted_models: null}' <<<"$patch"); shift ;;
      *) usage ;;
    esac
  done
  [ "$patch" != '{}' ] || usage
  begin_edit
  sailor_exists "$name" || refuse "unknown sailor $name"
  line=$(first_mate_line)
  if [ "$(jq -r '.status // empty' <<<"$patch")" = placeholder ] && privateer_on && [ "${line%%/*}" = "$name" ]; then
    refuse "the first mate runs on $line, and the first mate runs only on a live sailor"
  fi
  # shellcheck disable=SC2016 # jq, not the shell, expands the $ names.
  compose --arg s "$name" --argjson p "$patch" '.sailors[$s] += $p | .sailors[$s] |= with_entries(select(.value != null))'
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
  hand_edit_note
}

cmd_set_model() {
  local name model old='' first_mate=0 warm=0 limit='' options='' settings status endpoint harness replaced ids body state='' reason line
  [ "$#" -ge 2 ] || usage
  name=$1 model=$2
  shift 2
  case "$name$model" in -*) usage ;; esac
  case "$model" in '' | -*) usage ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --replace) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; old=$2; shift 2 ;;
      --first-mate) first_mate=1; shift ;;
      --model-limit) [ "$#" -ge 2 ] || usage; limit=$2; shift 2 ;;
      --model-options) [ "$#" -ge 2 ] || usage; options=$2; shift 2 ;;
      --warm) warm=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      *) usage ;;
    esac
  done
  [ "$warm" = 0 ] || [ "$DRY_RUN" = 0 ] || refuse "--dry-run loads nothing, so it takes no --warm"
  settings=$(jq -nc --arg limit "$limit" --arg options "$options" '
    (if $limit == "" then {} else ([$limit | capture("^(?<context>[0-9]+):(?<output>[0-9]+)$")] | if length == 0 then error("limit") else {limit: (.[0] | map_values(tonumber))} end) end)
    + (if $options == "" then {} else {options: ($options | fromjson)} end)' 2>/dev/null) ||
    refuse "--model-limit takes <context>:<output> and --model-options takes a JSON object"
  begin_edit
  status=$(sailor_field "$name" '.status')
  [ -n "$status" ] || refuse "unknown sailor $name"
  endpoint=$(sailor_field "$name" '.endpoint')
  harness=$(sailor_field "$name" '.harness')
  [ -z "$harness" ] || [ "$first_mate" = 0 ] || refuse "sailor $name is a login sailor on $harness, and the first mate runs only on an endpoint sailor"
  [ -z "$harness" ] || [ "$warm" = 0 ] || refuse "sailor $name is a login sailor on $harness, and a login sailor is never warmed"
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
  compose --arg s "$name" --arg m "$model" --arg old "$old" --argjson settings "$settings" '
    def dedupe: reduce .[] as $p ([]; if any(.[]; . == $p) then . else . + [$p] end);
    def swap: if type == "object" and .sailor == $s and .model == $old then .model = $m else . end;
    def fix: if type == "array" then map(swap) | dedupe else swap end;
    .sailors[$s].models |= ((if $old != "" then map(if . == $old then $m else . end) else . end) + [$m] | dedupe)
    | (if $old != "" and ((.sailors[$s].model_settings // null) != null) then .sailors[$s].model_settings |= del(.[$old]) else . end)
    | (if $settings != {} then .sailors[$s].model_settings[$m] = ((.sailors[$s].model_settings[$m] // {}) + $settings) else . end)
    | (if (.sailors[$s].model_settings // null) == {} then del(.sailors[$s].model_settings) else . end)
    | if $old == "" then .
      else (if (.rules | type) == "array" then .rules |= map(if type == "object" and has("use") then .use |= fix else . end) else . end)
        | (if has("default") then .default |= fix else . end)
      end'
  if [ "$first_mate" = 1 ]; then
    first_mate_rewrite "$name/$model" > "$WORK/privateer"
  fi
  guard_candidate
  if [ -n "$harness" ]; then
    echo "note: $name is a login sailor on $harness, so $model was not probed"
  elif [ "$status" = live ]; then
    need_curl
    load_timeouts
    sailor_auth "$name" || refuse "sailor $name has no token: $TOKEN_REASON"
    body=$(fetch_models "$endpoint") || refuse "sailor $name is not answering at $endpoint"
    state=$(model_state "$body" "$model")
    [ "$state" != missing ] || ! unlisted_models "$name" || state=unlisted
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
  hand_edit_note
}

cmd_retire() {
  local name ids removed gone
  [ "$#" -eq 1 ] || usage
  name=$1
  case "$name" in '' | -*) usage ;; esac
  begin_edit
  sailor_exists "$name" || refuse "unknown sailor $name"
  ids=$(sailor_tasks "$name" "" | paste -sd, -)
  [ -z "$ids" ] || refuse "task(s) $ids run on $name; retire it once they land"
  removed=$(jq --arg s "$name" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    [((.rules // [])[]? | profiles(.use?)[]?), profiles(.default?)[]?
     | select(type == "object" and .sailor == $s)] | length' "$FILE")
  gone=$(jq -nc --arg s "$name" '[$s]')
  jq -r --argjson gone "$gone" "$STRIP_JQ emptied_report[]" "$FILE" > "$WORK/emptied"
  compose --argjson gone "$gone" "$STRIP_JQ del(.sailors[\$gone[0]]) | drop_gone"
  guard_candidate
  commit || true
  echo "retired sailor $name and the $removed profile(s) naming it"
  cat "$WORK/emptied"
  report_effects
  hand_edit_note
}

# registry_problem <registry-json> <servers-json>: the first reason the slot
# registry cannot be projected, or nothing.
registry_problem() {
  jq -nr --argjson reg "$1" --argjson srv "$2" --argjson grades "$SAILOR_GRADES" --argjson login "$LOGIN_HARNESSES" --arg file "$SERVERS_FILE" '
    def whole: type == "number" and . == floor;
    def name: type == "string" and test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$");
    def safe_text: type == "string" and length > 0 and (test("[[:space:][:cntrl:]\"'"'"'\\\\]") | not);
    [$srv.servers[]? | select(type == "object")] as $servers
    | def slot_bad($homes; $n; $s):
        [$servers[] | select(.id? == $s.server)] as $match
        | (($s.homes // {}) | if type == "object" then . else {} end) as $shares
        | ((($shares | keys) - ($homes | keys)) | first) as $stray
        | ($s.capacity // 1) as $cap
        | (($s | has("server")) or ($s | has("harness"))) as $bound
        | if ($s | has("server")) and ($s | has("harness")) then "slot \($n) names both a server and a harness; a slot is bound to one server or one login harness"
          elif $bound != ($s | has("model")) then "slot \($n) needs a server or a harness with a model, or neither"
          elif ($s | has("grade")) and (($s.grade | type) != "string" or ($grades | index($s.grade)) == null) then "slot \($n) grade \($s.grade | tostring) is not one of \($grades | join(", "))"
          elif ($s | has("facets")) and (($s.facets | type) != "array" or ([$s.facets[] | name] | all | not)) then "slot \($n) facets must be a list of names"
          elif ($s | has("login")) and (($s | has("harness")) | not) then "slot \($n) login names a sign-in label, which only a login slot carries"
          elif $bound | not then empty
          elif ($s | has("harness")) and (($s.harness | type) != "string" or ($login | index($s.harness)) == null) then "slot \($n) harness \($s.harness | tostring) is not one of \($login | join(", "))"
          elif ($s | has("harness")) and ($s | has("auth_env") or has("unlisted_models") or has("model_settings")) then "slot \($n) is a login slot, which takes no auth_env, unlisted_models, or model_settings"
          elif ($s | has("login")) and (($s.login | safe_text) | not) then "slot \($n) login must be a non-empty string without spaces or quotes"
          elif ($s | has("server")) and ($match | length) == 0 then "slot \($n) names server \($s.server | tostring), which \($file) does not list"
          elif ($s | has("server")) and ($match | length) > 1 then "slot \($n) names server \($s.server), which \($file) lists more than once"
          elif ($s | has("server")) and (($match[0].baseURL | type) != "string" or ($match[0].baseURL | test("^https?://[^/]") | not)) then "slot \($n) is on server \($s.server), whose baseURL \($match[0].baseURL | tostring) is not an http(s) URL"
          elif ($s.model | type) != "string" or ($s.model | length) == 0 then "slot \($n) model must be a non-empty string"
          elif ($s | has("capacity")) and (($s.capacity | whole and . >= 1) | not) then "slot \($n) capacity must be a positive whole number"
          elif ($s | has("homes")) and (($s.homes | type) != "object") then "slot \($n) homes must map home names to shares"
          elif ([$shares[] | whole and . >= 0] | all | not) then "slot \($n) shares must be whole numbers"
          elif $stray != null then "slot \($n) gives a share to home \($stray), which the registry homes do not name"
          elif ([$shares[]] | add // 0) > $cap then "slot \($n) shares \([$shares[]] | add) tasks among its homes, above its capacity of \($cap)"
          else empty
          end;
    $reg
    | if type != "object" or .schema != 1 then "the slot registry must be an object with schema 1"
      elif (.homes | type) != "object" then "the slot registry needs a homes object"
      elif (.slots | type) != "object" then "the slot registry needs a slots object"
      elif has("privateer_first_mate") and ((.privateer_first_mate | type) != "string") then "privateer_first_mate must name a slot"
      else
        .homes as $homes
        | [.slots | to_entries[] | if (.value | type) != "object" then "slot \(.key) must be an object" else slot_bad($homes; .key; .value) end]
        | first // empty
      end'
}

# slot_projection <registry-json> <servers-json> <key>: the sailors map home
# <key> gets from the slot registry (see the header).
slot_projection() {
  jq -nc --argjson reg "$1" --argjson srv "$2" --arg key "$3" '
    [$srv.servers[]? | select(type == "object")] as $servers
    | def copy($s; $fields): reduce $fields[] as $f ({}; if $s | has($f) then . + {($f): $s[$f]} else . end);
    $reg.slots | to_entries
    | map(select(((.value | has("server")) or (.value | has("harness"))) and (((.value.homes // {})[$key] // 0) > 0))
          | .key as $n | .value as $s
          | [$servers[] | select(.id? == $s.server)][0] as $x
          | {key: $n, value: (
              (if $s | has("title") then {title: $s.title} else {} end)
              + (if $s | has("harness") then
                   {harness: $s.harness} + copy($s; ["login"])
                   + {status: ($s.status // "placeholder"), models: [$s.model], max_concurrent: $s.homes[$key]}
                   + copy($s; ["grade", "facets", "paid"])
                 else
                   (if ($x.name | type) == "string" then {host: $x.name} else {} end)
                   + {endpoint: (($x.baseURL | sub("/$"; "")) + "/v1"), status: ($s.status // "placeholder"), models: [$s.model], max_concurrent: $s.homes[$key]}
                   + copy($s; ["grade", "facets", "paid", "auth_env", "unlisted_models", "model_settings"])
                 end))})
    | from_entries'
}

cmd_sync() {
  local registry key='' managed reg srv='{}' err home_dir new gone stale s m ids line fm names
  [ "$#" -ge 3 ] || usage
  registry=$1
  shift
  case "$registry" in '' | -*) usage ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; key=$2; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$key" ] || usage
  begin_edit
  managed=$(registry_path)
  [ -n "$managed" ] ||
    refuse "this home's sailors are managed by hand, since config/sailor-registry is absent; write the slot registry's path into it to hand them to sync"
  managed=$(expand_home "$managed")
  case "$managed" in
    /*) ;;
    *) refuse "config/sailor-registry must name the slot registry by an absolute path or one starting ~/, not '$managed'" ;;
  esac
  [ -f "$registry" ] || refuse "no slot registry at $registry"
  [ "$registry" -ef "$managed" ] || refuse "this home follows the slot registry $managed (config/sailor-registry), not $registry"
  reg=$(jq -ce . "$registry" 2>/dev/null) || refuse "the slot registry $registry is not valid JSON"
  if jq -e '.slots | type == "object" and any(.[]; type == "object" and has("server"))' <<<"$reg" >/dev/null 2>&1; then
    [ -f "$SERVERS_FILE" ] || refuse "no mlx-serve registry at $SERVERS_FILE"
    srv=$(jq -ce . "$SERVERS_FILE" 2>/dev/null) || srv='{}'
    jq -e '.servers | type == "array"' <<<"$srv" >/dev/null 2>&1 || refuse "$SERVERS_FILE holds no servers list"
  fi
  err=$(registry_problem "$reg" "$srv") || die "could not read the slot registry $registry"
  [ -z "$err" ] || refuse "$err"
  home_dir=$(jq -r --arg k "$key" '.homes[$k] | strings' <<<"$reg")
  [ -n "$home_dir" ] || refuse "the slot registry names no home $key"
  home_dir=$(expand_home "$home_dir")
  [ -d "$home_dir" ] && [ "$home_dir" -ef "$FM_HOME" ] || refuse "the slot registry's home $key is $home_dir, not this home ($FM_HOME)"

  new=$(slot_projection "$reg" "$srv" "$key") || die "could not project the slot registry $registry"
  # shellcheck disable=SC2016 # jq, not the shell, expands the $ names.
  while IFS=$'\t' read -r s m; do
    if [ -z "$m" ]; then
      ids=$(sailor_tasks "$s" "" | paste -sd, -)
      [ -z "$ids" ] || refuse "task(s) $ids run on $s, which $registry no longer gives this home; sync once they land"
    else
      ids=$(sailor_tasks "$s" "" "$m" | paste -sd, -)
      [ -z "$ids" ] || refuse "task(s) $ids run $s/$m, which $registry no longer lists, and relaunching them needs it listed; sync once they land"
    fi
  done < <(jq -r --argjson new "$new" '
    (.sailors // {}) | to_entries[] | .key as $s
    | if ($new | has($s)) then (.value.models[] | select(. as $m | ($new[$s].models | index($m)) == null) | "\($s)\t\(.)")
      else "\($s)\t" end' "$FILE")
  # shellcheck disable=SC2016 # jq, not the shell, expands the $ names.
  stale=$(jq -r --argjson new "$new" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    [((.rules // [])[]? | select(type == "object") | "rule \"\(.when)\"" as $w | profiles(.use?)[]? | [$w, .]),
     (profiles(.default?)[]? | ["the default", .])]
    | map(select(.[1] | type == "object" and (.sailor | type) == "string" and (.model | type) == "string")
          | select(.[1].sailor as $s | .[1].model as $m | ($new | has($s)) and (($new[$s].models | index($m)) == null)))
    | map("\(.[0]) names \(.[1].sailor)/\(.[1].model), which the slot registry no longer gives this home; change it by hand first")
    | first // empty' "$FILE")
  [ -z "$stale" ] || refuse "$stale"

  if privateer_on; then
    line=$(first_mate_line)
    fm=$(jq -r '.privateer_first_mate // empty' <<<"$reg")
    if [ -n "$fm" ]; then
      # shellcheck disable=SC2016 # jq, not the shell, expands the $ names.
      err=$(jq -r --arg f "$fm" --arg k "$key" '
        .slots[$f] as $s
        | if $s == null then "privateer_first_mate names \($f), which is not a slot"
          elif $s | has("harness") then "slot \($f) is a login slot, and the first mate runs only on an endpoint sailor"
          elif ($s | has("server")) | not then "slot \($f) is blank, and the first mate runs only on a bound slot"
          elif ((($s.homes // {})[$k] // 0) > 0) | not then "slot \($f) gives home \($k) no share, so the first mate cannot run on it"
          elif (($s.facets // []) | index("helm")) == null then "slot \($f) lacks the helm facet the first mate needs"
          elif ($s.status // "placeholder") != "live" then "slot \($f) is a placeholder, and the first mate runs only on a live sailor"
          else empty
          end' <<<"$reg")
      [ -z "$err" ] || refuse "$err"
      line="$fm/$(jq -r --arg f "$fm" '.slots[$f].model' <<<"$reg")"
      first_mate_rewrite "$line" > "$WORK/privateer"
    fi
    if [ -n "$line" ] && [ "$(jq -r --arg s "${line%%/*}" '.[$s].status // empty' <<<"$new")" = placeholder ]; then
      refuse "the first mate runs on $line, and the first mate runs only on a live sailor"
    fi
  fi

  gone=$(jq -c --argjson new "$new" '[(.sailors // {}) | keys_unsorted[] | select(. as $s | $new | has($s) | not)]' "$FILE")
  jq -r --argjson gone "$gone" "$STRIP_JQ emptied_report[]" "$FILE" > "$WORK/emptied"
  # shellcheck disable=SC2016 # jq, not the shell, expands the $ names.
  compose --argjson new "$new" --argjson gone "$gone" "$STRIP_JQ"'
    (if $new == {} and (has("sailors") | not) then . else .sailors = $new end) | drop_gone'
  guard_candidate
  if ! commit; then
    echo "this home's sailors already match $registry; nothing written"
    return 0
  fi
  [ "$DRY_RUN" = 0 ] || return 0
  names=$(jq -r 'keys_unsorted | join(", ")' <<<"$new")
  echo "synced home $key from $registry: ${names:-no sailors}"
  jq -r --arg r "$registry" '.[] | "removed sailor \(.), which \($r) no longer gives this home"' <<<"$gone"
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
  grades)
    [ "$#" -eq 1 ] || usage
    need_jq
    jq -r '.[]' <<<"$GRADES"
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
  pick) shift; cmd_pick "$@" ;;
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
  health)
    [ "$#" -eq 1 ] || usage
    cmd_health
    ;;
  with-token)
    [ "$#" -ge 5 ] && [ "$4" = -- ] || usage
    cmd_with_token "$2" "$3" "${@:5}"
    ;;
  add) shift; cmd_add "$@" ;;
  set) shift; cmd_set "$@" ;;
  set-model) shift; cmd_set_model "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  sync) shift; cmd_sync "$@" ;;
  -h | --help)
    sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    ;;
  *) usage ;;
esac
