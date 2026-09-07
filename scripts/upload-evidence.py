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
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
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


def _uploaded_key(body: bytes) -> str | None:
    """The stored object's key from the store's 201 response, if it is usable.

    Usable means addressable: a key is a path under the store's authority, so a
    blank one addresses the store itself and a `.` or `..` segment addresses
    something else entirely once a client collapses it. A control character
    would break the single line this script prints. None of the three is a key
    the store should ever mint, so each is a malfunction to report, not to
    paper over.
    """
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    key = payload.get("key") if isinstance(payload, dict) else None
    if not isinstance(key, str) or not key.strip():
        return None
    if any(segment in {".", ".."} for segment in key.split("/")):
        return None
    if any(character < " " or character == "\x7f" for character in key):
        return None
    return key


def _authority(netloc: str) -> str:
    """Host and port, without whatever authorized the upload.

    Credentials in a URL are a write concern and reads here are public, so they
    belong in neither a URL we print nor an error we log.
    """
    return netloc.rpartition("@")[2]


def _public_url(sent_url: str, stored_key: str) -> str:
    """Where the object landed: our address for the store, its key.

    The key is the whole path the store answers on, so it already carries any
    path prefix the caller dialed through, and everything but scheme and
    authority comes off the URL we sent.
    """
    sent = urlsplit(sent_url)
    return urlunsplit((sent.scheme, _authority(sent.netloc), f"/{stored_key}", "", ""))


def _for_display(url: str) -> str:
    """Enough of a URL to say which store this was, and nothing that authorizes."""
    parts = urlsplit(url)
    return urlunsplit((parts.scheme, _authority(parts.netloc), parts.path, "", ""))


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
    except URLError as e:
        # A store that cannot be dialed at all — down, misspelled, or carrying
        # credentials in the URL, which urllib passes to the resolver whole.
        print(f"error: could not reach {_for_display(base_url)}: {e.reason}", file=sys.stderr)
        return 1

    # The store mints an unguessable segment into the key, so the object does
    # not live at the path we asked for, and only the store knows where it
    # landed. Only we know how to reach the store: its own `url` field hardcodes
    # https and drops the port, which is right only for a custom domain on 443.
    # So take the key from the store and the address from the dial.
    stored_key = _uploaded_key(body)
    if stored_key is None:
        print("error: upload succeeded but the store returned no usable key", file=sys.stderr)
        return 1
    public_url = _public_url(url, stored_key)
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
