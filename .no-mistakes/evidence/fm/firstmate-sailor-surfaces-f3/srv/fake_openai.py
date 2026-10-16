import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.endswith('/models'):
            b=json.dumps({"data":[{"id":"qwen-coder"},{"id":"qwen-big"},{"id":"qwen-small"}]}).encode()
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
http.server.HTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
