#!/usr/bin/env bash
# tests/fm-privateer-sessionstart-live-e2e.test.sh - a Privateer first mate
# takes the helm by itself: the real OpenCode first mate, in a session started
# by bin/fm-privateer.sh exactly as the captain would start one, receives the
# session-start digest, injected by the run-tier plugin (docs/sessionstart-
# nudge.md "OpenCode") before its first model call, with no model step in
# between. The digest must have taken the fleet lock for that OpenCode process,
# and after a compaction the re-emitted digest must reach the model again.
#
# The launcher runs the real OpenCode primary with the real firstmate plugins,
# inside the real macOS sandbox, behind the launcher's own egress proxy, with a
# throwaway Privateer home and a fixture clone of this checkout outside it. The
# session's only sailor is a scripted OpenAI-compatible model on a loopback
# port that answers every request with a plain reply and logs the user text it
# was sent. It spends no model tokens but starts a whole supervised primary
# session, so it stays opt-in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PRIVATEER_SESSIONSTART_LIVE opencode tmux sandbox-exec python3 jq git

TMP_ROOT=$(fm_test_tmproot fm-privateer-sessionstart-live)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
OPENCODE_VERSION=$(opencode --version 2>/dev/null | head -1)
SERVER_PID=
SOCKET=
OUTSIDE=

cleanup() {
  if [ -n "$SOCKET" ] && tmux -L "$SOCKET" has-session -t privateer 2>/dev/null; then
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null
  # OpenCode's helper processes outlive the server by a moment and recreate
  # their data directory, so let them go before the fixture is removed.
  sleep 2
  [ -z "$OUTSIDE" ] || rm -rf "$OUTSIDE"
  fm_test_cleanup
  if [ -e "$TMP_ROOT" ]; then
    sleep 2
    rm -rf "$TMP_ROOT" 2>/dev/null || true
  fi
}
trap cleanup EXIT

guard_fail() {
  fail "opencode $OPENCODE_VERSION in a Privateer session: $*"
}

# write_model <path>: the scripted model. argv: port file and request log. Each
# chat request appends one JSON line holding the text of every user message.
write_model() {
  cat > "$1" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT_FILE, LOG = sys.argv[1], sys.argv[2]

def chunk(delta, finish=None):
    return "data: " + json.dumps({"id": "c", "object": "chat.completion.chunk", "created": int(time.time()),
        "model": "scripted", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n"

def user_text(request):
    out = []
    for message in request.get("messages") or []:
        if message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, list):
            content = "".join(part.get("text", "") for part in content if isinstance(part, dict))
        out.append(content or "")
    return out

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def reply(self, code, body, ctype):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path.startswith("/v1/models"):
            self.reply(200, json.dumps({"object": "list", "data": [{"id": "scripted", "object": "model"}]}), "application/json")
        else:
            self.reply(404, "no such route\n", "text/plain")
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if not self.path.startswith("/v1/chat/completions"):
            return self.reply(404, "no such route\n", "text/plain")
        try:
            request = json.loads(raw or b"{}")
        except ValueError:
            request = {}
        with open(LOG, "a") as f:
            f.write(json.dumps({"user": user_text(request)}) + "\n")
        body = chunk({"role": "assistant", "content": "Aye. Standing by."}) + chunk({}, "stop") + "data: [DONE]\n\n"
        self.reply(200, body, "text/event-stream")

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORT_FILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
}

# digest_requests <log> <banner>: how many logged requests carried a user
# message that is typed session-start input and holds the banner.
digest_requests() {
  jq -r --arg banner "$2" \
    'select(any(.user[]; startswith("⁣FIRSTMATE_OP: v1 session-start: ") and contains($banner))) | 1' \
    "$1" 2>/dev/null | wc -l | tr -d ' '
}

test_privateer_first_mate_takes_the_helm_by_itself() {
  local case_dir home root port out status log pid comm started elapsed pane
  case_dir="$TMP_ROOT/case"
  home="$case_dir/home"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/projects"
  OUTSIDE=$(mktemp -d /tmp/pv-start-live.XXXXXX)
  root="$OUTSIDE/root"
  git clone -q "$ROOT" "$root" || guard_fail "the fixture clone of this checkout failed"
  cp -R "$ROOT/bin/." "$root/bin/"
  cp -R "$ROOT/.opencode/." "$root/.opencode/"
  mkdir -p "$root/docs/privateer"
  cp -R "$ROOT/docs/privateer/." "$root/docs/privateer/"
  git -C "$root" remote set-url origin https://github.com/cbcotton/firstmate.git

  log="$case_dir/model.log"
  : > "$log"
  write_model "$case_dir/model.py"
  python3 "$case_dir/model.py" "$case_dir/port" "$log" &
  SERVER_PID=$!
  for _ in $(seq 100); do
    [ -s "$case_dir/port" ] && break
    sleep 0.05
  done
  port=$(cat "$case_dir/port" 2>/dev/null)
  [ -n "$port" ] || guard_fail "the scripted model did not start"

  printf 'tiller/scripted\n' > "$home/config/privateer"
  printf 'opencode\n' > "$home/config/crew-harness"
  : > "$home/config/sailor-sandbox"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf '{"sailors":{"tiller":{"title":"Start","endpoint":"http://127.0.0.1:%s/v1","status":"live","models":["scripted"]}},"default":{"harness":"opencode","sailor":"tiller","model":"scripted"}}\n' "$port" \
    > "$home/config/crew-dispatch.json"
  fm_test_track_watcher_state "$home/state"

  out=$(cd "$case_dir" && FM_HOME="$home" "$root/bin/fm-privateer.sh" start 2>&1)
  status=$?
  [ "$status" = 0 ] || guard_fail "the launcher refused to start: $out"
  SOCKET=$(printf '%s\n' "$out" | sed -n 's/.*on tmux socket \([^ ]*\).*/\1/p' | head -1)
  [ -n "$SOCKET" ] || guard_fail "the launcher did not report its tmux socket: $out"

  # OpenCode creates its session when the first message is submitted, so the
  # captain's first message is what opens it; the digest must still reach the
  # model in the request that answers that message. The sandboxed OpenCode can spend
  # over a minute at startup on a blocked plugin install before its composer
  # is ready.
  started=$(date +%s)
  for _ in $(seq 480); do
    tmux -L "$SOCKET" capture-pane -p -t privateer:firstmate 2>/dev/null | grep -Fq 'Ask anything' && break
    tmux -L "$SOCKET" has-session -t privateer 2>/dev/null || guard_fail "the session ended before its composer was ready"
    sleep 0.5
  done
  sleep 2
  tmux -L "$SOCKET" send-keys -t privateer:firstmate -l 'CAPTAIN_FIRST_MESSAGE' 2>/dev/null || true
  tmux -L "$SOCKET" send-keys -t privateer:firstmate Enter 2>/dev/null || true
  for _ in $(seq 480); do
    [ "$(digest_requests "$log" 'SESSION START - ')" != 0 ] && break
    tmux -L "$SOCKET" has-session -t privateer 2>/dev/null || guard_fail "the session ended before the digest arrived"
    sleep 0.5
  done
  elapsed=$(( $(date +%s) - started ))
  pane=$(tmux -L "$SOCKET" capture-pane -p -t privateer:firstmate 2>/dev/null | tr -cd '[:print:]\n' | tail -20)
  [ "$(digest_requests "$log" 'SESSION START - ')" != 0 ] ||
    guard_fail "no model request carried the injected session-start digest; model log: $(cat "$log"); pane: $pane"
  # The model's first answering request, not the title request, must already
  # hold both the captain's message and the digest.
  jq -e -s '[.[] | select(.user[0] | startswith("Generate a title") | not)][0].user
    | any(.[]; startswith("\u2063FIRSTMATE_OP: v1 session-start: ")) and any(.[]; . == "CAPTAIN_FIRST_MESSAGE")' "$log" >/dev/null ||
    guard_fail "the model's first answering request did not hold the digest with the captain's message: $(head -c 600 "$log")"

  pid=$(cat "$home/state/.lock" 2>/dev/null)
  [ -n "$pid" ] || guard_fail "the injected digest left no fleet lock"
  comm=$(ps -o comm= -p "$pid" 2>/dev/null)
  [ "$(basename -- "$comm")" = opencode ] || guard_fail "the lock names pid $pid, which runs '$comm', not the OpenCode first mate"
  [ -f "$home/state/.session-start-complete" ] || guard_fail "the injected digest left no completed-startup record"
  jq -e -s 'any(.[].user[]; contains("READ-ONLY SESSION"))' "$log" >/dev/null 2>&1 &&
    guard_fail "the injected digest reported a read-only session"

  # Compaction: the re-emitted digest must reach the model again.
  tmux -L "$SOCKET" send-keys -t privateer:firstmate -l '/compact' 2>/dev/null || true
  tmux -L "$SOCKET" send-keys -t privateer:firstmate Enter 2>/dev/null || true
  for _ in $(seq 240); do
    [ "$(digest_requests "$log" 'SESSION START (CONTEXT RE-EMIT) - ')" != 0 ] && break
    sleep 0.5
  done
  [ "$(digest_requests "$log" 'SESSION START (CONTEXT RE-EMIT) - ')" != 0 ] ||
    guard_fail "no model request carried the re-emitted digest after /compact; model log: $(cat "$log")"

  out=$(FM_HOME="$home" "$root/bin/fm-privateer.sh" stop 2>&1)
  status=$?
  [ "$status" = 0 ] || guard_fail "the launcher could not stop the idle session: $out"
  SOCKET=
  pass "opencode $OPENCODE_VERSION as a Privateer first mate received the session-start digest in its first answering request, with the captain's first message (after ${elapsed}s), which took the fleet lock for its own OpenCode process (pid $pid), and received the re-emitted digest after /compact"
}

test_privateer_first_mate_takes_the_helm_by_itself

echo "# all fm-privateer-sessionstart-live-e2e tests passed"
