#!/usr/bin/env python3
"""Serve build/web with caching off. Usage: serve.py [port] (from build/web).

WHY: the backend URL is compiled INTO the bundle by `--dart-define`, so a
cached `main.dart.js` keeps calling whatever host it was built against. After a
rebuild the page reloads and still runs the old code, which POSTs at this
static server, gets a 501 HTML body, and reports "Unexpected response from
/api/v1/auth_token" - a stale file that reads as broken auth.
"""

import os
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class NoCache(SimpleHTTPRequestHandler):
    def send_head(self):
        # Strip the validators BEFORE the base class reads them: it answers a
        # conditional GET with 304 whatever response headers we add after, so
        # `no-store` alone would still hand back the stale bundle. `del` on an
        # absent key is a no-op here.
        del self.headers["If-Modified-Since"]
        del self.headers["If-None-Match"]
        return super().send_head()

    def translate_path(self, path):
        """SPA fallback: an app route must serve index.html, not 404.

        The app owns client-side routes like `/exam/<token>` - that is the
        candidate's invitation link. This server maps a URL straight onto a
        file, so it answered 404 and the app never loaded at all: a valid
        invitation looked like a dead link before a single line of Dart ran.
        Deep-linking is the whole delivery mechanism for a candidate, so this
        is not a nicety.

        Only requests for an actual FILE fall through to the base class. A path
        with no extension is an app route, so it gets the shell and Flutter's
        own router resolves it.
        """
        local = super().translate_path(path)
        if os.path.isdir(local) or os.path.exists(local):
            return local
        # No such file. If it looks like an asset, let the 404 happen - hiding
        # a missing main.dart.js behind the shell would be far more confusing.
        if os.path.splitext(local)[1]:
            return local
        return os.path.join(os.getcwd(), "index.html")

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, format, *args):  # noqa: A002 - base class name
        sys.stderr.write("  %s\n" % (format % args))  # no date noise


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8200
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", port), NoCache)
    except OSError as exc:
        # Say who to kill. A bare traceback here reads as a broken script when
        # the real cause is a server already up from an earlier run.
        sys.exit(f"port {port} is already in use ({exc.strerror}). "
                 f"Find it with `lsof -ti tcp:{port}` and kill it, "
                 f"or serve elsewhere with `make serve PORT=<n>`.")
    print("Serving HTTP on 127.0.0.1 port %d (no-store) ..." % port, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
