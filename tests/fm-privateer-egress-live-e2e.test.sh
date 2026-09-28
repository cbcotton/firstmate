#!/usr/bin/env bash
# tests/fm-privateer-egress-live-e2e.test.sh - the Privateer egress audit: a
# short Privateer session, started by bin/fm-privateer.sh exactly as the
# captain would start one, makes zero connection attempts to Anthropic.
#
# The launcher runs the real OpenCode primary, inside the real macOS sandbox,
# in a fixture clone of this checkout with a throwaway Privateer home, so the
# real firstmate plugins load and the real watcher arms. The session's only
# sailor is a logging proxy on a loopback port that also serves a scripted
# OpenAI-compatible model: it records every request, answers the model's
# requests with a plain reply, and logs and refuses every CONNECT tunnel and
# every proxied request to any other host. The session's HTTP_PROXY and
# HTTPS_PROXY name that proxy, so a well-behaved client's outbound traffic is
# recorded there, while the sandbox refuses whatever tries to go around it.
# The guard fails unless at least one model request arrived, so it can never
# pass by checking nothing, and it fails on any recorded attempt whose target
# names Anthropic or Claude. It spends no model tokens but starts a whole
# supervised primary session, so it stays opt-in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PRIVATEER_EGRESS_LIVE opencode tmux sandbox-exec python3 jq git

TMP_ROOT=$(fm_test_tmproot fm-privateer-egress-live)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
OPENCODE_VERSION=$(opencode --version 2>/dev/null | head -1)
SERVER_PID=
SOCKET=
HOME_DIR=
LAUNCHER=

cleanup() {
  if [ -n "$SOCKET" ] && tmux -L "$SOCKET" has-session -t privateer 2>/dev/null; then
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null
  # OpenCode's helper processes outlive the server by a moment and recreate
  # their data directory, so let them go before the fixture is removed.
  sleep 2
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

# write_audit_proxy <path>: the logging proxy and scripted model in one server.
write_audit_proxy() {
  cat > "$1" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT_FILE, LOG = sys.argv[1], sys.argv[2]
PORT = 0

def chunk(delta, finish=None):
    return "data: " + json.dumps({"id": "c", "object": "chat.completion.chunk", "created": int(time.time()),
        "model": "scripted", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n"

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def record(self, kind, target):
        with open(LOG, "a") as f:
            f.write(json.dumps({"kind": kind, "target": target, "line": self.requestline}) + "\n")
    def reply(self, code, body, ctype):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_CONNECT(self):
        self.record("connect", self.path)
        self.reply(403, "tunnel refused by the egress audit\n", "text/plain")
        self.close_connection = True
    def route(self):
        path = self.path
        if path.startswith("http://") or path.startswith("https://"):
            rest = path.split("://", 1)[1]
            host, _, tail = rest.partition("/")
            path = "/" + tail
            if host not in ("127.0.0.1:%d" % PORT, "localhost:%d" % PORT):
                self.record("request", host)
                self.reply(403, "request refused by the egress audit\n", "text/plain")
                return None
        self.record("model", (self.headers.get("Host") or "") + path)
        return path
    def do_GET(self):
        path = self.route()
        if path is None:
            return
        if path.startswith("/v1/models"):
            self.reply(200, json.dumps({"object": "list", "data": [{"id": "scripted", "object": "model"}]}), "application/json")
        else:
            self.reply(404, "no such route\n", "text/plain")
    def do_POST(self):
        path = self.route()
        if path is None:
            return
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if path.startswith("/v1/chat/completions"):
            body = chunk({"role": "assistant", "content": "Aye. Nothing to do; standing by."}) + chunk({}, "stop") + "data: [DONE]\n\n"
            self.reply(200, body, "text/event-stream")
        else:
            self.reply(404, "no such route\n", "text/plain")

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
PORT = srv.server_address[1]
open(PORT_FILE, "w").write(str(PORT))
srv.serve_forever()
PY
}

test_privateer_session_reaches_nothing_but_its_sailor() {
  local case_dir root port out status log model_requests anthropic tunnels pane started typed=no elapsed
  case_dir="$TMP_ROOT/case"
  HOME_DIR="$case_dir/home"
  root="$case_dir/root"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects"
  # The first mate runs the working tree's scripts and plugins from a fixture
  # clone, so nothing it writes lands in this checkout.
  git clone -q "$ROOT" "$root" || guard_fail "the fixture clone of this checkout failed"
  cp -R "$ROOT/bin/." "$root/bin/"
  cp -R "$ROOT/.opencode/." "$root/.opencode/"
  LAUNCHER="$root/bin/fm-privateer.sh"

  write_audit_proxy "$case_dir/proxy.py"
  log="$case_dir/egress.log"
  : > "$log"
  python3 "$case_dir/proxy.py" "$case_dir/port" "$log" &
  SERVER_PID=$!
  for _ in $(seq 100); do
    [ -s "$case_dir/port" ] && break
    sleep 0.05
  done
  port=$(cat "$case_dir/port" 2>/dev/null)
  [ -n "$port" ] || guard_fail "the audit proxy did not start"

  printf 'tiller/scripted\n' > "$HOME_DIR/config/privateer"
  printf 'opencode\n' > "$HOME_DIR/config/crew-harness"
  : > "$HOME_DIR/config/sailor-sandbox"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  printf '{"sailors":{"tiller":{"title":"Audit","endpoint":"http://127.0.0.1:%s/v1","status":"live","models":["scripted"]}},"default":{"harness":"opencode","sailor":"tiller","model":"scripted"}}\n' "$port" \
    > "$HOME_DIR/config/crew-dispatch.json"
  fm_test_track_watcher_state "$HOME_DIR/state"

  out=$(cd "$case_dir" && ANTHROPIC_API_KEY=sk-audit-decoy FM_HOME="$HOME_DIR" "$LAUNCHER" start --audit-proxy "http://127.0.0.1:$port" 2>&1)
  status=$?
  [ "$status" = 0 ] || guard_fail "the launcher refused to start: $out"
  SOCKET=$(printf '%s\n' "$out" | sed -n 's/.*on tmux socket \([^ ]*\).*/\1/p' | head -1)
  [ -n "$SOCKET" ] || guard_fail "the launcher did not report its tmux socket: $out"

  # The sandboxed OpenCode can spend over a minute at startup on a blocked
  # plugin install before its first model request; a typed prompt after that
  # gives the session a turn if its own startup nudge did not.
  model_requests=0
  started=$(date +%s)
  for i in $(seq 240); do
    model_requests=$(jq -r 'select(.kind == "model" and (.target | test("/v1/chat/completions"))) | .target' "$log" 2>/dev/null | wc -l | tr -d ' ')
    [ "$model_requests" -gt 0 ] && break
    if [ "$i" = 160 ]; then
      typed=yes
      tmux -L "$SOCKET" send-keys -t privateer -l 'egress audit: say nothing and stand by' 2>/dev/null || true
      tmux -L "$SOCKET" send-keys -t privateer Enter 2>/dev/null || true
    fi
    tmux -L "$SOCKET" has-session -t privateer 2>/dev/null || guard_fail "the session ended before its first model request; proxy log: $(cat "$log")"
    sleep 0.5
  done
  elapsed=$(( $(date +%s) - started ))
  pane=$(tmux -L "$SOCKET" capture-pane -p -t privateer 2>/dev/null | tr -cd '[:print:]\n' | tail -20)
  [ "$model_requests" -gt 0 ] || guard_fail "no model request reached the sailor, so the session proves nothing; pane: $pane"

  out=$(FM_HOME="$HOME_DIR" "$LAUNCHER" stop 2>&1)
  status=$?
  [ "$status" = 0 ] || guard_fail "the launcher could not stop the idle session: $out"
  SOCKET=

  anthropic=$(jq -r 'select((.target | ascii_downcase | test("anthropic|claude")) or (.line | ascii_downcase | test("anthropic|claude"))) | .line' "$log")
  [ -z "$anthropic" ] || guard_fail "the session attempted to reach Anthropic:"$'\n'"$anthropic"
  tunnels=$(jq -r 'select(.kind == "connect" or .kind == "request") | .target' "$log" | LC_ALL=C sort | uniq -c | tr -s ' ' | sed 's/^ //' | paste -sd ';' -)
  pass "opencode $OPENCODE_VERSION in a Privateer session made $model_requests model request(s) to its sailor (first after ${elapsed}s, typed prompt needed: $typed) and zero connection attempts to Anthropic; other tunnels the proxy refused: ${tunnels:-none}"
}

test_privateer_session_reaches_nothing_but_its_sailor

echo "# all fm-privateer-egress-live-e2e tests passed"
