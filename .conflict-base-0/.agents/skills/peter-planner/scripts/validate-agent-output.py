#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Validate and extract structured output from agent responses.

Reads agent output from stdin, extracts data from YAML frontmatter
(preferred) or ```json fences (fallback), validates required fields,
optionally checks for duplicate discussions.

Usage:
    cat response.txt | ./validate-agent-output.py [--check-dedup]
"""

import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


def _load_frontmatter_parser():
    spec = importlib.util.spec_from_file_location(
        "parse_frontmatter",
        Path(__file__).parent / "parse-frontmatter.py",
    )
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


_fm = _load_frontmatter_parser()

REQUIRED_FIELDS: dict[str, list[str]] = {
    "propose": ["title", "body", "persona"],
    "comment": ["discussion_number", "body", "persona"],
    "review_pr": ["pr_number", "body", "persona"],
    "plan": ["discussion_number", "issues"],
}


class ValidationError(ValueError):
    """Raised when agent output fails schema validation."""


def extract_json(text: str) -> dict:
    """Extract JSON from ```json fences or raw text."""
    match = re.search(r"```json\s*\n(.*?)\n\s*```", text, re.DOTALL)
    raw = match.group(1) if match else text.strip()
    return json.loads(raw)


def _try_frontmatter(text: str) -> dict | None:
    """Attempt frontmatter parse, returning dict or None on failure."""
    try:
        documents = _fm.parse_multi_document(text)
        if len(documents) > 1 and documents[0][0].get("action") == "plan":
            header, _ = documents[0]
            issues = []
            for metadata, body in documents[1:]:
                issue = dict(metadata)
                issue["body"] = body
                issues.append(issue)
            result = dict(header)
            result["issues"] = issues
            return result
        metadata, body = documents[0]
        if body:
            metadata["body"] = body
        return metadata
    except (ValueError, IndexError):
        return None


def extract_structured(text: str) -> dict:
    """Extract structured data from YAML frontmatter or ```json fences.

    In CLI agentic mode, Claude may emit reasoning text before the
    frontmatter block.  We first try parsing from the start, then scan
    for the first ``---`` boundary in the body.
    """
    stripped = text.strip()

    # Fast path: text starts with frontmatter
    if stripped.startswith("---"):
        result = _try_frontmatter(stripped)
        if result is not None:
            return result

    # Scan for frontmatter after preamble (CLI agentic mode)
    idx = stripped.find("\n---\n")
    if idx != -1:
        result = _try_frontmatter(stripped[idx + 1:])
        if result is not None:
            return result

    return extract_json(stripped)


def normalize_title(title: str) -> str:
    """Strip prefix tags and normalize for comparison."""
    return re.sub(r"^\[.*?\]\s*", "", title).strip().lower()


def check_dedup(title: str) -> str | None:
    """Check if a similar discussion already exists. Returns match or None."""
    script = Path(__file__).resolve().parents[2] / "gh-discuss" / "scripts" / "gh-discuss.py"
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


def require_non_empty_string(value: Any, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"field '{field_name}' must be a non-empty string")
    return value.strip()


def validate_plan(data: dict[str, Any]) -> None:
    milestone_name = data.get("milestone_name")
    if milestone_name is not None and (not isinstance(milestone_name, str) or not milestone_name.strip()):
        raise ValidationError("field 'milestone_name' must be a non-empty string or null")

    issues = data.get("issues")
    if not isinstance(issues, list) or not issues:
        raise ValidationError("field 'issues' must be a non-empty list")

    seen_titles: set[str] = set()
    seen_priorities: set[int] = set()
    for index, issue in enumerate(issues, start=1):
        if not isinstance(issue, dict):
            raise ValidationError(f"issue #{index} must be an object")

        title = require_non_empty_string(issue.get("title"), f"issues[{index}].title")
        require_non_empty_string(issue.get("body"), f"issues[{index}].body")

        title_key = title.casefold()
        if title_key in seen_titles:
            raise ValidationError(f"duplicate issue title in plan: '{title}'")
        seen_titles.add(title_key)

        priority = issue.get("priority")
        if not isinstance(priority, int) or priority <= 0:
            raise ValidationError(f"field 'issues[{index}].priority' must be a positive integer")
        if priority in seen_priorities:
            raise ValidationError(f"duplicate issue priority in plan: '{priority}'")
        seen_priorities.add(priority)

        labels = issue.get("labels")
        if labels is not None and (
            not isinstance(labels, list)
            or any(not isinstance(label, str) or not label.strip() for label in labels)
        ):
            raise ValidationError(f"field 'issues[{index}].labels' must be a list of non-empty strings")

        blocked_by = issue.get("blocked_by", [])
        if not isinstance(blocked_by, list) or any(not isinstance(value, int) or value <= 0 for value in blocked_by):
            raise ValidationError(f"field 'issues[{index}].blocked_by' must be a list of positive integers")

        requested_evidence = issue.get("requested_evidence")
        if (
            not isinstance(requested_evidence, list)
            or not requested_evidence
            or any(not isinstance(value, str) or not value.strip() for value in requested_evidence)
        ):
            raise ValidationError(
                f"field 'issues[{index}].requested_evidence' must be a non-empty list of strings"
            )


def validate_data(data: dict[str, Any]) -> dict[str, Any]:
    action = data.get("action")
    if action not in REQUIRED_FIELDS:
        raise ValidationError(
            f"unknown action '{action}'. Expected one of: {list(REQUIRED_FIELDS)}"
        )

    missing = [field for field in REQUIRED_FIELDS[action] if not data.get(field)]
    if missing:
        raise ValidationError(f"missing required fields for '{action}': {missing}")

    if action == "plan":
        validate_plan(data)

    if action == "propose":
        title = require_non_empty_string(data.get("title"), "title")
        if not title.startswith("[idea]"):
            data["title"] = f"[idea] {title}"

    return data


def main() -> None:
    text = sys.stdin.read().strip()
    if not text:
        print("error: empty input", file=sys.stderr)
        sys.exit(1)

    try:
        data = extract_structured(text)
    except (json.JSONDecodeError, ValueError, AttributeError) as e:
        print(f"error: failed to parse output: {e}", file=sys.stderr)
        print(f"raw input (first 500 chars): {text[:500]}", file=sys.stderr)
        sys.exit(1)

    action = data.get("action")
    try:
        data = validate_data(data)
    except ValidationError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    # Dedup check if requested
    if action == "propose" and "--check-dedup" in sys.argv:
        dup = check_dedup(data["title"])
        if dup:
            print(f"duplicate: proposed '{data['title']}' matches existing '{dup}'", file=sys.stderr)
            sys.exit(2)

    json.dump(data, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
