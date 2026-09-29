#!/usr/bin/env python3
"""A minimal, dependency-free webhook receiver for the I12 push-notification
interop scenarios. Run as its own process (not in the same Ballerina `bal
run` as the driver): a module-level Ballerina http:Listener only starts
*after* `main()` returns (confirmed with a minimal repro), so an in-process
receiver is never actually reachable during a `main()`-driven test.

Writes each received request body, as JSON, to OUT_FILE, one per call to
main() below overwriting the last -- a driver polls that file for a change.
"""

import http.server
import json
import sys


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 19870
    out_file = sys.argv[2] if len(sys.argv) > 2 else "/tmp/push_receiver_last.json"

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            with open(out_file, "wb") as f:
                f.write(body)
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, format: str, *args) -> None:  # noqa: A002
            pass  # quiet

    http.server.HTTPServer(("localhost", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
