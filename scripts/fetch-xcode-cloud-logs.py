#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "pyjwt[crypto]>=2.8",
# ]
# ///
"""Fetch Xcode Cloud build logs and issues for a commit via the App Store Connect API.

GitHub check-runs only carry Xcode Cloud's one-line failure summary; the real
script stdout/stderr lives in ASC LOG_BUNDLE artifacts. Requires a Team API key
with App Manager role: APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, and
APPLE_API_KEY_BASE64 (or APPLE_API_KEY_PATH).
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import time
import zipfile
from pathlib import Path
from typing import Any, Iterator
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import jwt

API_BASE = "https://api.appstoreconnect.apple.com"
INTERESTING_LOG = re.compile(r"post[_-]?clone|pre[_-]?xcodebuild|RunScript|ghosttykit", re.I)
FAILURE_LINE = re.compile(r"error|failed|fatal|No such file|command not found|sudo", re.I)
TAIL_LINES = 200


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"error: {name} environment variable is required")
    return value


def mint_token() -> str:
    key_id = require_env("APPLE_API_KEY_ID")
    issuer = require_env("APPLE_API_ISSUER_ID")
    if key_b64 := os.environ.get("APPLE_API_KEY_BASE64"):
        key = base64.b64decode(key_b64)
    elif key_path := os.environ.get("APPLE_API_KEY_PATH"):
        key = Path(key_path).read_bytes()
    else:
        sys.exit("error: set APPLE_API_KEY_BASE64 or APPLE_API_KEY_PATH")
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def api_get(token: str, url: str) -> dict[str, Any]:
    req = Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urlopen(req) as resp:
            return json.load(resp)
    except HTTPError as err:
        body = err.read().decode("utf-8", "replace")[:2000]
        sys.exit(f"error: GET {url} -> HTTP {err.code}\n{body}")


def paged(token: str, path: str, max_pages: int = 5, **params: str) -> Iterator[dict[str, Any]]:
    url = f"{API_BASE}{path}"
    if params:
        url += "?" + urlencode(params)
    for _ in range(max_pages):
        page = api_get(token, url)
        yield from page.get("data", [])
        url = page.get("links", {}).get("next")
        if not url:
            return


def commit_sha(run: dict[str, Any]) -> str:
    source = run.get("attributes", {}).get("sourceCommit") or {}
    return source.get("commitSha") or source.get("sha") or ""


def find_build_runs(token: str, sha: str) -> list[dict[str, Any]]:
    sha = sha.lower()
    matches = []
    for product in paged(token, "/v1/ciProducts"):
        for run in paged(token, f"/v1/ciProducts/{product['id']}/buildRuns", limit="200"):
            if commit_sha(run).lower().startswith(sha) or sha in json.dumps(run).lower():
                matches.append(run)
    return matches


def slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-") or "unnamed"


def print_issues(token: str, action_id: str) -> None:
    for issue in paged(token, f"/v1/ciBuildActions/{action_id}/issues"):
        attrs = issue.get("attributes", {})
        source = attrs.get("fileSource") or {}
        location = f" [{source.get('path')}:{source.get('lineNumber')}]" if source.get("path") else ""
        print(f"    issue [{attrs.get('issueType')}/{attrs.get('category')}]{location}: {attrs.get('message')}")


def excerpt(path: Path) -> None:
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError as err:
        print(f"    (unreadable: {err})")
        return
    interesting = path.name and INTERESTING_LOG.search(str(path))
    if interesting:
        print(f"    ---- tail -{TAIL_LINES} {path.name} ----")
        for line in lines[-TAIL_LINES:]:
            print(f"    {line}")
    else:
        hits = [line for line in lines if FAILURE_LINE.search(line)][:40]
        for line in hits:
            print(f"    {path.name}: {line}")


def download_artifacts(token: str, action_id: str, dest: Path) -> None:
    for artifact in paged(token, f"/v1/ciBuildActions/{action_id}/artifacts"):
        attrs = artifact.get("attributes", {})
        file_type, file_name = attrs.get("fileType", ""), attrs.get("fileName", "artifact")
        print(f"    artifact: {file_type} {file_name} ({attrs.get('fileSize')} bytes)")
        if "LOG" not in file_type.upper():
            continue
        url = attrs.get("downloadUrl")
        if not url:
            print("      (no downloadUrl)")
            continue
        dest.mkdir(parents=True, exist_ok=True)
        target = dest / slug(file_name)
        with urlopen(Request(url)) as resp:
            target.write_bytes(resp.read())
        if zipfile.is_zipfile(target):
            extract_dir = target.with_suffix("")
            with zipfile.ZipFile(target) as bundle:
                bundle.extractall(extract_dir)
            for member in sorted(extract_dir.rglob("*")):
                if member.is_file():
                    print(f"      extracted: {member.relative_to(dest)}")
                    excerpt(member)
        else:
            excerpt(target)


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch Xcode Cloud logs for a commit")
    parser.add_argument("--sha", required=True, help="Commit SHA (prefix ok) to look up")
    parser.add_argument("--out", type=Path, default=Path("xcode-cloud-logs"), help="Download directory")
    args = parser.parse_args()

    token = mint_token()
    runs = find_build_runs(token, args.sha)
    if not runs:
        print(f"no Xcode Cloud build runs found for {args.sha}", file=sys.stderr)
        return 2

    for run in runs:
        attrs = run.get("attributes", {})
        print(
            f"build run #{attrs.get('number')} ({run['id']}): "
            f"{attrs.get('executionProgress')}/{attrs.get('completionStatus')} "
            f"commit={commit_sha(run)[:12]} started={attrs.get('startedDate')}"
        )
        for action in paged(token, f"/v1/ciBuildRuns/{run['id']}/actions"):
            a_attrs = action.get("attributes", {})
            name = a_attrs.get("name", "action")
            print(f"  action {name} [{a_attrs.get('actionType')}]: {a_attrs.get('completionStatus')}")
            print_issues(token, action["id"])
            download_artifacts(token, action["id"], args.out / f"run-{attrs.get('number')}" / slug(name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
