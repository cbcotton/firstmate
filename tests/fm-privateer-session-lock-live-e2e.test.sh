#!/usr/bin/env bash
# tests/fm-privateer-session-lock-live-e2e.test.sh - a Privateer first mate
# owns its home: the real OpenCode first mate, in a session started by
# bin/fm-privateer.sh exactly as the captain would start one, runs
# bin/fm-session-start.sh through its own shell tool, and session start must
# acquire the fleet lock for that OpenCode process and name opencode as the
# primary harness, never fall back to a read-only session. A plain shell
# opened in the same session must still find no harness and stay read-only.
#
# The launcher runs the real OpenCode primary with the real firstmate plugins,
# inside the real macOS sandbox, behind the launcher's own egress proxy, with a
# throwaway Privateer home. The checkout is a fixture clone of this one outside
# the home and outside every path the session may write, so a command run from
# it has no writable current directory to fall back on. The session's only
# sailor is a scripted OpenAI-compatible model on a loopback port that answers
# the first turn offering tools with one shell tool call and every other
# request with a plain reply. It spends no model tokens but starts a whole
# supervised primary session, so it stays opt-in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PRIVATEER_SESSION_LOCK_LIVE opencode tmux sandbox-exec python3 jq git

TMP_ROOT=$(fm_test_tmproot fm-privateer-session-lock-live)
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

# write_model <path>: the scripted model. argv: port file, request log, and the
# shell command its one tool call runs.
write_model() {
  cat > "$1" <<'PY'
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT_FILE, LOG, COMMAND = sys.argv[1], sys.argv[2], sys.argv[3]
lock = threading.Lock()
called = []

def chunk(delta, finish=None):
    return "data: " + json.dumps({"id": "c", "object": "chat.completion.chunk", "created": int(time.time()),
        "model": "scripted", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n"

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def reply(self, code, body, ctype, answer=""):
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "answer": answer}) + "\n")
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
            tools = [t.get("function", {}).get("name") for t in json.loads(raw or b"{}").get("tools") or []]
        except ValueError:
            tools = []
        with lock:
            call = "bash" in tools and not called
            if call:
                called.append(True)
        if call:
            args = json.dumps({"command": COMMAND, "description": "Run firstmate session start"})
            body = chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": "call_start", "type": "function",
                "function": {"name": "bash", "arguments": args}}]}) + chunk({}, "tool_calls") + "data: [DONE]\n\n"
            return self.reply(200, body, "text/event-stream", "tool-call")
        body = chunk({"role": "assistant", "content": "Aye. Standing by."}) + chunk({}, "stop") + "data: [DONE]\n\n"
        self.reply(200, body, "text/event-stream", "text")

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORT_FILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
}

test_privateer_first_mate_owns_its_session_lock() {
  local case_dir home root port out status log start_out pid comm plain started elapsed typed=no pane i
  case_dir="$TMP_ROOT/case"
  home="$case_dir/home"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/projects"
  OUTSIDE=$(mktemp -d /tmp/pv-lock-live.XXXXXX)
  root="$OUTSIDE/root"
  git clone -q "$ROOT" "$root" || guard_fail "the fixture clone of this checkout failed"
  cp -R "$ROOT/bin/." "$root/bin/"
  cp -R "$ROOT/.opencode/." "$root/.opencode/"
  git -C "$root" remote set-url origin https://github.com/cbcotton/firstmate.git

  log="$case_dir/model.log"
  : > "$log"
  write_model "$case_dir/model.py"
  # shellcheck disable=SC2016 # expanded by the first mate's shell tool
  python3 "$case_dir/model.py" "$case_dir/port" "$log" \
    'bin/fm-session-start.sh > "$FM_HOME/state/session-start.tmp" 2>&1; mv "$FM_HOME/state/session-start.tmp" "$FM_HOME/state/session-start.out"' &
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
  printf '{"sailors":{"tiller":{"title":"Lock","endpoint":"http://127.0.0.1:%s/v1","status":"live","models":["scripted"]}},"default":{"harness":"opencode","sailor":"tiller","model":"scripted"}}\n' "$port" \
    > "$home/config/crew-dispatch.json"
  fm_test_track_watcher_state "$home/state"
  start_out="$home/state/session-start.out"

  out=$(cd "$case_dir" && FM_HOME="$home" "$root/bin/fm-privateer.sh" start 2>&1)
  status=$?
  [ "$status" = 0 ] || guard_fail "the launcher refused to start: $out"
  SOCKET=$(printf '%s\n' "$out" | sed -n 's/.*on tmux socket \([^ ]*\).*/\1/p' | head -1)
  [ -n "$SOCKET" ] || guard_fail "the launcher did not report its tmux socket: $out"

  # The sandboxed OpenCode can spend over a minute at startup on a blocked
  # plugin install before its first model request; a typed prompt after that
  # gives the session a turn if its own startup nudge did not.
  started=$(date +%s)
  for i in $(seq 360); do
    [ -e "$start_out" ] && break
    if [ "$i" = 160 ]; then
      typed=yes
      tmux -L "$SOCKET" send-keys -t privateer:firstmate -l 'run firstmate session start' 2>/dev/null || true
      tmux -L "$SOCKET" send-keys -t privateer:firstmate Enter 2>/dev/null || true
    fi
    tmux -L "$SOCKET" has-session -t privateer 2>/dev/null || guard_fail "the session ended before session start ran"
    sleep 0.5
  done
  elapsed=$(( $(date +%s) - started ))
  pane=$(tmux -L "$SOCKET" capture-pane -p -t privateer:firstmate 2>/dev/null | tr -cd '[:print:]\n' | tail -20)
  [ -e "$start_out" ] || guard_fail "the first mate never ran session start through its shell tool; model log: $(cat "$log"); pane: $pane"

  pid=$(sed -n 's/^lock acquired: harness pid \([0-9][0-9]*\)$/\1/p' "$start_out" | head -1)
  [ -n "$pid" ] || guard_fail "session start did not acquire the fleet lock:"$'\n'"$(sed -n '/^LOCK/,/^BOOTSTRAP/p' "$start_out")"
  ! grep -q 'READ-ONLY SESSION' "$start_out" || guard_fail "session start fell back to a read-only session"
  grep -q '^SUPERVISION OPERATING INSTRUCTIONS - primary harness: opencode$' "$start_out" ||
    guard_fail "session start did not name opencode as the primary harness: $(grep 'primary harness' "$start_out")"
  comm=$(ps -o comm= -p "$pid" 2>/dev/null)
  [ "$(basename -- "$comm")" = opencode ] || guard_fail "the lock names pid $pid, which runs '$comm', not the OpenCode first mate"

  # A plain shell opened in the sealed session, while the first mate holds the lock.
  tmux -L "$SOCKET" new-window -d -t privateer \
    "/bin/sh -c 'echo \"harness=\$($root/bin/fm-harness.sh 2>&1)\" > \"\$FM_HOME/state/plain.tmp\"; $root/bin/fm-lock.sh >> \"\$FM_HOME/state/plain.tmp\" 2>&1; echo \"lock=\$?\" >> \"\$FM_HOME/state/plain.tmp\"; mv \"\$FM_HOME/state/plain.tmp\" \"\$FM_HOME/state/plain\"'" ||
    guard_fail "tmux could not open a plain shell in the session"
  for _ in $(seq 100); do
    [ -e "$home/state/plain" ] && break
    sleep 0.2
  done
  plain=$(cat "$home/state/plain" 2>/dev/null)
  assert_equals "harness=unknown
error: cannot locate harness process in ancestry
lock=1" "$plain" "a plain shell in the sealed session must find no harness and stay read-only"
  assert_equals "$pid" "$(cat "$home/state/.lock" 2>/dev/null)" "the plain shell must leave the first mate's lock in place"

  out=$(FM_HOME="$home" "$root/bin/fm-privateer.sh" stop 2>&1)
  status=$?
  [ "$status" = 0 ] || guard_fail "the launcher could not stop the idle session: $out"
  SOCKET=
  pass "opencode $OPENCODE_VERSION as a Privateer first mate ran session start through its shell tool (after ${elapsed}s, typed prompt needed: $typed), which acquired the fleet lock for its own OpenCode process (pid $pid) and named opencode as the primary harness, while a plain shell in the same session found no harness and stayed read-only"
}

test_privateer_first_mate_owns_its_session_lock

echo "# all fm-privateer-session-lock-live-e2e tests passed"
