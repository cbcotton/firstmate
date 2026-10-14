#!/usr/bin/env bash
# tests/fm-sailor-token-live-e2e.test.sh - a sailor's bearer token reaches the
# real OpenCode's model requests, and nothing else.
#
# OpenCode resolving the provider entry's {env:<variable>} from its own
# environment and sending it as the bearer token, and the routed model id it
# sends, are decided inside OpenCode, so this is a harness-dependent check
# (firstmate-coding-guidelines, "Harness-dependent checks"). A throwaway home
# keeps the token in its .env under the sailor's auth_env; bin/fm-sailor.sh
# check and provider-json build the entry exactly as a launch does, and the
# real OpenCode runs headless through bin/fm-sailor.sh with-token against a
# loopback server that records each request's Authorization header and model
# and answers "ok", so the run spends no model tokens and the guard runs by
# default wherever its tools are installed. Every process command line is
# sampled during the run, and the token must appear in none of them, in no
# output, and in no file but .env. A control run without with-token must send
# no Authorization header, so the guard cannot pass vacuously.
# `opencode run` reads standard input when it is not a terminal and waits for
# it to close, so each run gets /dev/null rather than whatever the caller holds.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_SAILOR_TOKEN_LIVE opencode python3 jq

TMP_ROOT=$(fm_test_tmproot fm-sailor-token-live)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
OPENCODE_VERSION=$(opencode --version 2>/dev/null | head -1)
SERVER_PID=
SAMPLER_PID=
VAR=FM_LIVE_SAILOR_TOKEN
SENTINEL=fm-sentinel-live-token-5d2c80
MODEL=org/routed-model:cheapest
unset "$VAR"

cleanup() {
  [ -z "$SAMPLER_PID" ] || kill "$SAMPLER_PID" 2>/dev/null
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

guard_fail() {
  fail "opencode $OPENCODE_VERSION: $*"
}

write_recording_sailor() {  # <path>
  cat > "$1" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT_FILE, OUT = sys.argv[1], sys.argv[2]

def chunk(delta, finish=None):
    return "data: " + json.dumps({"id": "c", "object": "chat.completion.chunk", "created": int(time.time()),
        "model": "scripted", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n"

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def note(self, method, model):
        with open(OUT, "a") as f:
            f.write("%s\t%s\t%s\n" % (method, self.headers.get("Authorization") or "-", model))
    def reply(self, body, ctype):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        self.note("GET", "-")
        self.reply(json.dumps({"object": "list", "data": [{"id": "scripted", "object": "model"}]}), "application/json")
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        self.note("POST", req.get("model"))
        if req.get("stream"):
            self.reply(chunk({"role": "assistant", "content": "ok"}) + chunk({}, "stop") + "data: [DONE]\n\n", "text/event-stream")
        else:
            self.reply(json.dumps({"id": "c", "object": "chat.completion", "created": int(time.time()), "model": "scripted",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}]}),
                "application/json")

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORT_FILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
}

# run_opencode <home> <out> <config> [<wrapper>...]: one headless turn on the
# routed model, its OpenCode under <home>/xdg, started through <wrapper> when
# one is given, while every process command line is sampled into <out>.ps.
run_opencode() {
  local home=$1 out=$2 config=$3
  shift 3
  mkdir -p "$home/proj" "$home/xdg"
  git -C "$home/proj" init -q 2>/dev/null
  ( while :; do ps -axww -o command= >> "$out.ps" 2>/dev/null; sleep 0.1; done ) &
  SAMPLER_PID=$!
  (
    cd "$home/proj" || exit 1
    XDG_CONFIG_HOME="$home/xdg/config" XDG_DATA_HOME="$home/xdg/data" XDG_STATE_HOME="$home/xdg/state" \
      XDG_CACHE_HOME="$home/xdg/cache" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
      OPENCODE_CONFIG_CONTENT="$config" \
      perl -e 'alarm 180; exec @ARGV' "$@" opencode run --model "hf/$MODEL" "Say hi."
  ) </dev/null >"$out" 2>&1
  kill "$SAMPLER_PID" 2>/dev/null
  wait "$SAMPLER_PID" 2>/dev/null
  SAMPLER_PID=
}

test_sailor_token_reaches_only_the_model_requests() {
  local home port out config requests leaks
  home="$TMP_ROOT/home"
  mkdir -p "$home/config" "$home/state"

  write_recording_sailor "$TMP_ROOT/sailor.py"
  python3 "$TMP_ROOT/sailor.py" "$TMP_ROOT/port" "$TMP_ROOT/requests.log" &
  SERVER_PID=$!
  for _ in $(seq 100); do
    [ -s "$TMP_ROOT/port" ] && break
    sleep 0.05
  done
  port=$(cat "$TMP_ROOT/port" 2>/dev/null)
  [ -n "$port" ] || guard_fail "the recording sailor did not start"
  jq -n --arg e "http://127.0.0.1:$port/v1" --arg m "$MODEL" --arg v "$VAR" \
    '{sailors: {hf: {endpoint: $e, status: "live", models: [$m], auth_env: $v, unlisted_models: true}}}' > "$home/config/crew-dispatch.json"
  printf '%s=%s\n' "$VAR" "$SENTINEL" > "$home/.env"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-sailor.sh" check hf "$MODEL" 2>&1)
  expect_code 0 "$?" "the routed model must pass check on a sailor with unlisted_models: $out"
  config=$(FM_HOME="$home" "$ROOT/bin/fm-sailor.sh" provider-json hf "$MODEL" | jq -c '{provider: .}') ||
    guard_fail "provider-json failed"
  assert_contains "$config" "\"apiKey\":\"{env:$VAR}\"" "the provider entry must name the variable"

  : > "$TMP_ROOT/requests.log"
  run_opencode "$TMP_ROOT/control" "$TMP_ROOT/control.out" "$config"
  requests=$(grep '^POST' "$TMP_ROOT/requests.log")
  [ -n "$requests" ] || guard_fail "the control run sent no model request; see $(tail -c 400 "$TMP_ROOT/control.out" | tr -cd '[:print:]\n')"
  assert_equals "" "$(awk -F'\t' '$2 != "-"' <<<"$requests")" \
    "opencode $OPENCODE_VERSION: without the variable in its environment, OpenCode must send no Authorization header, or this guard proves nothing"

  : > "$TMP_ROOT/requests.log"
  run_opencode "$home" "$TMP_ROOT/token.out" "$config" "$ROOT/bin/fm-sailor.sh" with-token "$VAR" "$home/.env" --
  requests=$(grep '^POST' "$TMP_ROOT/requests.log")
  [ -n "$requests" ] || guard_fail "the token run sent no model request; see $(tail -c 400 "$TMP_ROOT/token.out" | tr -cd '[:print:]\n')"
  assert_equals "" "$(awk -F'\t' -v want="Bearer $SENTINEL" '$2 != want' <<<"$requests")" \
    "opencode $OPENCODE_VERSION: every model request must carry the sailor's token as its bearer token"
  assert_equals "" "$(awk -F'\t' -v want="$MODEL" '$3 != want' <<<"$requests")" \
    "opencode $OPENCODE_VERSION: every model request must name the routed model id unchanged"
  grep -qF -- "--model hf/$MODEL" "$TMP_ROOT/token.out.ps" ||
    guard_fail "the sampler never saw OpenCode's own command line, so it proves nothing about command lines"
  assert_no_grep "$SENTINEL" "$TMP_ROOT/token.out.ps" "opencode $OPENCODE_VERSION: the token must be on no process command line"
  assert_no_grep "$SENTINEL" "$TMP_ROOT/token.out" "opencode $OPENCODE_VERSION: the token must not be printed"
  leaks=$(grep -rl --exclude=.env -- "$SENTINEL" "$home" 2>/dev/null)
  [ -z "$leaks" ] || guard_fail "the token must be written nowhere but .env, including OpenCode's own data and logs: $leaks"
  pass "opencode $OPENCODE_VERSION sends a sailor's token from its environment as the bearer token on every model request, with the routed model id, and the token reaches no command line, output, or file"
}

test_sailor_token_reaches_only_the_model_requests

echo "# all fm-sailor-token-live-e2e tests passed"
