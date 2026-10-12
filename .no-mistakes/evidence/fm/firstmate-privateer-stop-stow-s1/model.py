import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT_FILE, LOG = sys.argv[1], sys.argv[2]

def chunk(delta, finish=None):
    return "data: " + json.dumps({"id": "c", "object": "chat.completion.chunk", "created": int(time.time()),
        "model": "scripted", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n"

def log(rec):
    rec["t"] = round(time.time(), 2)
    with open(LOG, "a") as f:
        f.write(json.dumps(rec) + "\n")

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def send(self, code, body, ctype):
        data = body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.path.startswith("/v1/models"):
            return self.send(200, json.dumps({"object": "list", "data": [{"id": "scripted", "object": "model"}]}), "application/json")
        self.send(404, "no\n", "text/plain")
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try: req = json.loads(raw or b"{}")
        except ValueError: req = {}
        msgs = req.get("messages") or []
        last = msgs[-1] if msgs else {}
        users = [m for m in msgs if m.get("role") == "user"]
        lastuser = json.dumps([u.get("content") for u in users])
        tools = [t.get("function", {}).get("name") for t in req.get("tools") or []]
        stow = "shown for the captain" in lastuser and "/stow" in lastuser
        if stow and last.get("role") != "tool" and "bash" in tools:
            i = lastuser.find("shown for the captain"); log({"kind": "stow-turn-request", "user_excerpt": lastuser[max(0,i-60):i+60]})
            time.sleep(4)
            args = json.dumps({"command": 'sleep 6; echo "- live stow proof $(date +%s)" >> "$FM_HOME/data/learnings.md"; date +%s > "$FM_HOME/data/stow-tool-done"', "description": "Record a learning"})
            body = chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": "call_stow", "type": "function",
                "function": {"name": "bash", "arguments": args}}]}) + chunk({}, "tool_calls") + "data: [DONE]\n\n"
            log({"kind": "stow-tool-call-sent"})
            return self.send(200, body, "text/event-stream")
        if stow and last.get("role") == "tool":
            time.sleep(3)
            log({"kind": "stow-final-reply"})
            body = chunk({"role": "assistant", "content": "Captain, stowed: 0 rows filed, 0 corrected, 1 learning."}) + chunk({}, "stop") + "data: [DONE]\n\n"
            return self.send(200, body, "text/event-stream")
        if "SLOWTURN" in lastuser and "bash" in tools:
            log({"kind": "slow-turn"}); time.sleep(25)
        log({"kind": "plain", "tools": bool(tools)})
        body = chunk({"role": "assistant", "content": "Aye. Standing by."}) + chunk({}, "stop") + "data: [DONE]\n\n"
        self.send(200, body, "text/event-stream")

srv = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[3]) if len(sys.argv) > 3 else 0), H)
open(PORT_FILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
