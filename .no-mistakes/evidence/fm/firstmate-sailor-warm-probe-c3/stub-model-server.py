# Stand-in OpenAI-compatible model server for live validation of fm-sailor.sh check.
# Modes by port arg: "bonsai" mimics a Qwen/Bonsai chat template that only allows one
# leading system message (404 "System message must be at the beginning." otherwise);
# "broken" answers 500 to every completion; "lazy" lists qwen-big with loaded:false and
# takes DELAY seconds to answer the first completion (load on demand).
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
mode, port, log = sys.argv[1], int(sys.argv[2]), sys.argv[3]
delay = float(sys.argv[4]) if len(sys.argv) > 4 else 0
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        with open(log, "a") as f: f.write(f"[{mode}] GET {self.path}\n")
        if self.path.endswith("/models"):
            data = [{"id": "qwen-coder", "loaded": True}]
            if mode == "lazy": data.append({"id": "qwen-big", "loaded": False})
            return self.send(200, {"object": "list", "data": data})
        self.send(404, {"error": "nope"})
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        roles = [m["role"] for m in req["messages"]]
        with open(log, "a") as f: f.write(f"[{mode}] POST {self.path} {json.dumps(req)}\n")
        if mode == "broken":
            return self.send(500, {"error": {"message": "out of memory loading model"}})
        if mode == "bonsai" and roles.count("system") > 1:
            return self.send(404, {"error": {"message": "System message must be at the beginning."}})
        if mode == "lazy" and req["model"] == "qwen-big": time.sleep(delay)
        self.send(200, {"choices": [{"index": 0, "message": {"role": "assistant", "content": "OK"}}]})
ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
