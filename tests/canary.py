#!/usr/bin/env python3
"""Canary service. Every request is logged with its Host header and path,
then answered 500 so callers fail fast rather than hang."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
LOG = os.environ.get('CANARY_LOG', '/tmp/canary.log')
PORT = int(os.environ.get('CANARY_PORT', '8898'))

class H(BaseHTTPRequestHandler):
    def _log(self):
        with open(LOG, 'a') as f:
            f.write(f"{self.command} {self.headers.get('Host','?')}{self.path}\n")
        self.send_response(500); self.send_header('Content-Length','2'); self.end_headers()
        self.wfile.write(b'{}')
    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _log
    def log_message(self, *a): pass

ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
