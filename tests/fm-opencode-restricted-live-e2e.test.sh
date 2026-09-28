#!/usr/bin/env bash
# tests/fm-opencode-restricted-live-e2e.test.sh - the real OpenCode honors the
# restricted permission profile bin/fm-opencode-permissions.sh composes.
#
# Whether a tool call runs is decided inside OpenCode, so this is a
# harness-dependent check (firstmate-coding-guidelines, "Harness-dependent
# checks"): it drives the installed OpenCode for real. A scripted
# OpenAI-compatible model server, started here on a loopback port, answers
# every model request with the next tool call from a fixed script, so the run
# is deterministic and spends no model tokens; the guard therefore runs by
# default wherever opencode is installed. Each step's verdict is read from the
# filesystem it would have changed, never from OpenCode's rendered output.
# `opencode run` reads standard input when it is not a terminal and waits for
# it to close, so the run gets /dev/null rather than whatever the caller holds.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_OPENCODE_RESTRICTED_LIVE opencode python3 jq git

TMP_ROOT=$(fm_test_tmproot fm-opencode-restricted-live)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
OPENCODE_VERSION=$(opencode --version 2>/dev/null | head -1)
SERVER_PID=

cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

guard_fail() {
  fail "opencode $OPENCODE_VERSION: $*"
}

write_scripted_model() {  # <path>
  cat > "$1" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT_FILE, SCRIPT, LOG = sys.argv[1], sys.argv[2], sys.argv[3]
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
        msgs = req.get("messages", [])
        done = sum(1 for m in msgs if m.get("role") == "tool")
        last = next((json.dumps(m.get("content")) for m in reversed(msgs) if m.get("role") == "tool"), "")
        with open(LOG, "a") as f:
            f.write(json.dumps({"results": done, "last": last}) + "\n")
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

test_real_opencode_honors_the_restricted_profile() {
  local case_dir home wt remote status_q inbox_q ledger_q config_q flag_q port perm config rc hosts_result status_result
  case_dir="$TMP_ROOT/restricted"
  home="$case_dir/home"
  wt="$case_dir/wt"
  remote="$case_dir/remote.git"
  mkdir -p "$home/config" "$home/state/t1.inbox/handled" "$home/data/t1" "$wt" "$remote" "$case_dir/xdg"
  printf 'restricted\n' > "$home/config/opencode-permission-profile"
  : > "$home/state/t1.status"
  printf 'steer\n' > "$home/state/t1.inbox/001.msg"
  git -C "$remote" init -q --bare
  git -C "$wt" init -q -b main
  git -C "$wt" config user.email sailor@example.invalid
  git -C "$wt" config user.name sailor
  printf 'foo\n' > "$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" commit -q -m init
  git -C "$wt" remote add origin "$remote"
  git -C "$wt" push -q origin main

  # The worker protocol commands exactly as bin/fm-brief.sh spells them.
  status_q="'$home/state/t1.status'"
  inbox_q="'$home/state/t1.inbox'"
  ledger_q="'$ROOT/bin/fm-fleet-ledger.sh'"
  config_q="'$home/config'"
  flag_q="'$home/config/fleet-ledger'"
  jq -n --arg wt "$wt" --arg status "$status_q" --arg inbox "$inbox_q" \
    --arg ledger "$ledger_q" --arg config "$config_q" --arg flag "$flag_q" \
    --arg outside_diff "'$case_dir/diff-out.txt'" '[
    {tool: "edit", args: {filePath: ($wt + "/a.txt"), oldString: "foo", newString: "bar"}},
    {tool: "bash", args: {command: "git commit -am \"say bar\"", description: "commit"}},
    {tool: "bash", args: {command: "git push origin main", description: "push"}},
    {tool: "bash", args: {command: "git status && rm -f a.txt", description: "compound"}},
    {tool: "bash", args: {command: ("echo \"working [at=1]: probe\" >> " + $status + " && { [ ! -e " + $flag + " ] || " + $ledger + " appended " + $config + " " + $status + " >/dev/null 2>&1 || true; }"), description: "status"}},
    {tool: "bash", args: {command: ("mv " + $inbox + "/001.msg " + $inbox + "/handled/"), description: "acknowledge"}},
    {tool: "read", args: {filePath: "/etc/hosts"}},
    {tool: "bash", args: {command: ("git diff --output=" + $outside_diff + " HEAD~1"), description: "diff output"}},
    {tool: "bash", args: {command: "git commit --allow-empty -m \"map old -> new\"", description: "arrow commit"}},
    {tool: "bash", args: {command: "git status", description: "bare status"}}
  ]' > "$case_dir/script.json"

  write_scripted_model "$case_dir/model.py"
  python3 "$case_dir/model.py" "$case_dir/port" "$case_dir/script.json" "$case_dir/model.log" &
  SERVER_PID=$!
  for _ in $(seq 100); do
    [ -s "$case_dir/port" ] && break
    sleep 0.05
  done
  port=$(cat "$case_dir/port" 2>/dev/null)
  [ -n "$port" ] || guard_fail "the scripted model server did not start"

  perm=$(FM_HOME="$home" "$ROOT/bin/fm-opencode-permissions.sh" compose t1) || guard_fail "compose failed"
  config=$(jq -cn --argjson perm "$perm" --arg url "http://127.0.0.1:$port/v1" '{autoupdate: false, share: "disabled", permission: $perm,
    provider: {sailor: {npm: "@ai-sdk/openai-compatible", name: "Scripted", options: {baseURL: $url}, models: {scripted: {name: "scripted"}}}}}')
  (
    cd "$wt" || exit 1
    XDG_CONFIG_HOME="$case_dir/xdg" OPENCODE_DB="$case_dir/opencode.db" \
      OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_CONFIG_CONTENT="$config" \
      perl -e 'alarm shift; exec @ARGV' 120 opencode run --model sailor/scripted go
  ) < /dev/null > "$case_dir/run.out" 2> "$case_dir/run.err"
  rc=$?
  [ "$rc" = 0 ] || guard_fail "opencode run exited $rc: $(tail -c 600 "$case_dir/run.err")"

  # Allowed: an edit and a local commit inside the copy.
  assert_equals bar "$(cat "$wt/a.txt" 2>/dev/null)" "opencode $OPENCODE_VERSION: an edit inside the copy must be allowed"
  assert_equals "say bar" "$(git -C "$wt" log -1 --skip=1 --format=%s)" "opencode $OPENCODE_VERSION: a local commit must be allowed"
  # Denied: the push, and the second half of a compound whose first half is allowed.
  assert_equals "$(git -C "$remote" rev-list --count main)" 1 "opencode $OPENCODE_VERSION: the push must be denied"
  [ -e "$wt/a.txt" ] || guard_fail "the rm inside an allowed compound command must be denied"
  # Allowed: the worker protocol against this task's own status file and inbox.
  assert_equals "working [at=1]: probe" "$(cat "$home/state/t1.status")" "opencode $OPENCODE_VERSION: the brief's status command must be allowed"
  [ -e "$home/state/t1.inbox/handled/001.msg" ] || guard_fail "the inbox acknowledgement must be allowed"
  # Denied: reading outside the copy. The verdict is the tool result OpenCode
  # sent back to the model for that step, which must exist (so the step ran)
  # and must not carry the file's contents.
  hosts_result=$(jq -r 'select(.results == 7) | .last' "$case_dir/model.log" | tail -1)
  [ -n "$hosts_result" ] || guard_fail "the /etc/hosts read step never returned a result, so its denial proves nothing"
  case "$hosts_result" in
    *localhost*) guard_fail "reading outside the copy must be denied, but the model received /etc/hosts" ;;
  esac
  # Denied: a Git command writing its output with --output.
  [ ! -e "$case_dir/diff-out.txt" ] || guard_fail "git diff --output must be denied"
  # Allowed: a commit message carrying '>' and a bare git status.
  assert_equals "map old -> new" "$(git -C "$wt" log -1 --format=%s)" "opencode $OPENCODE_VERSION: a commit message containing '>' must be allowed"
  status_result=$(jq -r 'select(.results == 10) | .last' "$case_dir/model.log" | tail -1)
  [ -n "$status_result" ] || guard_fail "the bare git status step never returned a result"
  case "$status_result" in
    *"prevents you from using this specific tool call"*) guard_fail "a bare git status must be allowed, but was denied" ;;
  esac
  pass "opencode $OPENCODE_VERSION honors the restricted profile: edits, commits, a bare git status and the worker protocol run; a push, a compound's denied half, an outside read, and git diff --output do not"
}

test_real_opencode_honors_the_restricted_profile

echo "# all fm-opencode-restricted-live-e2e tests passed"
