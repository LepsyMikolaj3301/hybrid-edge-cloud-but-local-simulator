# Tiny metrics source: counter increments 100/s (derived from wall clock) on /metrics.
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
T0 = time.time()
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("# TYPE bf_counter_total counter\nbf_counter_total %d\n" % int((time.time()-T0)*100)).encode()
        self.send_response(200); self.send_header("Content-Type","text/plain; version=0.0.4")
        self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*a): pass
HTTPServer(("0.0.0.0",8000),H).serve_forever()
