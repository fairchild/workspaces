#!/usr/bin/env python3
"""Operator-scope helper for the WorkSpaces Automation API.

Reads the per-launch operator credential the app mints
(automation-operator.json, 0600, next to automation.sock) and issues one
request over the unix socket with the handle header. Usage:

    ws-op.py GET  /v1/workspaces
    ws-op.py POST /v1/workspace/create '{"repoID":"…","name":"…","providerID":"local"}'
    ws-op.py POST /v1/window/snapshot '{"windowID":"12345"}' --png out.png

The snapshot payload's PNG is base64 under `data`; `--png` decodes it to a
file and prints the remaining metadata. windowID must be a JSON string (#995).
"""

import argparse
import base64
import json
import pathlib
import subprocess
import sys

CRED = (
    pathlib.Path.home()
    / "Library/Application Support/com.cloudcompute.workspaces/automation-operator.json"
)


def call(method: str, route: str, body: dict | None = None) -> dict:
    cred = json.loads(CRED.read_text())
    cmd = [
        "curl", "-s", "--unix-socket", cred["socketPath"], "-X", method,
        "-H", "x-workspaces-automation-handle: " + cred["handle"],
        "http://localhost" + route,
    ]
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("method", choices=["GET", "POST"])
    ap.add_argument("route")
    ap.add_argument("body", nargs="?", default=None)
    ap.add_argument("--png", help="decode result.data to this file (snapshots)")
    args = ap.parse_args()

    if not CRED.exists():
        print("no operator credential — enable Operator Scope and restart the app", file=sys.stderr)
        return 1
    body = json.loads(args.body) if args.body else None
    result = call(args.method, args.route, body)
    if args.png and result.get("ok") and "data" in result.get("result", {}):
        payload = result["result"]
        pathlib.Path(args.png).write_bytes(base64.b64decode(payload.pop("data")))
        payload["png"] = args.png
    print(json.dumps(result, indent=1))
    return 0 if result.get("ok") else 2


if __name__ == "__main__":
    sys.exit(main())
