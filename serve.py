"""Static server for the vendor portal.

Two differences from `python -m http.server`, both of which bit us:

  * It sends no-cache headers. Plain http.server sends Last-Modified, so
    browsers keep serving an old index.html after an edit and you see stale
    code with no obvious clue.
  * It binds 127.0.0.1, not 0.0.0.0. http.server listens on every network
    interface by default, which quietly puts this folder on your LAN.

It serves the folder this file lives in, so it works no matter which
directory you run it from.

    python serve.py            # port 8030
    python serve.py 8040       # different port
"""

import os
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))


class NoCacheHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt, *args):
        # Only log failures, so a stray 404 is not buried in 200s.
        if args and str(args[1]).startswith(("4", "5")):
            super().log_message(fmt, *args)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8030
    handler = partial(NoCacheHandler, directory=HERE)
    try:
        server = ThreadingHTTPServer(("127.0.0.1", port), handler)
    except OSError as e:
        print(f"Could not bind port {port}: {e}")
        print(f"Something else is probably using it. Try: python serve.py {port + 1}")
        sys.exit(1)

    print(f"Serving {HERE}")
    print()
    print(f"  Live portal   http://localhost:{port}/live/index.html")
    print(f"  Mockup demo   http://localhost:{port}/demo.html")
    print()
    print("Local only — not reachable from other machines. Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
