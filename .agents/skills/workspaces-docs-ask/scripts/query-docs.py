#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Ask the local WorkSpaces docs server a cited question."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


DEFAULT_PORTS = [8098, 8090, 8088, 3100, 3202, 3211]


class QueryFailure(RuntimeError):
    pass


def request_json(base_url: str, path: str, body: dict | None = None) -> dict:
    data = None
    headers = {}
    method = "GET"
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
        method = "POST"
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}{path}", data=data, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        try:
            payload = json.loads(detail)
            message = payload.get("detail") or payload.get("error") or detail
        except json.JSONDecodeError:
            message = detail
        raise QueryFailure(f"{path} returned {error.status}: {message}") from error
    except urllib.error.URLError as error:
        raise QueryFailure(f"could not reach {base_url}: {error.reason}") from error


def probe_base_url(explicit: str | None) -> str:
    candidates = []
    if explicit:
        candidates.append(explicit)
    if os.environ.get("WORKSPACES_DOCS_BASE_URL"):
        candidates.append(os.environ["WORKSPACES_DOCS_BASE_URL"])
    candidates.extend(f"http://127.0.0.1:{port}" for port in DEFAULT_PORTS)

    seen = set()
    for candidate in candidates:
        base_url = candidate.rstrip("/")
        if base_url in seen:
            continue
        seen.add(base_url)
        try:
            manifest = request_json(base_url, "/docs/local-docs-manifest.json")
            if manifest.get("local"):
                return base_url
        except QueryFailure:
            continue
    raise QueryFailure(
        "No local WorkSpaces docs server found. Start one with: "
        "uv run --script docs/server.py --port 8098"
    )


def print_markdown(payload: dict) -> None:
    answer = payload.get("copyText") or payload.get("answer") or ""
    print(answer.strip() or "No answer returned.")
    citations = payload.get("citations") or []
    if citations:
        print("\nCitations:")
        for citation in citations:
            title = citation.get("title") or citation.get("source") or "Source"
            url = citation.get("url") or ""
            source = citation.get("source") or ""
            print(f"- {title}: {url} ({source})")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("query", help="Question to ask the local docs server.")
    parser.add_argument("--base-url", help="Local docs server base URL.")
    parser.add_argument("--limit", type=int, default=12, help="Filtered docs to send.")
    parser.add_argument("--json", action="store_true", help="Print raw JSON.")
    args = parser.parse_args()

    base_url = probe_base_url(args.base_url)
    search_path = f"/docs/api/search?{urllib.parse.urlencode({'q': args.query, 'limit': args.limit})}"
    request_json(base_url, search_path)
    payload = request_json(
        base_url,
        "/docs/api/ask",
        {"query": args.query},
    )
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        print_markdown(payload)


if __name__ == "__main__":
    try:
        main()
    except QueryFailure as error:
        print(f"workspaces-docs-ask failed: {error}", file=sys.stderr)
        raise SystemExit(1)
