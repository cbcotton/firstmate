# Stub mlx-serve server: /health answers the code in <root>/health.code, /v1/models the code in <root>/models.code.
import http.server, os, sys
root = sys.argv[1]
def code(n):
    try: return int(open(os.path.join(root, n)).read().strip())
    except Exception: return 200
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        open(os.path.join(root, "requests.log"), "a").write("GET " + self.path + "\n")
        if self.path == "/health": c = code("health.code"); b = b'{"status":"ok"}' if c == 200 else b'{"status":"loading"}'
        elif self.path == "/v1/models": c = code("models.code"); b = b'{"data":[{"id":"qwen-coder","loaded":true}]}' if c == 200 else b'{"error":"x"}'
        else: c, b = 404, b'{}'
        self.send_response(c); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(root, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
