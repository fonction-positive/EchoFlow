"""Loopback-only fixture server for ./test.sh --download-checks URL."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import time


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/shutdown":
            self.send_response(200)
            self.end_headers()
            threading.Thread(target=self.server.shutdown).start()
            return
        data = b"E" * 262144
        self.send_response(503 if self.path == "/error" else 200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            for offset in range(0, len(data), 8192):
                self.wfile.write(data[offset:offset + 8192])
                self.wfile.flush()
                if self.path == "/slow":
                    time.sleep(0.1)
        except (BrokenPipeError, ConnectionResetError):
            pass


with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    print(f"http://127.0.0.1:{server.server_port}", flush=True)
    server.serve_forever()
