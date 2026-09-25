#!/bin/sh
# Serve the app on http://localhost:8123 (ES modules need http://, not file://).
# Every response carries Cache-Control: no-store, so an edited stylesheet or
# module shows on the next reload — without it the browser keeps serving its
# heuristically cached copy of ui-kit/*.css and src/*.js for hours.
PORT="${1:-8123}"
cd "$(dirname "$0")" || exit 1
# A warning, not a refusal: serving a slightly stale kit is a normal thing
# to want to do, and the check says nothing at all when the kits are not
# checked out beside this repo.
./scripts/vendor-kits.sh --check >/dev/null 2>&1 ||
  echo "warning: a vendored kit is out of date — run scripts/vendor-kits.sh" >&2
echo "IDEF0 Modeler → http://localhost:$PORT"
exec python3 - "$PORT" <<'PY'
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

class NoStore(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), NoStore).serve_forever()
PY
