#!/usr/bin/env bash
# tests/fm-privateer-seal-live-e2e.test.sh - the real OpenCode carries the
# Privateer seal plugin (.opencode/plugins/fm-privateer-seal.js) exactly as
# tests/fm-privateer.test.sh pins it against a fake client.
#
# Which tool runs, what a tool result says, and which messages reach the model
# are decided inside OpenCode, so this is a harness-dependent check
# (firstmate-coding-guidelines, "Harness-dependent checks"). A fixture clone of
# this checkout, with its working tree's scripts and plugins, is a Privateer
# home, and a scripted OpenAI-compatible model on a loopback port answers each
# captain turn with the next tool call of a fixed plan, so the run spends no
# model tokens and runs by default wherever opencode is installed. Every
# verdict is read from the filesystem a step would have changed and from the
# tool results and messages OpenCode sent back to the model.
#
# Outside the session, `opencode run` with no TMUX: the bash and read tools are
# refused with the launcher's refusal, and the marked privateer-seal line
# reaches the model. Inside it, `opencode serve` with TMUX naming the home's
# socket and two captain messages sent with `opencode run --attach`: a tmux
# command naming another server is refused; three refusing bin/fm-* calls in a
# row, whose refusal is on stderr as the real scripts write it, spend the
# budget, the third result carries the budget message, and the fourth call does
# not run; the next captain message resets the budget, so the call runs again.
# `opencode run` reads standard input when it is not a terminal and waits for
# it to close, so every OpenCode process gets /dev/null.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PRIVATEER_SEAL_LIVE opencode python3 jq git curl

TMP_ROOT=$(fm_test_tmproot fm-privateer-seal-live)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
OPENCODE_VERSION=$(opencode --version 2>/dev/null | head -1)
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
  fail "opencode $OPENCODE_VERSION with the Privateer seal: $*"
}

# write_model <path>: the scripted model. Its plan holds one list of tool calls
# per captain turn, a turn being a user message that is not Firstmate
# operational input; within a turn it answers with the next call after the tool
# results already given, then with plain text. It logs every request that
# offers tools: the turn, the step, the last tool result, and every user text.
write_model() {
  cat > "$1" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT_FILE, PLAN, LOG = sys.argv[1], sys.argv[2], sys.argv[3]
TURNS = json.load(open(PLAN))

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
        msgs = req.get("messages", [])
        captain = [i for i, m in enumerate(msgs) if m.get("role") == "user" and not text_of(m).startswith("⁣")]
        turn = len(captain) - 1
        step = sum(1 for m in msgs[captain[-1]:] if m.get("role") == "tool") if captain else 0
        plan = TURNS[turn] if 0 <= turn < len(TURNS) else []
        call = plan[step] if req.get("tools") and step < len(plan) else None
        if req.get("tools"):
            last = next((text_of(m) for m in reversed(msgs) if m.get("role") == "tool"), "")
            users = [text_of(m) for m in msgs if m.get("role") == "user"]
            with open(LOG, "a") as f:
                f.write(json.dumps({"turn": turn, "step": step, "last": last, "users": users}) + "\n")
        if call is None:
            parts = [chunk({"role": "assistant", "content": "Standing by."}), chunk({}, "stop")]
        else:
            fn = {"name": call["tool"], "arguments": json.dumps(call["args"])}
            parts = [chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": "call_%d_%d" % (turn, step), "type": "function", "function": fn}]}),
                     chunk({}, "tool_calls")]
        self.reply("".join(parts) + "data: [DONE]\n\n", "text/event-stream")

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORT_FILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
}

# start_model <case-dir> <plan-json>: starts the scripted model on the plan,
# in this shell so MODEL_PID stays set, and writes <case-dir>/config.json, the
# OpenCode configuration that makes it the only provider.
start_model() {
  local dir=$1 port
  printf '%s\n' "$2" > "$dir/plan.json"
  : > "$dir/model.log"
  write_model "$dir/model.py"
  python3 "$dir/model.py" "$dir/port" "$dir/plan.json" "$dir/model.log" > "$dir/model.err" 2>&1 &
  MODEL_PID=$!
  for _ in $(seq 100); do
    [ -s "$dir/port" ] && break
    sleep 0.05
  done
  port=$(cat "$dir/port" 2>/dev/null)
  [ -n "$port" ] || guard_fail "the scripted model did not start: $(cat "$dir/model.err" 2>/dev/null)"
  jq -cn --arg url "http://127.0.0.1:$port/v1" '{autoupdate: false, share: "disabled", model: "sailor/scripted", permission: {"*": "allow"},
    provider: {sailor: {npm: "@ai-sdk/openai-compatible", name: "Scripted", options: {baseURL: $url}, models: {scripted: {name: "scripted"}}}}}' \
    > "$dir/config.json"
}

stop_model() {
  [ -z "$MODEL_PID" ] || kill "$MODEL_PID" 2>/dev/null
  MODEL_PID=
}

# make_privateer_home <case-dir>: a fixture clone of this checkout, carrying its
# working tree's scripts and plugins, that is a Privateer home with a probe
# script refusing on stderr as the real bin/fm-* scripts do and counting its
# runs in state/probe-runs; prints the home.
make_privateer_home() {
  local home="$1/home"
  git clone -q "$ROOT" "$home" || guard_fail "the fixture clone of this checkout failed"
  cp -R "$ROOT/bin/." "$home/bin/"
  cp -R "$ROOT/.opencode/." "$home/.opencode/"
  mkdir -p "$home/config" "$home/state" "$1/xdg/config" "$1/xdg/data" "$1/xdg/state" "$1/xdg/cache"
  printf 'tiller/scripted\n' > "$home/config/privateer"
  cat > "$home/bin/fm-seal-probe.sh" <<'SH'
#!/bin/sh
echo run >> "$FM_HOME/state/probe-runs"
echo "refused: probe refusal $(wc -l < "$FM_HOME/state/probe-runs" | tr -d ' ')" >&2
exit 1
SH
  chmod +x "$home/bin/fm-seal-probe.sh"
  printf '%s\n' "$home"
}

# tool_result <case-dir> <turn> <step>: the last tool result the model had
# received when it was asked for that step of that captain turn.
tool_result() {
  jq -rs --argjson t "$2" --argjson s "$3" '[.[] | select(.turn == $t and .step == $s)] | last | .last // ""' "$1/model.log"
}

# opencode_env <case-dir>: the isolated OpenCode directories, one per line.
opencode_env() {
  printf '%s\n' "XDG_CONFIG_HOME=$1/xdg/config" "XDG_DATA_HOME=$1/xdg/data" "XDG_STATE_HOME=$1/xdg/state" \
    "XDG_CACHE_HOME=$1/xdg/cache" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1
}

test_seal_stops_an_outside_opencode() {
  local dir home config rc refusal result seal line step
  local -a oc_env=()
  dir="$TMP_ROOT/outside"
  mkdir -p "$dir"
  home=$(make_privateer_home "$dir")
  start_model "$dir" '[[{"tool": "bash", "args": {"command": "touch outside-probe", "description": "probe"}}, {"tool": "read", "args": {"filePath": "AGENTS.md"}}]]'
  config=$(cat "$dir/config.json")
  refusal=$(cd "$home" && env -u TMUX -u FM_HOME bin/fm-privateer.sh inside 2>&1)
  while IFS= read -r line; do oc_env+=("$line"); done < <(opencode_env "$dir")
  (
    cd "$home" || exit 1
    env -u TMUX -u FM_HOME "${oc_env[@]}" OPENCODE_CONFIG_CONTENT="$config" \
      perl -e 'alarm shift; exec @ARGV' 180 opencode run "probe this home"
  ) < /dev/null > "$dir/run.out" 2>&1
  rc=$?
  stop_model
  [ "$rc" = 0 ] || guard_fail "opencode run outside the session exited $rc: $(tail -c 600 "$dir/run.out")"
  [ ! -e "$home/outside-probe" ] || guard_fail "the bash tool ran outside the session"
  for step in 1 2; do
    result=$(tool_result "$dir" 0 "$step")
    [ -n "$result" ] || guard_fail "step $step never returned a result, so its refusal proves nothing"
    assert_contains "$result" "$refusal" "opencode $OPENCODE_VERSION: tool step $step outside the session must be refused with the launcher's refusal"
  done
  seal=$(jq -r '.users[]' "$dir/model.log" | grep -F "FIRSTMATE_OP: v1 privateer-seal: $refusal" | head -1)
  [ -n "$seal" ] || guard_fail "the privateer-seal line never reached the model; user messages: $(jq -c '.users' "$dir/model.log" | tail -1)"
  pass "opencode $OPENCODE_VERSION outside a sealed Privateer session refuses the bash and read tools with the launcher's refusal and delivers the privateer-seal line to the model"
}

test_seal_holds_inside_the_session() {
  local dir home config socket url rc runs step third blocked again line message
  local -a oc_env=() attach
  dir="$TMP_ROOT/inside"
  mkdir -p "$dir"
  home=$(make_privateer_home "$dir")
  socket=$(. "$home/bin/fm-privateer-lib.sh" && fm_privateer_socket_name "$home")
  [ -n "$socket" ] || guard_fail "the home's session socket could not be read"
  start_model "$dir" '[
    [{"tool": "bash", "args": {"command": "tmux -L fm-seal-live-other list-sessions", "description": "other server"}},
     {"tool": "bash", "args": {"command": "bin/fm-seal-probe.sh", "description": "probe"}},
     {"tool": "bash", "args": {"command": "bin/fm-seal-probe.sh", "description": "probe"}},
     {"tool": "bash", "args": {"command": "bin/fm-seal-probe.sh", "description": "probe"}},
     {"tool": "bash", "args": {"command": "bin/fm-seal-probe.sh", "description": "probe"}}],
    [{"tool": "bash", "args": {"command": "bin/fm-seal-probe.sh", "description": "probe"}}]]'
  config=$(cat "$dir/config.json")
  while IFS= read -r line; do oc_env+=("$line"); done < <(opencode_env "$dir")
  (
    cd "$home" || exit 1
    exec env TMUX="/tmp/tmux-$(id -u)/$socket,1,0" FM_HOME="$home" "${oc_env[@]}" OPENCODE_CONFIG_CONTENT="$config" \
      OPENCODE_SERVER_PASSWORD=seal-live opencode serve --port 0
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
  attach=(opencode run --attach "$url" --password seal-live)
  for message in "run the probes" "try the other sailor"; do
    (
      cd "$home" || exit 1
      env -u TMUX -u FM_HOME "${oc_env[@]}" perl -e 'alarm shift; exec @ARGV' 180 "${attach[@]}" "$message"
    ) < /dev/null > "$dir/run.out" 2>&1
    attach+=(--continue)
    rc=$?
    [ "$rc" = 0 ] || guard_fail "opencode run --attach '$message' exited $rc: $(tail -c 600 "$dir/run.out")"
  done
  kill "$SERVE_PID" 2>/dev/null
  SERVE_PID=
  stop_model

  assert_contains "$(tool_result "$dir" 0 1)" "tmux reaches only this session's own server" "opencode $OPENCODE_VERSION: a tmux command naming another server must be refused inside the session"
  for step in 2 3; do
    assert_contains "$(tool_result "$dir" 0 "$step")" "refused: probe refusal $((step - 1))" "opencode $OPENCODE_VERSION: the bash result must carry the probe's stderr refusal"
  done
  third=$(tool_result "$dir" 0 4)
  assert_contains "$third" "refused: probe refusal 3" "opencode $OPENCODE_VERSION: the third refusal must reach the model"
  assert_contains "$third" "three refusals in a row: stop, report the last refusal to the captain, and wait" "opencode $OPENCODE_VERSION: the result that spends the budget must carry the budget message"
  blocked=$(tool_result "$dir" 0 5)
  assert_contains "$blocked" "three refusals in a row" "opencode $OPENCODE_VERSION: the next firstmate script must be refused with the budget message"
  again=$(tool_result "$dir" 1 1)
  assert_contains "$again" "refused: probe refusal 4" "opencode $OPENCODE_VERSION: a captain message must reset the budget so the script runs again"
  runs=$(wc -l < "$home/state/probe-runs" 2>/dev/null | tr -d ' ')
  assert_equals 4 "$runs" "opencode $OPENCODE_VERSION: the probe must run three times, not while the budget is spent, and once more after the captain's message"
  pass "opencode $OPENCODE_VERSION inside a sealed Privateer session refuses tmux naming another server, spends the refusal budget on three stderr refusals from a firstmate script, appends the budget message to the third result, blocks the fourth call, and resets on the next captain message"
}

test_seal_stops_an_outside_opencode
test_seal_holds_inside_the_session

echo "# all fm-privateer-seal-live-e2e tests passed"
