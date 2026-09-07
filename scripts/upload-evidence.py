#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Upload an evidence file to the R2-backed evidence store and print its public URL."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ALLOWED_EXTENSIONS = {"png", "jpg", "jpeg", "gif", "webp", "svg", "webm", "mp4", "txt"}
MAX_UPLOAD_BYTES = 50 * 1024 * 1024
DEFAULT_BASE_URL = "https://evidence.cloudcompute.com"

CONTENT_TYPES = {
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "gif": "image/gif",
    "webp": "image/webp",
    "svg": "image/svg+xml",
    "webm": "video/webm",
    "mp4": "video/mp4",
    "txt": "text/plain; charset=utf-8",
}


def _uploaded_url(body: bytes) -> str | None:
    """Read the stored object's URL out of the store's 201 response."""
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    url = payload.get("url") if isinstance(payload, dict) else None
    return url if isinstance(url, str) and url else None


def main() -> int:
    parser = argparse.ArgumentParser(description="Upload evidence to R2 store")
    parser.add_argument("file", type=Path, help="File to upload")
    parser.add_argument("--repo", required=True, help="Repository short name")
    parser.add_argument("--pr", required=True, help="PR number")
    parser.add_argument("--name", default=None, help="Slug for the filename (default: original name)")
    parser.add_argument("--breadcrumb", action="store_true", help="Copy to ~/Desktop and append to april-runs.log")
    parser.add_argument("--base-url", default=None, help=f"Evidence store URL (default: {DEFAULT_BASE_URL})")
    args = parser.parse_args()

    base_url = args.base_url or os.environ.get("EVIDENCE_BASE_URL", DEFAULT_BASE_URL)
    token = os.environ.get("EVIDENCE_UPLOAD_TOKEN")
    if not token:
        print("error: EVIDENCE_UPLOAD_TOKEN environment variable is required", file=sys.stderr)
        return 1

    filepath: Path = args.file
    if not filepath.is_file():
        print(f"error: file not found: {filepath}", file=sys.stderr)
        return 1

    ext = filepath.suffix.lstrip(".").lower()
    if ext not in ALLOWED_EXTENSIONS:
        print(f"error: unsupported file type: .{ext} (allowed: {', '.join(sorted(ALLOWED_EXTENSIONS))})", file=sys.stderr)
        return 1

    size = filepath.stat().st_size
    if size > MAX_UPLOAD_BYTES:
        print(
            f"error: file is {size} bytes and exceeds the 50 MiB upload limit",
            file=sys.stderr,
        )
        return 1

    now = datetime.now(timezone.utc)
    timestamp = now.strftime("%Y%m%d-%H%M%S")
    slug = args.name or filepath.stem
    key = f"{args.repo}/pr-{args.pr}/{timestamp}-{slug}.{ext}"

    content_type = CONTENT_TYPES.get(ext, "application/octet-stream")
    data = filepath.read_bytes()
    if len(data) > MAX_UPLOAD_BYTES:
        print(
            f"error: file grew to {len(data)} bytes and exceeds the 50 MiB upload limit",
            file=sys.stderr,
        )
        return 1

    url = f"{base_url.rstrip('/')}/{key}"
    req = Request(url, data=data, method="PUT")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Length", str(len(data)))
    req.add_header("Content-Type", content_type)
    req.add_header("User-Agent", "upload-evidence/1.0")

    try:
        with urlopen(req) as resp:
            if resp.status not in (200, 201):
                print(f"error: upload failed with status {resp.status}", file=sys.stderr)
                return 1
            body = resp.read()
    except HTTPError as e:
        print(f"error: upload failed: {e.code} {e.reason}", file=sys.stderr)
        return 1

    # The store mints an unguessable segment into the key, so the object does
    # not live at the path we asked for. The response is the only authority on
    # where it landed.
    public_url = _uploaded_url(body)
    if public_url is None:
        print("error: upload succeeded but the store returned no URL", file=sys.stderr)
        return 1
    print(public_url)

    breadcrumb = args.breadcrumb or os.environ.get("EVIDENCE_BREADCRUMB") == "1"
    if breadcrumb:
        desktop = Path.home() / "Desktop"
        if desktop.is_dir():
            dest = desktop / f"{timestamp}-{slug}.{ext}"
            shutil.copy2(filepath, dest)

            log_file = desktop / "april-runs.log"
            iso = now.isoformat(timespec="seconds")
            with open(log_file, "a") as f:
                f.write(f"{iso}  {public_url}  {slug}\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
