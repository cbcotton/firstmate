#!/usr/bin/env bash
# Live scenario: real sailor spawn + real OpenCode + the captain's real AXI global plugins (copied)
# against a loopback server that enforces the Qwen/mlx-lm one-leading-system-message rule.
set -u
ROOT=/Users/cotton/.no-mistakes/worktrees/e74e4e411ceb/01M4R10GJCQZSQBSJBT10B9BP6
cd "$ROOT"
. tests/fixtures.sh
T=$(mktemp -d /tmp/fmfold-run.XXXXXX); T=$(cd "$T" && pwd -P)
trap 'kill $SP 2>/dev/null; chmod -R u+w "$T"; rm -rf "$T"' EXIT
cat > "$T/strict.py" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT_FILE, OUT = sys.argv[1], sys.argv[2]
def chunk(d, f=None):
    return "data: "+json.dumps({"id":"c","object":"chat.completion.chunk","created":int(time.time()),"model":"scripted","choices":[{"index":0,"delta":d,"finish_reason":f}]})+"\n\n"
class H(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def log_message(self,*a): pass
    def reply(self, code, body, ct):
        b=body.encode(); self.send_response(code); self.send_header("Content-Type",ct); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self): self.reply(200, json.dumps({"object":"list","data":[{"id":"scripted","object":"model"}]}),"application/json")
    def do_POST(self):
        req=json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        msgs=req.get("messages",[]); roles=[m.get("role") for m in msgs]
        sysn=roles.count("system")
        # Qwen chat template (mlx-lm): at most one system message, and only at index 0.
        bad = any(r=="system" for r in roles[1:])
        systext="\n".join(m.get("content") for m in msgs if m.get("role")=="system" and isinstance(m.get("content"),str))
        hdrs=[l for l in systext.splitlines() if l.startswith("## AXI ambient context") or l.startswith("## LATE")]
        with open(OUT,"a") as f: f.write(json.dumps({"roles":roles,"system_count":sysn,"rejected":bad,"system_headers":hdrs})+"\n")
        if bad:
            self.reply(404, json.dumps({"error":{"message":"System message must be at the beginning.","type":"not_found_error"}}),"application/json"); return
        if req.get("stream"):
            self.reply(200, chunk({"role":"assistant","content":"ok-from-strict-sailor"})+chunk({},"stop")+"data: [DONE]\n\n","text/event-stream")
        else:
            self.reply(200, json.dumps({"id":"c","object":"chat.completion","created":int(time.time()),"model":"scripted","choices":[{"index":0,"message":{"role":"assistant","content":"ok-from-strict-sailor"},"finish_reason":"stop"}]}),"application/json")
srv=ThreadingHTTPServer(("127.0.0.1",0),H); open(PORT_FILE,"w").write(str(srv.server_address[1])); srv.serve_forever()
PY
python3 "$T/strict.py" "$T/port" "$T/req.log" & SP=$!
for _ in $(seq 100); do [ -s "$T/port" ] && break; sleep 0.05; done
PORT=$(cat "$T/port")
XDG="$T/xdg"; mkdir -p "$XDG/config/opencode/plugins"
cp ~/.config/opencode/plugins/axi-*.js "$XDG/config/opencode/plugins/"
echo "== global plugins (copies of captain's real AXI plugins):"; ls "$XDG/config/opencode/plugins"
home="$T/home"; proj="$T/project"; wt="$T/wt"; id=fold-scn-s1
fakebin=$(fm_test_make_spawn_fakebin "$T/fake")
fm_test_spawn_home "$home" opencode
fm_git_worktree "$proj" "$wt" "task-$id"
fm_test_spawn_brief "$home" "$id"
wt=$(cd "$wt" && pwd -P)
control="$T/control"; mkdir -p "$control"; git -C "$control" init -q
printf '{"sailors":{"tiller":{"endpoint":"http://127.0.0.1:%s/v1","status":"live","models":["scripted"]}}}\n' "$PORT" > "$home/config/crew-dispatch.json"
run_oc() { # dir label
  local p; p=$(jq -cn --arg url "http://127.0.0.1:$PORT/v1" '{provider:{tiller:{npm:"@ai-sdk/openai-compatible",name:"tiller",options:{baseURL:$url},models:{scripted:{name:"scripted"}}}}}')
  : > "$T/req.log"
  (cd "$1" && XDG_CONFIG_HOME="$XDG/config" XDG_DATA_HOME="$XDG/data" XDG_STATE_HOME="$XDG/state" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_CONFIG_CONTENT="$p" perl -e 'alarm 240; exec @ARGV' opencode run --model tiller/scripted "Say hi.") </dev/null >"$T/$2.out" 2>&1
  echo "   opencode exit=$?"
  echo "   requests seen by strict sailor:"; sed 's/^/     /' "$T/req.log"
  echo "   opencode output (tail):"; tail -c 300 "$T/$2.out" | tr -cd '[:print:]\n' | sed 's/^/     /'; echo
}
echo; echo "== Scenario 1 (control, no fold plugin, real AXI plugins): reproduce the Bonsai fault"
run_oc "$control" control
echo "== Scenario 2: real fm-spawn sailor launch (--harness opencode --sailor tiller)"
out=$(FM_FAKE_LAUNCH_LOG="$T/launch.log" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode local-only --yolo off --harness opencode --model scripted --sailor tiller); echo "   spawn exit=$?"
ls -1 "$wt/.opencode/plugins" | sed 's/^/   plugin: /'
echo "   git status --porcelain .opencode: [$(git -C "$wt" status --porcelain -- .opencode)]"
echo "== Scenario 3: OpenCode in the sailor worktree with the real AXI plugins"
run_oc "$wt" sailor
echo "== Scenario 4 (adversarial): a project plugin loaded AFTER the fold unshifts a system entry"
cat > "$wt/.opencode/plugins/zz-late-system.js" <<'JS'
export const ZzLate = async () => ({
  "experimental.chat.system.transform": async (_i, output) => { output.system.unshift("## LATE unshift"); output.system.push("## LATE push"); },
});
JS
run_oc "$wt" late
rm -f "$wt/.opencode/plugins/zz-late-system.js"
echo "== Scenario 5: relaunch the same worktree as a non-sailor OpenCode launch"
fm_test_spawn_brief "$home" fold-scn-s2
out2=$(FM_FAKE_LAUNCH_LOG="$T/launch2.log" fm_test_run_spawn "$home" "$wt" "$fakebin" fold-scn-s2 "$proj" --mode local-only --yolo off --harness opencode --model anthropic/claude-sonnet-4-5); echo "   spawn exit=$? $(echo "$out2" | tail -2)"
ls -1 "$wt/.opencode/plugins" | sed 's/^/   plugin: /'
[ -e "$wt/.opencode/plugins/fm-sailor-system-fold.js" ] && echo "   FOLD PLUGIN STILL PRESENT" || echo "   fold plugin removed: yes"
