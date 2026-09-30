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
# the audit can never pass by checking nothing.
#
# The same session proves the helm (bin/fm-privateer.sh "The helm"), which is
# harness-dependent because OpenCode decides what reaches the model: the
# captain's home holds Claude instructions in ~/.claude/CLAUDE.md and a decoy
# skill in each of ~/.claude/skills, ~/.agents/skills, and ~/.opencode/skills,
# and the first request that offers the first mate's tools must carry the
# privateer agent's prompt and the helm's rulebook as its only instructions,
# never the checkout's AGENTS.md or the decoy instructions, and must offer
# exactly the skills under docs/privateer/skills/. It spends no model tokens
# but starts a whole supervised primary session, so it stays opt-in.
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

# write_model <path>: the scripted model, recording every request it serves,
# and for each chat request its system text and the skills it offers.
write_model() {
  cat > "$1" <<'PY'
import json, re, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT_FILE, LOG, SEEN = sys.argv[1], sys.argv[2], sys.argv[3]

def text_of(content):
    if isinstance(content, list):
        return "".join(part.get("text", "") for part in content if isinstance(part, dict))
    return content if isinstance(content, str) else ""

def record(raw):
    try:
        req = json.loads(raw or b"{}")
    except ValueError:
        return
    system = "\n".join(text_of(m.get("content")) for m in req.get("messages") or [] if m.get("role") == "system")
    tools = [t.get("function", {}) for t in req.get("tools") or []]
    offered = system + "\n" + "\n".join(t.get("description", "") for t in tools if t.get("name") == "skill")
    skills = sorted(set(re.findall(r"<name>([^<]+)</name>", "".join(re.findall(r"<available_skills>(.*?)</available_skills>", offered, re.S)))))
    with open(SEEN, "a") as f:
        f.write(json.dumps({"system": system, "skills": skills, "tools": [t.get("name") for t in tools]}) + "\n")

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
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.startswith("/v1/chat/completions"):
            record(raw)
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
exec opencode "\$@"
SH
  chmod +x "$1"
}

test_privateer_session_reaches_nothing_but_its_sailor() {
  local case_dir root port out status log egress model_requests proxied allowed anthropic probe destinations pane started typed=no elapsed
  local seen captain helm_real shown system skills name
  case_dir="$TMP_ROOT/case"
  HOME_DIR="$case_dir/home"
  root="$case_dir/root"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects"
  # The first mate runs the working tree's scripts, plugins, and Privateer
  # rulebook from a fixture clone, so nothing it writes lands in this checkout;
  # its origin is an https forge, so the proxy allows that forge on 443 and
  # nothing else there.
  git clone -q "$ROOT" "$root" || guard_fail "the fixture clone of this checkout failed"
  cp -R "$ROOT/bin/." "$root/bin/"
  cp -R "$ROOT/.opencode/." "$root/.opencode/"
  mkdir -p "$root/docs/privateer"
  cp -R "$ROOT/docs/privateer/." "$root/docs/privateer/"
  git -C "$root" remote set-url origin https://github.com/cbcotton/firstmate.git
  LAUNCHER="$root/bin/fm-privateer.sh"
  # The captain's home holds Claude instructions and a skill in each folder
  # OpenCode reads from a home; none may reach the first mate.
  captain="$case_dir/captain"
  mkdir -p "$captain/.claude/skills/decoy-claude" "$captain/.agents/skills/decoy-agents" "$captain/.opencode/skills/decoy-opencode"
  printf 'DECOY CLAUDE INSTRUCTIONS\n' > "$captain/.claude/CLAUDE.md"
  for name in decoy-claude:.claude decoy-agents:.agents decoy-opencode:.opencode; do
    printf -- '---\nname: %s\ndescription: A decoy skill from the captain home.\n---\nDecoy.\n' "${name%%:*}" \
      > "$captain/${name#*:}/skills/${name%%:*}/SKILL.md"
  done

  write_model "$case_dir/model.py"
  log="$case_dir/model.log"
  seen="$case_dir/seen.log"
  : > "$log"
  python3 "$case_dir/model.py" "$case_dir/port" "$log" "$seen" &
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

  out=$(cd "$case_dir" && HOME="$captain" ANTHROPIC_API_KEY=sk-audit-decoy FM_TEST_SEAM=1 FM_PRIVATEER_PRIMARY="$case_dir/primary" \
    FM_HOME="$HOME_DIR" "$LAUNCHER" start 2>&1)
  status=$?
  [ "$status" = 0 ] || guard_fail "the launcher refused to start: $out"
  SOCKET=$(printf '%s\n' "$out" | sed -n 's/.*on tmux socket \([^ ]*\).*/\1/p' | head -1)
  [ -n "$SOCKET" ] || guard_fail "the launcher did not report its tmux socket: $out"

  # The sandboxed OpenCode can spend over a minute at startup on a blocked
  # plugin install before its first model request; a typed prompt after that
  # gives the session a turn if its own startup nudge did not. The wait ends
  # once the first mate's own turn, which offers its tools, reaches the model,
  # not at OpenCode's title request that can arrive before it.
  model_requests=0
  started=$(date +%s)
  for i in $(seq 240); do
    model_requests=$(jq -r 'select(.path | test("/v1/chat/completions")) | .path' "$log" 2>/dev/null | wc -l | tr -d ' ')
    [ "$model_requests" -gt 0 ] && [ -n "$(jq -c 'select(.tools | index("skill"))' "$seen" 2>/dev/null | head -1)" ] && break
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

  # What the first mate's own requests showed the model: the agent that
  # replaces OpenCode's build prompt, the helm's rulebook and nothing else as
  # instructions, and exactly the helm's skills.
  helm_real=$(cd "$HOME_DIR/state/privateer/helm" && pwd -P)
  shown=$(jq -c 'select(.tools | index("skill"))' "$seen" 2>/dev/null | head -1)
  [ -n "$shown" ] || guard_fail "no request from the first mate offered its tools, so what it was shown proves nothing: $(head -c 2000 "$seen" 2>/dev/null)"
  system=$(printf '%s\n' "$shown" | jq -r '.system')
  assert_contains "$system" "You are the Privateer first mate, working for the captain in a terminal." \
    "opencode $OPENCODE_VERSION: the first mate must run as the privateer agent"
  assert_contains "$system" "Instructions from: $helm_real/AGENTS.md" \
    "opencode $OPENCODE_VERSION: the first mate must load the helm's rulebook"
  assert_contains "$system" "# Privateer first mate" "opencode $OPENCODE_VERSION: the rulebook's text must reach the model"
  assert_not_contains "$system" "This is the supervisor contract for primary firstmates" \
    "opencode $OPENCODE_VERSION: the checkout's AGENTS.md must never reach the first mate"
  assert_not_contains "$system" "DECOY CLAUDE INSTRUCTIONS" \
    "opencode $OPENCODE_VERSION: the captain's ~/.claude/CLAUDE.md must never reach the first mate"
  skills=$(printf '%s\n' "$shown" | jq -r '.skills | join(" ")')
  assert_equals "$(printf '%s\n' "$ROOT"/docs/privateer/skills/*/ | sed 's#/$##; s#.*/##' | LC_ALL=C sort | paste -sd ' ' -)" "$skills" \
    "opencode $OPENCODE_VERSION: the first mate must be offered exactly the helm's skills"
  pass "opencode $OPENCODE_VERSION in a Privateer session made $model_requests model request(s) to its sailor through the egress proxy (first after ${elapsed}s, typed prompt needed: $typed), its direct connections around the proxy were denied ($probe), and the proxy recorded zero Anthropic destinations among: $destinations; the first mate ran as the privateer agent with only the helm's rulebook as instructions and only its skills ($skills), none of the captain's own"
}

test_privateer_session_reaches_nothing_but_its_sailor

echo "# all fm-privateer-egress-live-e2e tests passed"
