# Stand-in upstream for the proxy tests: answers 200 to every request and prints one line per request, so a test can tell
# whether nginx forwarded it and with which credentials.
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Echo(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)

    def answer(self):
        self.read_body()
        print(f"REQ {self.command} {self.path} authorization={self.headers.get('Authorization', '')}", flush=True)
        body = b"echo\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_DELETE = answer

    def log_message(self, *args):
        pass


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
ThreadingHTTPServer(("0.0.0.0", port), Echo).serve_forever()
