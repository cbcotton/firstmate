#!/usr/bin/env bash
# tests/fm-helm-live-e2e.test.sh - the real OpenCode turns each slash command
# in .opencode/commands/ into one call of the Privateer front door,
# bin/fm-helm.sh, with the captain's words intact, and hands the front door's
# report to the model, exactly as tests/fm-helm.test.sh assumes.
#
# How a command's template is expanded, where its shell step runs, and what
# reaches the model are decided inside OpenCode, so this is a harness-dependent
# check (firstmate-coding-guidelines, "Harness-dependent checks"). A fixture
# clone of this checkout, with its working tree's scripts and OpenCode files,
# is a Privateer home whose bin/fm-helm.sh is a probe recording its arguments,
# working directory, and standard input, and writing one line to stdout and
# one to stderr. `opencode serve` runs inside the home's session, and each
# command is sent with `opencode run --attach --command`, so the run spends
# no model tokens: a scripted OpenAI-compatible model on a loopback port
# answers every request and logs each user message. It runs by default
# wherever opencode is installed.
#
# Every command must reach the probe once, from the home, with its own verb;
# the verbs that take words must receive them on standard input followed by
# the end line, quotes, $, and ; included; the model must receive both probe
# lines and none of the template's shell step. Two words the front door's
# header names as limits are pinned too: a backtick cuts the words and drops
# the end line, and $' cuts them silently.
# `opencode run` reads standard input when it is not a terminal and waits for
# it to close, so every OpenCode process gets /dev/null.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_HELM_LIVE opencode python3 jq git curl

TMP_ROOT=$(fm_test_tmproot fm-helm-live)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
OPENCODE_VERSION=$(opencode --version 2>/dev/null | head -1)
END_LINE=FM_HELM_END_OF_ARGUMENTS
MODEL_PID=
SERVE_PID=

cleanup() {
  [ -z "$SERVE_PID" ] || kill "$SERVE_PID" 2>/dev/null
  [ -z "$MODEL_PID" ] || kill "$MODEL_PID" 2>/dev/null
  # OpenCode's helper processes outlive it by a moment and recreate their data
  # directory, so let them go before the fixture is removed.
  sleep 1
  rm -rf "$TMP_ROOT" 2>/dev/null || { sleep 2; rm -rf "$TMP_ROOT" 2>/dev/null || true; }
}
trap cleanup EXIT

guard_fail() {
  fail "opencode $OPENCODE_VERSION with the front door's slash commands: $*"
}

# start_model <dir>: a scripted model that answers every request with plain
# text and logs the user messages of each request as one JSON line to
# <dir>/model.log; writes <dir>/config.json, the OpenCode configuration that
# makes it the only provider.
start_model() {
  local dir=$1 port
  : > "$dir/model.log"
  cat > "$dir/model.py" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT_FILE, LOG = sys.argv[1], sys.argv[2]

def text_of(message):
    content = message.get("content")
    if isinstance(content, list):
        return "".join(part.get("text", "") for part in content if isinstance(part, dict))
    return content if isinstance(content, str) else ""

def chunk(delta, finish=None):
    return "data: " + json.dumps({"id": "c", "object": "chat.completion.chunk", "created": int(time.time()),
        "model": "scripted", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n"

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def reply(self, body, ctype):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        self.reply(json.dumps({"object": "list", "data": [{"id": "scripted", "object": "model"}]}), "application/json")
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        users = [text_of(m) for m in req.get("messages", []) if m.get("role") == "user"]
        with open(LOG, "a") as f:
            f.write(json.dumps({"users": users}) + "\n")
        self.reply(chunk({"role": "assistant", "content": "Standing by."}) + chunk({}, "stop") + "data: [DONE]\n\n", "text/event-stream")

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORT_FILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
  python3 "$dir/model.py" "$dir/port" "$dir/model.log" > "$dir/model.err" 2>&1 &
  MODEL_PID=$!
  for _ in $(seq 100); do
    [ -s "$dir/port" ] && break
    sleep 0.05
  done
  port=$(cat "$dir/port" 2>/dev/null)
  [ -n "$port" ] || guard_fail "the scripted model did not start: $(cat "$dir/model.err" 2>/dev/null)"
  jq -cn --arg url "http://127.0.0.1:$port/v1" '{autoupdate: false, share: "disabled", model: "sailor/scripted", small_model: "sailor/scripted", permission: {"*": "allow"},
    provider: {sailor: {npm: "@ai-sdk/openai-compatible", name: "Scripted", options: {baseURL: $url}, models: {scripted: {name: "scripted"}}}}}' \
    > "$dir/config.json"
}

# make_home <dir>: a fixture clone of this checkout, with its working tree's
# scripts and OpenCode files, that is a Privateer home whose front door is a
# probe; prints the home. Each probe run records into state/probe/<n>/.
make_home() {
  local home="$1/home"
  git clone -q "$ROOT" "$home" || guard_fail "the fixture clone of this checkout failed"
  cp -R "$ROOT/bin/." "$home/bin/"
  cp -R "$ROOT/.opencode/." "$home/.opencode/"
  mkdir -p "$home/config" "$home/state/probe" "$1/xdg/config" "$1/xdg/data" "$1/xdg/state" "$1/xdg/cache"
  printf 'tiller/scripted\n' > "$home/config/privateer"
  cat > "$home/bin/fm-helm.sh" <<'SH'
#!/bin/sh
n=$(ls "$FM_HOME/state/probe" | wc -l | tr -d ' ')
d="$FM_HOME/state/probe/$n"
mkdir -p "$d"
printf '%s\n' "$@" > "$d/argv"
pwd -P > "$d/cwd"
cat > "$d/stdin"
echo "helm-probe-stdout $1"
echo "helm-probe-stderr $1" >&2
SH
  chmod +x "$home/bin/fm-helm.sh"
  printf '%s\n' "$home"
}

# probe_runs <home>: how many times the probe ran.
probe_runs() {
  find "$1/state/probe" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

# users_since <dir> <line>: the user messages of every model request logged
# after line <line> of the log, joined; OpenCode's title request may come last.
users_since() {
  tail -n "+$(($2 + 1))" "$1/model.log" | jq -r '.users | join("\n")'
}

# send_command <verb> <words>: the captain's /<verb> <words>, through the
# running server. `opencode run` wraps each message argument holding a space
# in quotes before joining them, so the words go one per argument, which joins
# them back to exactly the words typed.
send_command() {
  local verb=$1
  local -a words=()
  read -r -a words <<WORDS
$2
WORDS
  env -u TMUX -u FM_HOME "${oc_env[@]}" perl -e 'alarm shift; exec @ARGV' 180 "${attach[@]}" --command "$verb" ${words[@]+"${words[@]}"}
}

test_every_command_reaches_the_front_door() {
  local dir home config socket url line verb words runs n users rc logged
  local -a oc_env=() attach
  dir="$TMP_ROOT/commands"
  mkdir -p "$dir"
  home=$(make_home "$dir")
  socket=$(. "$home/bin/fm-privateer-lib.sh" && fm_privateer_socket_name "$home")
  [ -n "$socket" ] || guard_fail "the home's session socket could not be read"
  start_model "$dir"
  config=$(cat "$dir/config.json")
  for line in "XDG_CONFIG_HOME=$dir/xdg/config" "XDG_DATA_HOME=$dir/xdg/data" "XDG_STATE_HOME=$dir/xdg/state" \
    "XDG_CACHE_HOME=$dir/xdg/cache" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1; do
    oc_env+=("$line")
  done
  (
    cd "$home" || exit 1
    exec env TMUX="/tmp/tmux-$(id -u)/$socket,1,0" FM_HOME="$home" "${oc_env[@]}" OPENCODE_CONFIG_CONTENT="$config" \
      OPENCODE_SERVER_PASSWORD=helm-live opencode serve --port 0
  ) < /dev/null > "$dir/serve.out" 2>&1 &
  SERVE_PID=$!
  url=
  for _ in $(seq 300); do
    url=$(sed -n 's/.*listening on \(http:[^ ]*\).*/\1/p' "$dir/serve.out" | head -1)
    [ -n "$url" ] && curl -s -o /dev/null "$url" && break
    kill -0 "$SERVE_PID" 2>/dev/null || guard_fail "opencode serve exited: $(tail -c 600 "$dir/serve.out")"
    sleep 0.2
  done
  [ -n "$url" ] || guard_fail "opencode serve never listened: $(tail -c 600 "$dir/serve.out")"
  attach=(opencode run --attach "$url" --password helm-live)

  # verb|words: the words the captain types after the command.
  runs=0
  while IFS='|' read -r verb words; do
    logged=$(wc -l < "$dir/model.log" | tr -d ' ')
    (
      cd "$home" || exit 1
      send_command "$verb" "$words"
    ) < /dev/null > "$dir/run.out" 2>&1
    rc=$?
    [ "$rc" = 0 ] || guard_fail "opencode run --command $verb exited $rc: $(tail -c 600 "$dir/run.out")"
    n=$runs
    runs=$((runs + 1))
    assert_equals "$runs" "$(probe_runs "$home")" "opencode $OPENCODE_VERSION: /$verb must run the front door exactly once"
    assert_equals "$home" "$(cat "$home/state/probe/$n/cwd")" "opencode $OPENCODE_VERSION: /$verb must run the front door from the home"
    users=$(users_since "$dir" "$logged")
    assert_contains "$users" "helm-probe-stdout $verb" "opencode $OPENCODE_VERSION: the front door's stdout must reach the model for /$verb"
    assert_contains "$users" "helm-probe-stderr $verb" "opencode $OPENCODE_VERSION: the front door's stderr must reach the model for /$verb"
    assert_not_contains "$users" "fm-helm.sh" "opencode $OPENCODE_VERSION: the template's shell step must not reach the model for /$verb"
    case "$verb" in
      helm | queue | sailors | wake)
        assert_equals "$verb" "$(cat "$home/state/probe/$n/argv")" "opencode $OPENCODE_VERSION: /$verb must pass only its verb"
        ;;
      *)
        assert_equals "$verb"$'\n'"--stdin" "$(cat "$home/state/probe/$n/argv")" "opencode $OPENCODE_VERSION: /$verb must pass its verb and --stdin"
        assert_equals "$words"$'\n'"$END_LINE" "$(cat "$home/state/probe/$n/stdin")" "opencode $OPENCODE_VERSION: /$verb must pass the captain's words exactly, then the end line"
        ;;
    esac
  done <<'EOF'
helm|
scout|app check why the captain's "build" fails; $(whoami) && echo no
ship|app add a health check
queue|
sailors|
steer|look-around-4d look again, and don't stop
land|add-a-file-1b
wake|
EOF

  (
    cd "$home" || exit 1
    # The backtick is the captain's own character, not an expansion.
    # shellcheck disable=SC2016
    send_command scout 'app fix `foo` now'
  ) < /dev/null > "$dir/run.out" 2>&1
  n=$runs
  runs=$((runs + 1))
  assert_equals "$runs" "$(probe_runs "$home")" "opencode $OPENCODE_VERSION: words holding a backtick must still run the front door once"
  assert_equals "app fix " "$(cat "$home/state/probe/$n/stdin")" "opencode $OPENCODE_VERSION: a backtick must cut the words and drop the end line, as the front door's header says"

  (
    cd "$home" || exit 1
    send_command scout "app print \$'x' then stop"
  ) < /dev/null > "$dir/run.out" 2>&1
  n=$runs
  runs=$((runs + 1))
  assert_equals "$runs" "$(probe_runs "$home")" "opencode $OPENCODE_VERSION: words holding \$' must still run the front door once"
  assert_equals "app print "$'\n'"$END_LINE" "$(cat "$home/state/probe/$n/stdin")" "opencode $OPENCODE_VERSION: \$' must cut the words silently, as the front door's header says"

  kill "$SERVE_PID" 2>/dev/null
  SERVE_PID=
  pass "opencode $OPENCODE_VERSION runs each of the eight slash commands as one front-door call from the home, passes the captain's words exactly on standard input, hands the front door's stdout and stderr to the model, and cuts words at a backtick or \$' as documented"
}

test_every_command_reaches_the_front_door

echo "# all fm-helm-live-e2e tests passed"
