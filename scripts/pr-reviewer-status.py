#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx"]
# ///
"""PR Reviewer session observer.

Usage:
  ./scripts/pr-reviewer-status.py                    # List recent sessions
  ./scripts/pr-reviewer-status.py sesn_abc123         # Show session events
  ./scripts/pr-reviewer-status.py --errors            # Show recent Vercel errors
"""

import json
import os
import subprocess
import sys

import httpx

HEADERS = {
    "anthropic-version": "2023-06-01",
    "anthropic-beta": "managed-agents-2026-04-01",
}


def get_api_key() -> str:
    key = os.environ.get("ANTHROPIC_API_KEY")
    if key:
        return key
    # Try sourcing from ~/.env
    try:
        result = subprocess.run(
            ["bash", "-c", "source ~/.env 2>/dev/null && echo $ANTHROPIC_API_KEY"],
            capture_output=True, text=True, timeout=5,
        )
        key = result.stdout.strip()
        if key:
            return key
    except Exception:
        pass
    print("ANTHROPIC_API_KEY not found in env or ~/.env", file=sys.stderr)
    sys.exit(1)


def api(path: str, api_key: str) -> dict:
    resp = httpx.get(
        f"https://api.anthropic.com{path}",
        headers={**HEADERS, "x-api-key": api_key},
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def list_sessions(api_key: str) -> None:
    data = api("/v1/sessions?limit=10", api_key)
    for s in data.get("data", []):
        title = s.get("title", "")
        status = s.get("status", "")
        created = s.get("created_at", "")[:19]
        sid = s.get("id", "")
        meta = s.get("metadata", {})
        pr = meta.get("pr_number", "")
        marker = " ← PR review" if pr else ""
        print(f"{created}  {status:<12}  {sid}{marker}")
        if title:
            print(f"  {title[:80]}")
        print()


def show_events(session_id: str, api_key: str) -> None:
    # Session status
    s = api(f"/v1/sessions/{session_id}", api_key)
    usage = s.get("usage", {})
    print(f"status: {s['status']}")
    print(f"title:  {s.get('title', '')}")
    input_t = usage.get("input_tokens", 0)
    output_t = usage.get("output_tokens", 0)
    cache_r = usage.get("cache_read_input_tokens", 0)
    print(f"tokens: {input_t} in / {output_t} out / {cache_r} cache-read")
    print("---")

    # Events
    data = api(f"/v1/sessions/{session_id}/events?limit=100", api_key)
    events = data.get("data", [])
    for e in events:
        t = e.get("type", "")
        if t == "agent.message":
            for b in e.get("content", []):
                if b.get("type") == "text":
                    print(f"[msg] {b['text'][:400]}")
        elif t == "agent.tool_use":
            name = e.get("name", "")
            inp = json.dumps(e.get("input", {}))[:200]
            print(f"[tool] {name}: {inp}")
        elif t == "agent.tool_result":
            parts = [
                b.get("text", "")[:150]
                for b in e.get("content", [])
                if b.get("type") == "text"
            ]
            if parts:
                print(f"[result] {parts[0]}")
        elif t == "agent.mcp_tool_use":
            print(f"[mcp] {e.get('name', '')}: {json.dumps(e.get('input', {}))[:200]}")
        elif t == "session.error":
            print(f"[error] {json.dumps(e.get('error', {}))[:300]}")
        elif t.startswith("session.status"):
            reason = e.get("stop_reason", {})
            print(f"[{t}] {json.dumps(reason) if reason else ''}")


def main() -> None:
    api_key = get_api_key()
    args = sys.argv[1:]

    if not args:
        list_sessions(api_key)
    elif args[0].startswith("sesn_"):
        show_events(args[0], api_key)
    elif args[0] == "--errors":
        print("Use: vercel logs --environment production --no-branch --since 5m --level error --expand")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
