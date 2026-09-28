#!/usr/bin/env python3
"""Forwards GETs to the real Keycloak and counts them, so a test can tell how often a relying party
fetches the realm's JWKS. GET /_count returns the running total.  Usage: counting_proxy.py [port]"""
import sys, threading, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9830
UPSTREAM = "http://localhost:8180"
hits = {"n": 0}
lock = threading.Lock()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/_count":
            body = str(hits["n"]).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        with lock:
            hits["n"] += 1
        with urllib.request.urlopen(UPSTREAM + self.path) as r:
            body = r.read()
            self.send_response(r.status)
            self.send_header("Content-Type", r.headers.get("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("localhost", PORT), H).serve_forever()
