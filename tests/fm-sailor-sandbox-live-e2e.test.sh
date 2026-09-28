#!/usr/bin/env bash
# tests/fm-sailor-sandbox-live-e2e.test.sh - a sandboxed sailor launch, exactly
# as bin/fm-spawn.sh builds it, confines the real interactive OpenCode.
#
# The spawn runs for real against a fake tmux that only records the launch
# command. That exact command then runs on a pseudo-terminal with the real
# macOS sandbox and the real OpenCode, pointed at a scripted OpenAI-compatible
# sailor on a loopback port, so the run spends no model tokens and the guard
# runs by default wherever its tools are installed. The OpenCode permission
# profile is left at allow, so the sandbox alone must stop every step it
# should; each verdict is read from the filesystem.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_SAILOR_SANDBOX_LIVE opencode sandbox-exec script python3 jq git

TMP_ROOT=$(fm_test_tmproot fm-sailor-sandbox-live)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
OPENCODE_VERSION=$(opencode --version 2>/dev/null | head -1)
SERVER_PID=
TUI_PID=
OUTSIDE=

# kill_tree <pid>: the pseudo-terminal's whole process tree, deepest first, so
# OpenCode has stopped writing before its files are removed.
kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$child"
  done
  kill "$1" 2>/dev/null
}

cleanup() {
  if [ -n "$TUI_PID" ]; then
    kill_tree "$TUI_PID"
    wait "$TUI_PID" 2>/dev/null
    sleep 1
  fi
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null
  [ -z "$OUTSIDE" ] || rm -rf "$OUTSIDE"
  # fm-spawn writes the task's Git hooks directory read-only.
  chmod -R u+w "$TMP_ROOT" 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

guard_fail() {
  fail "opencode $OPENCODE_VERSION under sandbox-exec: $*"
}

write_scripted_sailor() {  # <path>
  cat > "$1" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT_FILE, SCRIPT = sys.argv[1], sys.argv[2]
STEPS = json.load(open(SCRIPT))

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
        done = sum(1 for m in req.get("messages", []) if m.get("role") == "tool")
        step = STEPS[done] if req.get("tools") and done < len(STEPS) else None
        if step is None:
            parts = [chunk({"role": "assistant", "content": "done"}), chunk({}, "stop")]
        else:
            call = {"index": 0, "id": "call_%d" % done, "type": "function",
                    "function": {"name": step["tool"], "arguments": json.dumps(step["args"])}}
            parts = [chunk({"role": "assistant", "tool_calls": [call]}), chunk({}, "tool_calls")]
        self.reply("".join(parts) + "data: [DONE]\n\n", "text/event-stream")

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORT_FILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
}

test_sandboxed_sailor_launch_confines_the_real_opencode() {
  local case_dir home proj wt fakebin launchlog id port out status common real_cache
  id=sandbox-live-s1
  case_dir="$TMP_ROOT/case"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  launchlog="$case_dir/launch.log"
  fm_test_spawn_home "$home" opencode
  fm_git_worktree "$proj" "$wt" "task-$id"
  fm_test_spawn_brief "$home" "$id"
  wt=$(cd "$wt" && pwd -P)
  git -C "$wt" config user.name 'Sandboxed Sailor'
  git -C "$wt" config user.email sailor@example.invalid
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)
  # Outside every allowed path, including this process's own $TMPDIR.
  OUTSIDE=$(mktemp -d /private/tmp/fm-sailor-sandbox-outside.XXXXXX)

  jq -n --arg wt "$wt" --arg meta "$home/state/$id.meta" --arg status "$home/state/$id.status" \
    --arg hook "$common/hooks/pre-commit" --arg outside "$OUTSIDE/escaped.txt" \
    --arg outside_redirect "$OUTSIDE/redirected.txt" --arg outside_diff "$OUTSIDE/diff.txt" --arg q "'" '[
    {tool: "edit", args: {filePath: ($wt + "/README.md"), oldString: "project", newString: "sailor"}},
    {tool: "bash", args: {command: "git commit -qam \"sailor edit\"", description: "commit"}},
    {tool: "bash", args: {command: ("echo \"working [at=1]: sandboxed\" >> " + $q + $status + $q + ""), description: "status"}},
    {tool: "bash", args: {command: ("echo escaped > " + $q + $outside + $q + ""), description: "outside"}},
    {tool: "bash", args: {command: ("echo worktree=/ >> " + $q + $meta + $q + ""), description: "task record"}},
    {tool: "bash", args: {command: ("echo exit 0 > " + $q + $hook + $q + ""), description: "hook"}},
    {tool: "bash", args: {command: ("echo redirected >> " + $q + $status + $q + " > " + $q + $outside_redirect + $q), description: "status redirect"}},
    {tool: "bash", args: {command: ("git diff --output=" + $q + $outside_diff + $q + " HEAD~1"), description: "diff output"}},
    {tool: "bash", args: {command: "curl -s -m 3 https://example.com/ >/dev/null && echo reached > net-reached.txt; echo ok > sailor-done.txt", description: "network and marker"}}
  ]' > "$case_dir/script.json"

  write_scripted_sailor "$case_dir/sailor.py"
  python3 "$case_dir/sailor.py" "$case_dir/port" "$case_dir/script.json" &
  SERVER_PID=$!
  for _ in $(seq 100); do
    [ -s "$case_dir/port" ] && break
    sleep 0.05
  done
  port=$(cat "$case_dir/port" 2>/dev/null)
  [ -n "$port" ] || guard_fail "the scripted sailor did not start"
  printf '{"sailors":{"tiller":{"endpoint":"http://127.0.0.1:%s/v1","status":"live","models":["scripted"]}}}\n' "$port" \
    > "$home/config/crew-dispatch.json"
  : > "$home/config/sailor-sandbox"

  # OpenCode keeps its own data under the throwaway home the spawn fixture uses,
  # except its cache, which stays the real one so nothing is downloaded.
  out=$(XDG_CACHE_HOME="$HOME/.cache" FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode local-only --yolo off \
      --harness opencode --model scripted --sailor tiller)
  status=$?
  [ "$status" = 0 ] || guard_fail "the sailor spawn failed: $out"
  assert_contains "$out" "sandbox=seatbelt" "the spawn must report the sandbox"

  real_cache="$HOME/.cache"
  (
    cd "$wt" || exit 1
    HOME="$home/user-home" XDG_CACHE_HOME="$real_cache" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
      exec script -q "$case_dir/tty.log" bash -c "$(cat "$launchlog")"
  ) </dev/null >/dev/null 2>&1 &
  TUI_PID=$!
  for _ in $(seq 240); do
    [ -e "$wt/sailor-done.txt" ] && break
    sleep 0.5
  done
  [ -e "$wt/sailor-done.txt" ] || guard_fail "the scripted steps never finished; see the pane log $(tail -c 400 "$case_dir/tty.log" 2>/dev/null | tr -cd '[:print:]\n')"

  assert_equals "# sailor" "$(cat "$wt/README.md")" "opencode $OPENCODE_VERSION: an edit inside the copy must succeed in the sandbox"
  assert_equals "sailor edit" "$(git -C "$wt" log -1 --format=%s)" "opencode $OPENCODE_VERSION: a commit must succeed in the sandbox"
  assert_equals "working [at=1]: sandboxed" "$(cat "$home/state/$id.status")" "opencode $OPENCODE_VERSION: the worker's status append must succeed in the sandbox"
  [ ! -e "$OUTSIDE/escaped.txt" ] || guard_fail "a write outside every allowed path must fail"
  [ ! -e "$OUTSIDE/redirected.txt" ] || guard_fail "a redirection appended to the status command must not write outside the copy"
  [ ! -e "$OUTSIDE/diff.txt" ] || guard_fail "git diff --output must not write outside the copy"
  ! grep -qx 'worktree=/' "$home/state/$id.meta" || guard_fail "the worker must not be able to rewrite its own task record"
  [ ! -e "$common/hooks/pre-commit" ] || guard_fail "the worker must not be able to plant a Git hook"
  [ ! -e "$wt/net-reached.txt" ] || guard_fail "a connection beyond the sailor's endpoint must fail"
  grep -q opencode-plugin "$home/state/$id.busy-state" 2>/dev/null \
    || guard_fail "firstmate's busy-state plugin must still record the worker's state from inside the sandbox"
  pass "opencode $OPENCODE_VERSION in a sandboxed sailor launch edits, commits, reports and records its busy state, but cannot write outside (by redirection or git diff --output included), rewrite its record, plant a hook, or reach the network"
}

test_sandboxed_sailor_launch_confines_the_real_opencode

echo "# all fm-sailor-sandbox-live-e2e tests passed"
