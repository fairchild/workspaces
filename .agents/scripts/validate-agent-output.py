#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Validate and extract JSON output from agent responses.

Reads agent output from stdin, extracts JSON from ```json fences,
validates required fields, optionally checks for duplicate discussions.

Usage:
    cat response.txt | ./validate-agent-output.py [--check-dedup]
"""

import json
import re
import subprocess
import sys
from pathlib import Path

REQUIRED_FIELDS: dict[str, list[str]] = {
    "propose": ["title", "body", "persona"],
    "comment": ["discussion_number", "body", "persona"],
    "review_pr": ["pr_number", "body", "persona"],
    "advance_issue": ["issue_number", "body", "persona"],
    "plan": ["discussion_number", "issues"],
}


def extract_json(text: str) -> dict:
    """Extract JSON from ```json fences or raw text."""
    match = re.search(r"```json\s*\n(.*?)\n\s*```", text, re.DOTALL)
    raw = match.group(1) if match else text.strip()
    return json.loads(raw)


def normalize_title(title: str) -> str:
    """Strip prefix tags and normalize for comparison."""
    return re.sub(r"^\[.*?\]\s*", "", title).strip().lower()


def check_dedup(title: str) -> str | None:
    """Check if a similar discussion already exists. Returns match or None."""
    script = Path(__file__).parent.parent / "skills" / "gh-discuss" / "scripts" / "gh-discuss.py"
    try:
        result = subprocess.run(
            ["uv", "run", str(script), "list", "--json"],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            return None
        discussions = json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        return None

    proposed = normalize_title(title)
    if len(proposed) < 10:
        return None

    for d in discussions:
        existing = normalize_title(d.get("title", ""))
        if proposed == existing or (len(proposed) > 20 and proposed in existing):
            return d["title"]

    return None


def main() -> None:
    text = sys.stdin.read().strip()
    if not text:
        print("error: empty input", file=sys.stderr)
        sys.exit(1)

    try:
        data = extract_json(text)
    except (json.JSONDecodeError, AttributeError) as e:
        print(f"error: failed to parse JSON: {e}", file=sys.stderr)
        print(f"raw input (first 500 chars): {text[:500]}", file=sys.stderr)
        sys.exit(1)

    action = data.get("action")
    if action not in REQUIRED_FIELDS:
        print(f"error: unknown action '{action}'. Expected one of: {list(REQUIRED_FIELDS)}", file=sys.stderr)
        sys.exit(1)

    missing = [f for f in REQUIRED_FIELDS[action] if not data.get(f)]
    if missing:
        print(f"error: missing required fields for '{action}': {missing}", file=sys.stderr)
        sys.exit(1)

    # Fix common title issues for proposals
    if action == "propose":
        title = data["title"]
        if not title.startswith("[idea]"):
            data["title"] = f"[idea] {title}"

        # Dedup check if requested
        if "--check-dedup" in sys.argv:
            dup = check_dedup(data["title"])
            if dup:
                print(f"duplicate: proposed '{data['title']}' matches existing '{dup}'", file=sys.stderr)
                sys.exit(2)

    json.dump(data, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
