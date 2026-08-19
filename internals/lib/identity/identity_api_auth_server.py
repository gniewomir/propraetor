#!/usr/bin/env python3
"""Minimal example API that enforces Identity marker scope (ADR-0057 / #255)."""

from __future__ import annotations

import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from identity_api_auth import AuthorizationError, authorize_from_env


class _Handler(BaseHTTPRequestHandler):
    server_version = "propraetor-identity-api-auth/1"

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_GET(self) -> None:
        if self.path not in ("/", "/health"):
            self.send_error(404)
            return
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        try:
            authorize_from_env(self.headers.get("Authorization"))
        except AuthorizationError as exc:
            body = ("%s\n" % exc).encode("utf-8")
            self.send_response(401)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        body = b"authorized\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    host = os.environ.get("LISTEN_HOST", "0.0.0.0")
    port = int(os.environ.get("LISTEN_PORT", "8080"))
    httpd = ThreadingHTTPServer((host, port), _Handler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
