#!/usr/bin/env python3
"""Dev server for the Flutter web build: static files plus an /api proxy.

WHY THIS EXISTS

`python -m http.server` serves files and nothing else. It has no POST handler,
so every API call the app makes comes back **501 Not Implemented** - which is
exactly what the login screen reports when it says

    Request to /api/workflow/auth/guest failed (HTTP 501).

The app deliberately calls its own origin (`API_BASE_URL` empty, the default
its `.env.example` documents), because a cross-origin call would need
credentialed CORS on every route. That design is right; it just needs a server
that forwards `/api/*` to Odoo instead of looking for a file called `api`.

So: same origin, no CORS, cookies and bearer tokens both work, and the browser
sees one host.

USAGE

    python3 tool/dev_server.py                 # :8100 -> Odoo on :7070
    python3 tool/dev_server.py 8200 7071       # custom ports
"""
from __future__ import annotations

import http.server
import socketserver
import sys
import urllib.error
import urllib.request
from pathlib import Path

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8100
ODOO_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 7070
ODOO = f"http://127.0.0.1:{ODOO_PORT}"
ROOT = Path(__file__).resolve().parent.parent / "build" / "web"

# Everything Odoo owns. Anything else is a file, or the SPA's index.html.
PROXY_PREFIXES = ("/api/", "/web/", "/odoo/", "/jsonrpc", "/longpolling/")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(ROOT), **kw)

    # ── Caching ────────────────────────────────────────────────────────────

    def end_headers(self):  # noqa: D102
        # Never let a dev browser cache the app.
        #
        # `flutter build web` emits a SERVICE WORKER that caches main.dart.js,
        # and it keeps replaying the old bundle after a rebuild - so a fix is
        # on disk, served correctly, and still invisible on screen. The failure
        # is silent and looks exactly like "the change did not work", which
        # costs a debugging session every time.
        #
        # Only for static assets: a proxied API response sets its own headers.
        if not self._is_proxied():
            self.send_header("Cache-Control",
                             "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
        super().end_headers()

    # ── Routing ────────────────────────────────────────────────────────────

    def _is_proxied(self) -> bool:
        return self.path.startswith(PROXY_PREFIXES)

    def do_GET(self):  # noqa: N802
        if self._is_proxied():
            return self._proxy("GET")
        # Refuse to serve the service worker at all.
        #
        # Returning 404 makes the browser UNREGISTER an already-installed one,
        # which is what clears a stale install without the user having to open
        # devtools. Production still ships it; this only affects dev.
        #
        # Written by hand rather than via `send_error`: that method is
        # overridden below to serve index.html on any 404 so deep links work,
        # which turned this refusal into a 200 and left the worker installed.
        if self.path.split("?")[0].endswith("flutter_service_worker.js"):
            body = b"// disabled in dev\n"
            self.send_response(404)
            self.send_header("Content-Type", "application/javascript")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return None
        return super().do_GET()

    def do_POST(self):  # noqa: N802
        # The whole point: http.server answers 501 here by default.
        if self._is_proxied():
            return self._proxy("POST")
        self.send_error(405, "Only /api routes accept POST")

    def do_PUT(self):  # noqa: N802
        return self._proxy("PUT") if self._is_proxied() else self.send_error(405)

    def do_DELETE(self):  # noqa: N802
        return self._proxy("DELETE") if self._is_proxied() else self.send_error(405)

    def do_OPTIONS(self):  # noqa: N802
        # Same origin means the browser never preflights, but a client library
        # may still ask. Answer plainly rather than 501.
        if self._is_proxied():
            return self._proxy("OPTIONS")
        self.send_response(204)
        self.send_header("Allow", "GET, POST, OPTIONS")
        self.end_headers()

    # ── Proxy ──────────────────────────────────────────────────────────────

    def _proxy(self, method: str) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None

        req = urllib.request.Request(ODOO + self.path, data=body, method=method)
        for k, v in self.headers.items():
            # Host must name the UPSTREAM, and hop-by-hop headers must not be
            # forwarded: passing the client's Content-Length through after the
            # body is re-read is how a proxy hangs.
            if k.lower() in ("host", "content-length", "connection",
                             "accept-encoding"):
                continue
            req.add_header(k, v)

        try:
            with urllib.request.urlopen(req, timeout=120) as res:
                self._relay(res.status, res.headers, res.read())
        except urllib.error.HTTPError as e:
            # A 4xx/5xx from Odoo is a real answer - the API uses status codes
            # to mean things - so relay it rather than turning it into a 502.
            self._relay(e.code, e.headers, e.read())
        except Exception as e:  # noqa: BLE001
            self.send_error(502, f"Cannot reach Odoo at {ODOO}: {e}")

    def _relay(self, status: int, headers, payload: bytes) -> None:
        self.send_response(status)
        for k, v in headers.items():
            if k.lower() in ("transfer-encoding", "content-length",
                             "connection"):
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    # ── SPA fallback ───────────────────────────────────────────────────────

    def send_error(self, code, message=None, explain=None):  # noqa: D102
        # A deep link like /assessments is a route inside the app, not a file.
        # Hand back index.html and let the client router resolve it.
        if code == 404 and not self._is_proxied():
            self.path = "/index.html"
            return super().do_GET()
        return super().send_error(code, message, explain)

    def log_message(self, format, *args):  # noqa: A002, D102
        sys.stderr.write(f"{self.address_string()} {format % args}\n")


class Server(socketserver.ThreadingTCPServer):
    # Threaded: a single-threaded proxy deadlocks the moment the page loads
    # several assets while one API call is still in flight.
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    if not (ROOT / "index.html").exists():
        sys.exit(f"No build at {ROOT}. Run: flutter build web")
    print(f"serving {ROOT}")
    print(f"  http://localhost:{PORT}      -> the app")
    print(f"  /api, /web, /odoo            -> {ODOO}")
    with Server(("", PORT), Handler) as httpd:
        httpd.serve_forever()
