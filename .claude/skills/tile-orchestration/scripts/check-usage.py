#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check remaining codex and Claude Code usage quota before a big parallel fan-out.

Both mechanisms are undocumented CLI/account-status queries, not documented
public APIs — reverse-engineered from the open-source Orca app
(github.com/stablyai/orca, src/main/rate-limits/{codex,claude}-fetcher.ts),
which surfaces the same numbers in its status-bar usage indicator. Neither
call consumes a real model request.

    codex:  spawns `codex -s read-only -a untrusted app-server`, speaks the
            JSON-RPC/LSP handshake (initialize -> initialized notification),
            then calls `account/rateLimits/read`.
    claude: reads the OAuth token Claude Code stores in the macOS Keychain
            (`security find-generic-password -s "Claude Code-credentials"`)
            and GETs https://api.anthropic.com/api/oauth/usage with it.

Usage:
    uv run --script scripts/check-usage.py
    uv run --script scripts/check-usage.py --json
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request


def check_codex() -> dict:
    try:
        proc = subprocess.Popen(
            ["codex", "-s", "read-only", "-a", "untrusted", "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError:
        return {"available": False, "reason": "codex CLI not found"}

    def send(msg: dict) -> None:
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    send(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"clientInfo": {"name": "check-usage", "version": "1.0.0"}},
        }
    )

    deadline = time.time() + 10
    result = None
    init_done = False
    try:
        while time.time() < deadline:
            line = proc.stdout.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == 1 and not init_done:
                init_done = True
                proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "initialized", "params": {}}) + "\n")
                proc.stdin.flush()
                send({"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"})
                continue
            if msg.get("id") == 2:
                result = msg
                break
    finally:
        proc.terminate()

    if result is None:
        return {"available": False, "reason": "no response from app-server (not signed in?)"}
    if "error" in result:
        return {"available": False, "reason": result["error"].get("message", "unknown RPC error")}

    limits = result["result"]["rateLimits"]
    return {
        "available": True,
        "five_hour_used_pct": limits["primary"]["usedPercent"],
        "five_hour_resets_at": limits["primary"]["resetsAt"],
        "weekly_used_pct": limits["secondary"]["usedPercent"],
        "weekly_resets_at": limits["secondary"]["resetsAt"],
        "plan": limits.get("planType"),
    }


def check_claude() -> dict:
    try:
        token = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-a", os.environ.get("USER", ""), "-w"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        access_token = json.loads(token)["claudeAiOauth"]["accessToken"]
    except (subprocess.CalledProcessError, KeyError, json.JSONDecodeError, FileNotFoundError):
        return {"available": False, "reason": "no Claude Code OAuth credentials in Keychain"}

    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": f"Bearer {access_token}",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
    except Exception as e:  # noqa: BLE001 - report any failure, this is a diagnostic tool
        return {"available": False, "reason": f"usage endpoint request failed: {e}"}

    return {
        "available": True,
        "five_hour_used_pct": data["five_hour"]["utilization"],
        "five_hour_resets_at": data["five_hour"]["resets_at"],
        "weekly_used_pct": data["seven_day"]["utilization"],
        "weekly_resets_at": data["seven_day"]["resets_at"],
        "per_model_limits": [
            {"model": lim["scope"]["model"]["display_name"], "used_pct": lim["percent"]}
            for lim in data.get("limits", [])
            if lim.get("scope") and lim["scope"].get("model", {}).get("display_name")
        ],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    result = {"codex": check_codex(), "claude": check_claude()}

    if args.json:
        print(json.dumps(result, indent=2))
        return 0

    for name, r in result.items():
        if not r["available"]:
            print(f"{name}: unavailable ({r['reason']})")
            continue
        line = f"{name}: 5h {r['five_hour_used_pct']}% used, weekly {r['weekly_used_pct']}% used"
        if r.get("plan"):
            line += f" (plan: {r['plan']})"
        print(line)
        for lim in r.get("per_model_limits", []):
            print(f"  - {lim['model']}: {lim['used_pct']}% used")
    return 0


if __name__ == "__main__":
    sys.exit(main())
