#!/usr/bin/env python3
"""Serve the IDEF0 web app and capture the golden fixtures it computes.

    python3 macos/scripts/fixture_server.py        # then open http://localhost:8124/macos/scripts/goldens.html
    macos/scripts/regen-goldens.sh                 # or the same, headless, in one step

GET serves the repository root, so the page can import the web app's own
modules. POST /__fixture/<name> writes the request body into OUT (the Swift
test bundle's Fixtures directory by default). Nothing else is writable.

F86: regen-goldens.sh sets OUT to a fresh temp directory so a run that fails
partway through never overwrites the previously committed fixtures — it stages
into OUT, diffs, and only then copies over Fixtures. The manual workflow above
(serving by hand and opening goldens.html in a real browser) is unaffected: OUT
still defaults to Fixtures itself.
"""
import functools
import http.server
import os
import re
import socketserver

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_OUT = os.path.join(ROOT, "macos", "Tests", "IDEF0CoreTests", "Fixtures")
OUT = os.environ.get("OUT", DEFAULT_OUT)
NAME = re.compile(r"^[a-z0-9][a-z0-9._-]{0,80}$")
PORT = int(os.environ.get("PORT", "8124"))


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path in ("/__done/ok", "/__done/error"):
            # The page reports completion so a headless run knows when to stop.
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            status = self.path.rsplit("/", 1)[1]
            print(f"GOLDENS-DONE {status} {body.decode('utf-8', 'replace')}", flush=True)
            self.send_response(200)
            self.end_headers()
            return
        prefix = "/__fixture/"
        name = self.path[len(prefix):] if self.path.startswith(prefix) else ""
        if not NAME.match(name):
            self.send_response(400)
            self.end_headers()
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok %d" % len(body))

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


os.makedirs(OUT, exist_ok=True)
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), functools.partial(Handler, directory=ROOT)) as httpd:
    print(f"Serving {ROOT} on http://localhost:{PORT} — open /macos/scripts/goldens.html", flush=True)
    httpd.serve_forever()
