#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Upload an evidence file to the R2-backed evidence store and print its public URL."""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ALLOWED_EXTENSIONS = {"png", "jpg", "jpeg", "gif", "webp", "svg"}
DEFAULT_BASE_URL = "https://evidence.cloudcompute.com"

CONTENT_TYPES = {
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "gif": "image/gif",
    "webp": "image/webp",
    "svg": "image/svg+xml",
}


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

    now = datetime.now(timezone.utc)
    timestamp = now.strftime("%Y%m%d-%H%M%S")
    slug = args.name or filepath.stem
    key = f"{args.repo}/pr-{args.pr}/{timestamp}-{slug}.{ext}"

    content_type = CONTENT_TYPES.get(ext, "application/octet-stream")
    data = filepath.read_bytes()

    url = f"{base_url.rstrip('/')}/{key}"
    req = Request(url, data=data, method="PUT")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", content_type)
    req.add_header("User-Agent", "upload-evidence/1.0")

    try:
        with urlopen(req) as resp:
            if resp.status not in (200, 201):
                print(f"error: upload failed with status {resp.status}", file=sys.stderr)
                return 1
    except HTTPError as e:
        print(f"error: upload failed: {e.code} {e.reason}", file=sys.stderr)
        return 1

    public_url = f"{base_url.rstrip('/')}/{key}"
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
