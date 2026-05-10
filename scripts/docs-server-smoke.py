#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fast HTTP smoke checks for the local WorkSpaces docs server.

Usage:
    uv run --script scripts/docs-server-smoke.py
    uv run --script scripts/docs-server-smoke.py --base-url http://127.0.0.1:8098
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class SmokeFailure(RuntimeError):
    pass


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def request(
    base_url: str,
    path: str,
    *,
    method: str = "GET",
    body: dict | None = None,
) -> tuple[int, dict[str, str], bytes]:
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(
        f"{base_url}{path}", data=data, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return (
                int(response.status),
                {key.lower(): value for key, value in response.headers.items()},
                response.read(),
            )
    except urllib.error.HTTPError as error:
        return (
            int(error.status),
            {key.lower(): value for key, value in error.headers.items()},
            error.read(),
        )


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SmokeFailure(message)


def wait_for_server(base_url: str, process: subprocess.Popen[str]) -> None:
    deadline = time.time() + 10
    while time.time() < deadline:
        if process.poll() is not None:
            stdout, stderr = process.communicate(timeout=1)
            raise SmokeFailure(
                f"docs server exited early with {process.returncode}\n"
                f"stdout:\n{stdout}\nstderr:\n{stderr}"
            )
        try:
            status, _, _ = request(base_url, "/docs/")
            if status == 200:
                return
        except OSError:
            pass
        time.sleep(0.1)
    raise SmokeFailure(f"timed out waiting for {base_url}")


def write_fake_claude(directory: Path) -> Path:
    fake_claude = directory / "claude"
    fake_claude.write_text(
        """#!/usr/bin/env python3
import json
print(json.dumps({
  "type": "result",
  "session_id": "docs-smoke-fake-claude",
  "total_cost_usd": 0,
  "result": json.dumps({
    "answer_markdown": "Use the local docs server for rendered pages and raw `.md` paths for source Markdown.",
    "copy_text": "Use the local docs server for rendered pages and raw `.md` paths for source Markdown.",
    "citations": [{
      "title": "WorkSpaces Docs Site",
      "url": "/docs/docs-site",
      "source": "docs/README.md",
      "snippet": "Local docs server and raw Markdown contract."
    }]
  })
}))
""",
        encoding="utf-8",
    )
    fake_claude.chmod(fake_claude.stat().st_mode | stat.S_IXUSR)
    return fake_claude


def run_checks(base_url: str, *, check_ask: bool) -> None:
    status, headers, body = request(base_url, "/docs/")
    expect(status == 200, f"/docs/ returned {status}")
    expect(b"WorkSpaces" in body, "/docs/ did not include the landing page")

    status, headers, body = request(base_url, "/docs/developer-operator-index.html")
    expect(status == 200, f"operator index returned {status}")
    expect(b"/docs/api/ask" in body, "operator index is missing docs ask wiring")

    status, _, body = request(base_url, "/docs/local-docs-manifest.json")
    expect(status == 200, f"local docs manifest returned {status}")
    manifest = json.loads(body)
    entries = manifest.get("entries", [])
    expect(manifest.get("local") is True, "local docs manifest is not marked local")
    expect(len(entries) >= 50, f"expected at least 50 local docs, found {len(entries)}")
    expect(
        any(entry.get("dest") == "development/agent-team.md" for entry in entries),
        "local manifest is missing uncurated development/agent-team.md",
    )

    status, headers, body = request(
        base_url, "/docs/development/libghostty-integration.md"
    )
    expect(status == 200, "raw Markdown doc did not return 200")
    expect(
        "text/markdown" in headers.get("content-type", ""),
        f"raw Markdown content type was {headers.get('content-type')}",
    )
    expect(body.lstrip().startswith(b"# "), "raw Markdown body did not start with H1")

    status, headers, body = request(
        base_url, "/docs/development/libghostty-integration"
    )
    expect(status == 200, "extensionless rendered doc did not return 200")
    expect(
        "text/html" in headers.get("content-type", ""),
        f"rendered doc content type was {headers.get('content-type')}",
    )
    expect(b"WorkSpaces Docs Reader" in body, "rendered doc omitted reader shell")
    expect(b"/docs/local-docs-manifest.json" in body, "reader shell cannot load manifest")

    if check_ask:
        status, _, body = request(
            base_url,
            "/docs/api/ask",
            method="POST",
            body={
                "query": "How do I use rendered docs and raw markdown?",
                "filteredResults": [
                    {
                        "title": "WorkSpaces Docs Site",
                        "dest": "docs-site.md",
                        "source": "docs/README.md",
                        "snippet": "Local docs server and raw Markdown contract.",
                    }
                ],
            },
        )
        expect(status == 200, f"docs ask returned {status}: {body.decode()[:300]}")
        answer = json.loads(body)
        expect(answer.get("answer"), "docs ask response did not include answer")
        expect(answer.get("copyText"), "docs ask response did not include copyText")
        expect(answer.get("citations"), "docs ask response did not include citations")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base-url",
        help="Validate an already-running docs server instead of starting one.",
    )
    parser.add_argument("--port", type=int, help="Port to use when starting a server.")
    parser.add_argument(
        "--ask",
        action="store_true",
        help="Also call /docs/api/ask when validating an existing server.",
    )
    parser.add_argument(
        "--real-claude",
        action="store_true",
        help="When starting a server, use the real claude binary instead of a fake one.",
    )
    args = parser.parse_args()

    process: subprocess.Popen[str] | None = None
    temp_dir: tempfile.TemporaryDirectory[str] | None = None
    try:
        if args.base_url:
            base_url = args.base_url.rstrip("/")
            check_ask = args.ask
        else:
            temp_dir = tempfile.TemporaryDirectory(prefix="workspaces-docs-smoke-")
            port = args.port or free_port()
            base_url = f"http://127.0.0.1:{port}"
            env = {
                **os.environ,
                "PYTHONPYCACHEPREFIX": str(Path(temp_dir.name) / "pycache"),
                "WORKSPACES_DOCS_ASK_TIMEOUT_SECONDS": "10",
            }
            if not args.real_claude:
                fake_claude = write_fake_claude(Path(temp_dir.name))
                env["WORKSPACES_DOCS_ASK_CLAUDE_BIN"] = str(fake_claude)
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(REPO_ROOT / "docs/server.py"),
                    "--port",
                    str(port),
                ],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            wait_for_server(base_url, process)
            check_ask = True

        run_checks(base_url, check_ask=check_ask)
        print(f"docs server smoke passed: {base_url}")
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        if temp_dir is not None:
            temp_dir.cleanup()


if __name__ == "__main__":
    try:
        main()
    except SmokeFailure as error:
        print(f"docs server smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1)
