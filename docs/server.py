#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Serve the WorkSpaces static docs site from the repository root.

Usage:
    uv run --script docs/server.py

Then open:
    http://127.0.0.1:8088/docs/
"""

from __future__ import annotations

import argparse
import functools
import http.server
import socketserver
from pathlib import Path
from urllib.parse import urlsplit


SOURCE_OVERRIDES = {
    "/docs/README.md": "/README.md",
    "/docs/CONTEXT.md": "/CONTEXT.md",
    "/docs/docs-site.md": "/docs/README.md",
}


class QuietHTTPRequestHandler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".md": "text/markdown; charset=utf-8",
        ".svg": "image/svg+xml",
        ".js": "text/javascript; charset=utf-8",
        ".css": "text/css; charset=utf-8",
    }

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def redirect_docs_root(self) -> bool:
        path = urlsplit(self.path).path
        if path in {"", "/"}:
            self.send_response(302)
            self.send_header("Location", "/docs/")
            self.end_headers()
            return True
        if path == "/favicon.ico":
            self.send_response(302)
            self.send_header("Location", "/docs/assets/icon-concepts/favicon.ico")
            self.end_headers()
            return True
        return False

    def translate_path(self, path: str) -> str:
        parsed = urlsplit(path)
        override = SOURCE_OVERRIDES.get(parsed.path)
        if override:
            return super().translate_path(override)
        return super().translate_path(path)

    def doc_source_exists(self, path: str) -> bool:
        doc_path = f"{path.rstrip('/')}.md"
        override = SOURCE_OVERRIDES.get(doc_path)
        if override:
            return Path(self.directory, override.lstrip("/")).is_file()
        return Path(self.directory, doc_path.lstrip("/")).is_file()

    def render_extensionless_doc(self) -> bool:
        path = urlsplit(self.path).path
        if not path.startswith("/docs/") or path in {"/docs/", "/docs/index"}:
            return False
        if Path(path).suffix or not self.doc_source_exists(path):
            return False
        self.path = "/docs/reader.html"
        return True

    def do_GET(self) -> None:
        if self.redirect_docs_root():
            return
        self.render_extensionless_doc()
        super().do_GET()

    def do_HEAD(self) -> None:
        if self.redirect_docs_root():
            return
        self.render_extensionless_doc()
        super().do_HEAD()


class ReusableTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Serve the WorkSpaces docs site and Markdown sources."
    )
    parser.add_argument("--host", default="127.0.0.1", help="Host interface to bind.")
    parser.add_argument("--port", type=int, default=8088, help="Port to bind.")
    parser.add_argument(
        "--check",
        action="store_true",
        help="Print the resolved repository root and exit without serving.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    docs_root = Path(__file__).resolve().parent
    repo_root = docs_root.parent

    if args.check:
        print(repo_root)
        return

    handler = functools.partial(QuietHTTPRequestHandler, directory=str(repo_root))
    with ReusableTCPServer((args.host, args.port), handler) as httpd:
        url = f"http://{args.host}:{args.port}/docs/"
        print(f"Serving WorkSpaces repository docs from {repo_root}")
        print(f"Open {url}")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
