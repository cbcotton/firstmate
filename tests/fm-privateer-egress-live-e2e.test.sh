#!/usr/bin/env bash
# tests/fm-privateer-egress-live-e2e.test.sh - the Privateer egress audit: a
# short Privateer session, started by bin/fm-privateer.sh exactly as the
# captain would start one, makes zero connection attempts to Anthropic.
#
# The launcher runs the real OpenCode primary, inside the real macOS sandbox,
# behind the launcher's own egress proxy, in a fixture clone of this checkout
# whose origin is an https forge, with a throwaway Privateer home, so the real
# firstmate plugins load and the real watcher arms. The session's only sailor
# is a scripted OpenAI-compatible model on a loopback port that records every
# request and answers with a plain reply. Before OpenCode starts, the primary's
# command first tries two direct connections that ignore the proxy variables,
# one to Anthropic and one to the sailor itself, inside the same sandbox; both
# must be denied. The proxy's own log must then name at least one allowed
# request to the sailor, allow nothing but the sailor and the forge, and name
# no Anthropic or Claude host among every allowed and refused destination, so
# the audit can never pass by checking nothing. It spends no model tokens but
# starts a whole supervised primary session, so it stays opt-in.
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

# write_model <path>: the scripted model, recording every request it serves.
write_model() {
  cat > "$1" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT_FILE, LOG = sys.argv[1], sys.argv[2]

def chunk(delta, finish=None):
    return "data: " + json.dumps({"id": "c", "object": "chat.completion.chunk", "created": int(time.time()),
        "model": "scripted", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n"

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def reply(self, code, body, ctype):
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path}) + "\n")
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
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.startswith("/v1/chat/completions"):
            body = chunk({"role": "assistant", "content": "Aye. Nothing to do; standing by."}) + chunk({}, "stop") + "data: [DONE]\n\n"
            self.reply(200, body, "text/event-stream")
        else:
            self.reply(404, "no such route\n", "text/plain")

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORT_FILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
}

# write_probe_primary <path> <sailor-port>: the primary's command. Inside the
# sandbox it tries a direct connection to Anthropic and to the sailor, both
# ignoring the proxy, records each curl status in the home, then runs OpenCode.
write_probe_primary() {
  cat > "$1" <<SH
#!/bin/sh
/usr/bin/curl --noproxy '*' -sS -m 5 -o /dev/null https://api.anthropic.com/ 2>/dev/null
anthropic=\$?
/usr/bin/curl --noproxy '*' -sS -m 5 -o /dev/null http://127.0.0.1:$2/v1/models 2>/dev/null
sailor=\$?
printf 'anthropic=%s sailor=%s\\n' "\$anthropic" "\$sailor" > "\$FM_HOME/state/direct-probe"
exec opencode
SH
  chmod +x "$1"
}

test_privateer_session_reaches_nothing_but_its_sailor() {
  local case_dir root port out status log egress model_requests proxied allowed anthropic probe destinations pane started typed=no elapsed
  case_dir="$TMP_ROOT/case"
  HOME_DIR="$case_dir/home"
  root="$case_dir/root"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects"
  # The first mate runs the working tree's scripts and plugins from a fixture
  # clone, so nothing it writes lands in this checkout; its origin is an https
  # forge, so the proxy allows that forge on 443 and nothing else there.
  git clone -q "$ROOT" "$root" || guard_fail "the fixture clone of this checkout failed"
  cp -R "$ROOT/bin/." "$root/bin/"
  cp -R "$ROOT/.opencode/." "$root/.opencode/"
  git -C "$root" remote set-url origin https://github.com/cbcotton/firstmate.git
  LAUNCHER="$root/bin/fm-privateer.sh"

  write_model "$case_dir/model.py"
  log="$case_dir/model.log"
  : > "$log"
  python3 "$case_dir/model.py" "$case_dir/port" "$log" &
  SERVER_PID=$!
  for _ in $(seq 100); do
    [ -s "$case_dir/port" ] && break
    sleep 0.05
  done
  port=$(cat "$case_dir/port" 2>/dev/null)
  [ -n "$port" ] || guard_fail "the scripted model did not start"
  write_probe_primary "$case_dir/primary" "$port"

  printf 'tiller/scripted\n' > "$HOME_DIR/config/privateer"
  printf 'opencode\n' > "$HOME_DIR/config/crew-harness"
  : > "$HOME_DIR/config/sailor-sandbox"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  printf '{"sailors":{"tiller":{"title":"Audit","endpoint":"http://127.0.0.1:%s/v1","status":"live","models":["scripted"]}},"default":{"harness":"opencode","sailor":"tiller","model":"scripted"}}\n' "$port" \
    > "$HOME_DIR/config/crew-dispatch.json"
  fm_test_track_watcher_state "$HOME_DIR/state"
  egress="$HOME_DIR/state/privateer/egress/log"

  out=$(cd "$case_dir" && ANTHROPIC_API_KEY=sk-audit-decoy FM_TEST_SEAM=1 FM_PRIVATEER_PRIMARY="$case_dir/primary" \
    FM_HOME="$HOME_DIR" "$LAUNCHER" start 2>&1)
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
    model_requests=$(jq -r 'select(.path | test("/v1/chat/completions")) | .path' "$log" 2>/dev/null | wc -l | tr -d ' ')
    [ "$model_requests" -gt 0 ] && break
    if [ "$i" = 160 ]; then
      typed=yes
      tmux -L "$SOCKET" send-keys -t privateer:firstmate -l 'egress audit: say nothing and stand by' 2>/dev/null || true
      tmux -L "$SOCKET" send-keys -t privateer:firstmate Enter 2>/dev/null || true
    fi
    tmux -L "$SOCKET" has-session -t privateer 2>/dev/null || guard_fail "the session ended before its first model request; proxy log: $(cat "$egress" 2>/dev/null)"
    sleep 0.5
  done
  elapsed=$(( $(date +%s) - started ))
  pane=$(tmux -L "$SOCKET" capture-pane -p -t privateer:firstmate 2>/dev/null | tr -cd '[:print:]\n' | tail -20)
  [ "$model_requests" -gt 0 ] || guard_fail "no model request reached the sailor, so the session proves nothing; pane: $pane; proxy log: $(cat "$egress" 2>/dev/null)"

  out=$(FM_HOME="$HOME_DIR" "$LAUNCHER" stop 2>&1)
  status=$?
  [ "$status" = 0 ] || guard_fail "the launcher could not stop the idle session: $out"
  SOCKET=

  probe=$(cat "$HOME_DIR/state/direct-probe" 2>/dev/null)
  case "$probe" in
    "anthropic=0 "* | '') guard_fail "a direct connection to Anthropic that ignored the proxy was not denied: '${probe:-no probe ran}'" ;;
  esac
  case "$probe" in
    *" sailor=0") guard_fail "a direct connection to the sailor that ignored the proxy was not denied: '$probe'" ;;
  esac
  [ -s "$egress" ] || guard_fail "the egress proxy logged nothing"
  proxied=$(jq -r --arg d "127.0.0.1:$port" 'select(.verdict == "allowed" and .dest == $d) | .dest' "$egress" | wc -l | tr -d ' ')
  [ "$proxied" -gt 0 ] || guard_fail "no sailor request passed through the egress proxy: $(cat "$egress")"
  allowed=$(jq -r --arg d "127.0.0.1:$port" 'select(.verdict == "allowed" and .dest != $d and .dest != "github.com:443") | .dest' "$egress")
  [ -z "$allowed" ] || guard_fail "the egress proxy allowed a destination other than the sailor and the forge:"$'\n'"$allowed"
  anthropic=$(jq -r 'select(.dest | ascii_downcase | test("anthropic|claude")) | "\(.verdict) \(.method) \(.dest)"' "$egress")
  [ -z "$anthropic" ] || guard_fail "the session attempted to reach Anthropic:"$'\n'"$anthropic"
  destinations=$(jq -r '"\(.verdict) \(.dest)"' "$egress" | LC_ALL=C sort | uniq -c | tr -s ' ' | sed 's/^ //' | paste -sd ';' -)
  pass "opencode $OPENCODE_VERSION in a Privateer session made $model_requests model request(s) to its sailor through the egress proxy (first after ${elapsed}s, typed prompt needed: $typed), its direct connections around the proxy were denied ($probe), and the proxy recorded zero Anthropic destinations among: $destinations"
}

test_privateer_session_reaches_nothing_but_its_sailor

echo "# all fm-privateer-egress-live-e2e tests passed"
