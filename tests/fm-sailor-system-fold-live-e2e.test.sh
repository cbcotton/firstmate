#!/usr/bin/env bash
# tests/fm-sailor-system-fold-live-e2e.test.sh - the system-fold plugin a sailor
# launch gets makes the real OpenCode send one system message.
#
# How OpenCode turns its system prompt into messages, and in which order it runs
# plugins, is decided inside OpenCode, so this is a harness-dependent check
# (firstmate-coding-guidelines, "Harness-dependent checks"). The sailor spawn
# runs for real against a fake tmux; the real OpenCode then runs headless in the
# spawned copy, with a global plugin that adds system text as the AXI plugins
# do, against a loopback server that records every request and answers "ok",
# so the run spends no model tokens and the guard runs by default wherever its
# tools are installed. A control run in a copy without the fold must still send
# two system messages, so the guard cannot pass vacuously.
# `opencode run` reads standard input when it is not a terminal and waits for
# it to close, so each run gets /dev/null rather than whatever the caller holds.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_SAILOR_SYSTEM_FOLD_LIVE opencode python3 jq git

TMP_ROOT=$(fm_test_tmproot fm-sailor-system-fold-live)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
OPENCODE_VERSION=$(opencode --version 2>/dev/null | head -1)
SERVER_PID=

cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null
  # fm-spawn writes the task's Git hooks directory read-only.
  chmod -R u+w "$TMP_ROOT" 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

guard_fail() {
  fail "opencode $OPENCODE_VERSION: $*"
}

write_recording_sailor() {  # <path>
  cat > "$1" <<'PY'
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT_FILE, OUT = sys.argv[1], sys.argv[2]

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
        with open(OUT, "a") as f:
            f.write(json.dumps([m.get("role") for m in req.get("messages", [])]) + "\t"
                    + json.dumps("\n".join(m.get("content") for m in req.get("messages", [])
                                           if m.get("role") == "system" and isinstance(m.get("content"), str))) + "\n")
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

# run_opencode <dir> <xdg-root> <requests-log> <port>: one headless turn in
# <dir> on the scripted sailor, with the global plugin under <xdg-root>.
run_opencode() {
  local dir=$1 xdg=$2 port=$4 provider
  provider=$(jq -cn --arg url "http://127.0.0.1:$port/v1" \
    '{provider: {tiller: {npm: "@ai-sdk/openai-compatible", name: "tiller", options: {baseURL: $url}, models: {scripted: {name: "scripted"}}}}}')
  (
    cd "$dir" || exit 1
    XDG_CONFIG_HOME="$xdg/config" XDG_DATA_HOME="$xdg/data" XDG_STATE_HOME="$xdg/state" \
      OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_CONFIG_CONTENT="$provider" \
      perl -e 'alarm 180; exec @ARGV' opencode run --model tiller/scripted "Say hi."
  ) </dev/null >"$3.out" 2>&1
}

test_sailor_launch_sends_one_system_message() {
  local case_dir home proj wt control fakebin id port out status xdg roles text
  id=fold-live-s1
  case_dir="$TMP_ROOT/case"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  control="$case_dir/control"
  xdg="$case_dir/xdg"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" opencode
  fm_git_worktree "$proj" "$wt" "task-$id"
  fm_test_spawn_brief "$home" "$id"
  wt=$(cd "$wt" && pwd -P)
  mkdir -p "$control" "$xdg/config/opencode/plugins"
  git -C "$control" init -q
  cat > "$xdg/config/opencode/plugins/extra-system.js" <<'JS'
export const ExtraSystem = async () => ({
  "experimental.chat.system.transform": async (_input, output) => {
    output.system.push("## Extra system context: fold guard");
  },
});
JS

  write_recording_sailor "$case_dir/sailor.py"
  python3 "$case_dir/sailor.py" "$case_dir/port" "$case_dir/requests.log" &
  SERVER_PID=$!
  for _ in $(seq 100); do
    [ -s "$case_dir/port" ] && break
    sleep 0.05
  done
  port=$(cat "$case_dir/port" 2>/dev/null)
  [ -n "$port" ] || guard_fail "the recording sailor did not start"
  printf '{"sailors":{"tiller":{"endpoint":"http://127.0.0.1:%s/v1","status":"live","models":["scripted"]}}}\n' "$port" \
    > "$home/config/crew-dispatch.json"

  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode local-only --yolo off \
      --harness opencode --model scripted --sailor tiller)
  status=$?
  [ "$status" = 0 ] || guard_fail "the sailor spawn failed: $out"
  assert_present "$wt/.opencode/plugins/fm-sailor-system-fold.js" "the sailor spawn did not write the system-fold plugin"

  : > "$case_dir/requests.log"
  run_opencode "$control" "$xdg" "$case_dir/control" "$port"
  [ -s "$case_dir/requests.log" ] || guard_fail "the control run sent no request; see $(tail -c 400 "$case_dir/control.out" | tr -cd '[:print:]\n')"
  roles=$(cut -f1 "$case_dir/requests.log" | jq -s 'map(map(select(. == "system")) | length) | max')
  assert_equals 2 "$roles" "opencode $OPENCODE_VERSION: without the fold, a plugin's system text must still arrive as a second system message, or this guard proves nothing"

  : > "$case_dir/requests.log"
  run_opencode "$wt" "$xdg" "$case_dir/sailor" "$port"
  [ -s "$case_dir/requests.log" ] || guard_fail "the sailor run sent no request; see $(tail -c 400 "$case_dir/sailor.out" | tr -cd '[:print:]\n')"
  while IFS=$'\t' read -r roles text; do
    assert_equals '"system"' "$(jq -c '.[0]' <<<"$roles")" "opencode $OPENCODE_VERSION: a sailor request must open with its system message"
    assert_equals 1 "$(jq 'map(select(. == "system")) | length' <<<"$roles")" \
      "opencode $OPENCODE_VERSION: a sailor request must carry exactly one system message, got roles $roles"
    case "$(jq -r . <<<"$text")" in
      *"## Extra system context: fold guard") ;;
      *) guard_fail "the folded system message must keep the plugin's text, last" ;;
    esac
  done < "$case_dir/requests.log"
  pass "opencode $OPENCODE_VERSION in a sailor launch sends one system message that keeps every plugin's text in order"
}

test_sailor_launch_sends_one_system_message

echo "# all fm-sailor-system-fold-live-e2e tests passed"
