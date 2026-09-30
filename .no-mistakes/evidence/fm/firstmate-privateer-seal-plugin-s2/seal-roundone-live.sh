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
. "/Users/cotton/.no-mistakes/worktrees/e74e4e411ceb/01M3SG9F3NSN7FD9889ZR357KP/tests/lib.sh"

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

# Scenario A: outside OpenCode opened in a sealed home, but inheriting FM_HOME of a
# different, non-Privateer home (as an fm-afk-launch primary would pass down).
scenario_inherited_foreign_fm_home() {
  local dir home other config rc result line
  local -a oc_env=()
  dir="$TMP_ROOT/foreign"; mkdir -p "$dir"
  home=$(make_privateer_home "$dir")
  other="$dir/mainhome"; mkdir -p "$other/config" "$other/state"
  start_model "$dir" '[[{"tool": "bash", "args": {"command": "touch outside-probe", "description": "probe"}}]]'
  config=$(cat "$dir/config.json")
  while IFS= read -r line; do oc_env+=("$line"); done < <(opencode_env "$dir")
  ( cd "$home" || exit 1
    env -u TMUX FM_HOME="$other" "${oc_env[@]}" OPENCODE_CONFIG_CONTENT="$config" \
      perl -e 'alarm shift; exec @ARGV' 180 opencode run "probe this home" ) < /dev/null > "$dir/run.out" 2>&1
  rc=$?; stop_model
  echo "opencode rc=$rc"
  [ ! -e "$home/outside-probe" ] || guard_fail "bash ran outside the session despite the seal (inherited FM_HOME=$other)"
  result=$(tool_result "$dir" 0 1)
  echo "tool result seen by model: $result"
  assert_contains "$result" "fm-privateer" "bash must be refused by the seal"
  jq -r '.users[]' "$dir/model.log" | grep -F "FIRSTMATE_OP: v1 privateer-seal:" | head -1
  pass "outside OpenCode inheriting a foreign non-Privateer FM_HOME is still sealed; bash did not run"
}

# Scenario B: checkout outside its home; FM_HOME names the sealed home and TMUX its socket -> inside rules
# (tmux to another server refused, but a normal command runs).
scenario_checkout_outside_home_inside() {
  local dir home checkout config socket rc line
  local -a oc_env=()
  dir="$TMP_ROOT/split"; mkdir -p "$dir"
  home=$(make_privateer_home "$dir")
  checkout="$dir/checkout"; git clone -q "$ROOT" "$checkout"; cp -R "$ROOT/bin/." "$checkout/bin/"; cp -R "$ROOT/.opencode/." "$checkout/.opencode/"
  socket=$(FM_HOME="$home" TMUX='' "$checkout/bin/fm-privateer.sh" launch-env 2>&1 | sed -n 's/.*(tmux socket \([^)]*\)).*/\1/p')
  [ -n "$socket" ] || guard_fail "socket unreadable"
  start_model "$dir" '[[{"tool": "bash", "args": {"command": "tmux -L fm-seal-live-other list-sessions", "description": "other"}},
     {"tool": "bash", "args": {"command": "touch inside-probe", "description": "probe"}}]]'
  config=$(cat "$dir/config.json")
  while IFS= read -r line; do oc_env+=("$line"); done < <(opencode_env "$dir")
  ( cd "$checkout" || exit 1
    env TMUX="/tmp/tmux-$(id -u)/$socket,1,0" FM_HOME="$home" "${oc_env[@]}" OPENCODE_CONFIG_CONTENT="$config" \
      perl -e 'alarm shift; exec @ARGV' 180 opencode run "work" ) < /dev/null > "$dir/run.out" 2>&1
  rc=$?; stop_model
  echo "opencode rc=$rc"
  echo "step1 result: $(tool_result "$dir" 0 1)"
  assert_contains "$(tool_result "$dir" 0 1)" "tmux reaches only this session's own server" "inside rule must apply"
  [ -e "$checkout/inside-probe" ] || guard_fail "ordinary bash did not run inside the session (sealed as outside?)"
  pass "checkout outside its sealed home with FM_HOME+TMUX of that home gets inside rules: foreign tmux refused, ordinary bash runs"
}

# Scenario C: inside, refuse x2, read/grep/cat the script (must not reset nor be blocked), refuse again -> budget spent,
# then a cat of the script after the budget is spent still runs.
scenario_reading_scripts_does_not_reset_budget() {
  local dir home config socket url rc line runs r
  local -a oc_env=() attach
  dir="$TMP_ROOT/read"; mkdir -p "$dir"
  home=$(make_privateer_home "$dir")
  socket=$(FM_HOME="$home" TMUX='' "$home/bin/fm-privateer.sh" launch-env 2>&1 | sed -n 's/.*(tmux socket \([^)]*\)).*/\1/p')
  start_model "$dir" '[[
     {"tool": "bash", "args": {"command": "bin/fm-seal-probe.sh", "description": "p"}},
     {"tool": "bash", "args": {"command": "bin/fm-seal-probe.sh", "description": "p"}},
     {"tool": "bash", "args": {"command": "sed -n 1,3p bin/fm-seal-probe.sh", "description": "read"}},
     {"tool": "bash", "args": {"command": "grep -n refused bin/fm-seal-probe.sh", "description": "grep"}},
     {"tool": "bash", "args": {"command": "bin/fm-seal-probe.sh", "description": "p"}},
     {"tool": "bash", "args": {"command": "cat bin/fm-seal-probe.sh", "description": "cat"}},
     {"tool": "bash", "args": {"command": "bash -c bin/fm-seal-probe.sh", "description": "nested"}}]]'
  config=$(cat "$dir/config.json")
  while IFS= read -r line; do oc_env+=("$line"); done < <(opencode_env "$dir")
  ( cd "$home" || exit 1
    env TMUX="/tmp/tmux-$(id -u)/$socket,1,0" FM_HOME="$home" "${oc_env[@]}" OPENCODE_CONFIG_CONTENT="$config" \
      perl -e 'alarm shift; exec @ARGV' 240 opencode run "run the probes" ) < /dev/null > "$dir/run.out" 2>&1
  rc=$?; stop_model
  echo "opencode rc=$rc"
  for s in 1 2 3 4 5 6 7; do r=$(tool_result "$dir" 0 $s); printf -- '--- result after step %s:\n%s\n' "$s" "$(printf '%s' "$r" | head -5)"; done
  assert_contains "$(tool_result "$dir" 0 3)" "echo run" "sed read of the script must run, not be blocked"
  assert_contains "$(tool_result "$dir" 0 4)" "refused" "grep of the script must run"
  r=$(tool_result "$dir" 0 5)
  assert_contains "$r" "refused: probe refusal 3" "third probe runs"
  assert_contains "$r" "three refusals in a row" "reads did not reset: third refusal spends the budget"
  assert_contains "$(tool_result "$dir" 0 6)" "#!/bin/sh" "cat of script after budget spent must still run"
  assert_contains "$(tool_result "$dir" 0 7)" "three refusals in a row" "nested bash -c firstmate call is blocked once spent"
  runs=$(wc -l < "$home/state/probe-runs" | tr -d ' ')
  assert_equals 3 "$runs" "probe ran exactly three times"
  pass "reading/grepping/cat-ing a bin/fm-* script neither resets nor is blocked; budget still spent on the third refusal; nested call blocked"
}

scenario_inherited_foreign_fm_home
scenario_checkout_outside_home_inside
scenario_reading_scripts_does_not_reset_budget
echo "# all round-one live scenarios passed"
