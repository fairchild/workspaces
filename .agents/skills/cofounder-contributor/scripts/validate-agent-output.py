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
    "recommend_close": ["discussion_number", "body", "persona"],
    "review_pr": ["pr_number", "body", "persona", "verdict"],
    "execute_issue": ["issue_number", "pr_title", "commit_message", "body", "persona"],
    "advance_pr": ["pr_number", "issue_number", "pr_title", "commit_message", "body", "persona"],
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


# Every line break str.splitlines() recognizes, so line-oriented scanning
# below can't be fooled into treating one of these as ordinary content: a
# character straddling what "one line" means between this module's own
# `\n`-based joins and parse-frontmatter.py's `_parse_yaml_subset` (which
# uses splitlines() internally) is exactly how an earlier draft's
# duplicate-key guard was bypassed (#1179 codex review round 2) -- multiple
# `key: value` lines joined by e.g. U+2028 looked like one atomic unit to the
# guard but were parsed as several by the delegate. Order matters: "\r\n"
# must collapse before the standalone "\r" pass.
_UNICODE_LINE_BREAKS = ("\r\n", "\r", "\v", "\f", "\x1c", "\x1d", "\x1e", "\x85", "\u2028", "\u2029")


def _normalize_line_endings(text: str) -> str:
    for line_break in _UNICODE_LINE_BREAKS:
        text = text.replace(line_break, "\n")
    return text


def _frontmatter_delimiter_lines(lines: list[str]) -> list[int]:
    """Indices of ``lines`` that are real frontmatter delimiters.

    A delimiter is a line whose stripped content is exactly ``---`` --
    incidental surrounding whitespace tolerated, matching
    parse-frontmatter.py's own boundary rule (`_is_frontmatter_boundary`,
    `parse_multi_document`) rather than a stricter rule of this module's own
    invention; two different definitions of "is this a delimiter" between
    the code that COUNTS them and the code that PARSES them is exactly how
    an earlier draft was bypassed (#1179 codex review round 2). Lines inside
    a fenced code block (``` ... ```) never count -- a documented example of
    frontmatter syntax inside a fence is common and must never be mistaken
    for a live control block.
    """
    positions: list[int] = []
    in_fence = False
    for index, line in enumerate(lines):
        stripped_line = line.strip()
        if stripped_line.startswith("```"):
            in_fence = not in_fence
            continue
        if not in_fence and stripped_line == "---":
            positions.append(index)
    return positions


def _salvage_truncated_frontmatter(lines: list[str]) -> dict | None:
    """Recover a frontmatter block whose closing delimiter never arrived.

    Covers "review analysis fully completed, then died at the output stage"
    (#1179): the model wrote metadata (and often a full markdown body) but
    the closing ``---`` itself is missing -- either a formatting slip after
    a complete response, or the output was genuinely cut off partway through
    the metadata block.

    Deliberately conservative, since this runs on model output that reads
    untrusted GitHub content (a PR's diff, its own commentary) as context: a
    prompt-injected or merely unlucky response could contain text shaped
    like a second control block, and getting the metadata/body boundary
    wrong here can silently substitute a different verdict, persona, or PR
    number into a real GitHub review. Several independent safety properties,
    not layered as a fallback chain (a single path that skips any one of
    them is a bug, not a smaller version of one -- see #1179's codex review,
    which found exactly that shape of bug twice in earlier drafts):

    1. Structural: salvage only fires when `lines` contains EXACTLY ONE real
       (fence-aware) delimiter. Two or more is unresolvable safely -- it
       could be a genuinely closed block whose content failed validation
       for some *other* reason (salvaging past its closer would
       reinterpret unrelated body/markdown as metadata), or a body's own
       markdown horizontal rule. Rather than guess which delimiter is the
       real dangling opener, don't salvage at all -- this is a deliberately
       conservative false-negative: a genuine missing-closer response whose
       preamble or completed body *also* contains an unrelated `---` line
       is left unsalvaged too.
    2. Content: within that single candidate, metadata is exactly the
       leading contiguous run of `key: value` lines, computed by growing the
       parsed prefix one line at a time and stopping at the FIRST line that
       is (a) blank -- every real template separates metadata from body
       with a blank line, so this is the common case, (b) a fence opener --
       nothing inside a fence is ever metadata, or (c) would redefine an
       already-captured key with a different value, in case a blank line is
       ever missing. Never keep scanning past a stop looking for a longer
       prefix that also happens to parse; a body line that coincidentally
       looks like `key: value` (a bare "verdict: ..." sentence, a labeled
       note) must end up in `body`, never overwrite a real field.

    Known limitation: this recovers metadata field-by-field, so it doesn't
    understand a value that spans multiple lines (a quoted multi-line
    `commit_message`, used by execute_issue/advance_pr, not review). A
    genuinely truncated multi-line value still fails safely -- the field is
    reported missing by the same required-field validation every other path
    uses -- it just isn't salvaged; only single-line values recover.
    """
    delimiters = _frontmatter_delimiter_lines(lines)
    if len(delimiters) != 1:
        return None
    body_lines = lines[delimiters[0] + 1 :]

    best_metadata: dict | None = None
    best_split = 0
    for split in range(1, len(body_lines) + 1):
        line = body_lines[split - 1].strip()
        if not line or line.startswith("```"):
            break
        try:
            metadata = _fm._parse_yaml_subset("\n".join(body_lines[:split]))
        except ValueError:
            break
        if not metadata:
            continue
        if best_metadata is not None and any(
            key in best_metadata and best_metadata[key] != value for key, value in metadata.items()
        ):
            break
        best_metadata, best_split = metadata, split
    if best_metadata is None:
        return None
    body = "\n".join(body_lines[best_split:]).strip()
    if body:
        best_metadata["body"] = body
    return best_metadata


def extract_structured(text: str) -> dict:
    """Extract structured data from YAML frontmatter or ```json fences.

    In CLI agentic mode, Claude may emit reasoning text before the
    frontmatter block.  Scan every line-level ``---`` candidate so a
    preamble horizontal rule does not hide the real frontmatter block.

    A frontmatter opener commits the response to that format: once a real
    (fence-aware) ``---`` delimiter is present anywhere, extraction never
    falls through to `extract_json`'s JSON-fence scan -- this model's output
    reads untrusted GitHub content (a PR's own diff, its review commentary)
    as context, and that content can easily contain a JSON-shaped object (a
    config file excerpt, an example payload, even a fenced ```json block)
    that a JSON scan could mistake for the actionable review.

    There is no analogous stray-text-JSON salvage: unlike the truncated-
    frontmatter case, nothing in #1179's evidence points at JSON output ever
    being the real shape here (every persona's documented output format is
    YAML frontmatter), and a generic "find `{...}` anywhere in the text"
    scan has no structural signal at all to distinguish the model's own
    conclusion from JSON-shaped content it read out of the PR diff or
    quoted in its own commentary while explaining why it's NOT the
    conclusion -- #1179's codex review reproduced exactly that with quoted,
    disclaimed JSON. `extract_json`'s existing ```json-fence behavior is
    left as-is for responses that never attempt frontmatter at all (the
    shape it was originally built for).
    """
    lines = _normalize_line_endings(text).strip().split("\n")
    stripped = "\n".join(lines)
    first_frontmatter: dict | None = None

    for match in re.finditer(r"(?m)^---$", stripped):
        result = _try_frontmatter(stripped[match.start() :])
        if result is None:
            continue
        if result.get("action"):
            return result
        if first_frontmatter is None:
            first_frontmatter = result

    if first_frontmatter is not None:
        return first_frontmatter

    if _frontmatter_delimiter_lines(lines):
        salvaged = _salvage_truncated_frontmatter(lines)
        if salvaged is not None:
            print(
                "warning: primary output parse failed; salvaged via _salvage_truncated_frontmatter",
                file=sys.stderr,
            )
            return salvaged
        # Deliberately NOT `extract_json(stripped)`: its own ```json-fence
        # search has the exact problem this branch exists to avoid -- a
        # fenced JSON example elsewhere in the text (a config excerpt in the
        # review's own commentary) would satisfy it despite the frontmatter
        # opener never resolving to anything usable.
        raise ValueError(
            "frontmatter opener present but no valid document could be recovered"
        )

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


def validate_string_list(value: Any, field_name: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValidationError(f"field '{field_name}' must be a list of non-empty strings")
    normalized: list[str] = []
    for index, item in enumerate(value, start=1):
        if not isinstance(item, str) or not item.strip():
            raise ValidationError(f"field '{field_name}[{index}]' must be a non-empty string")
        normalized.append(item.strip())
    return normalized


def validate_plan(data: dict[str, Any]) -> None:
    milestone_name = data.get("milestone_name")
    if milestone_name is not None and (not isinstance(milestone_name, str) or not milestone_name.strip()):
        raise ValidationError("field 'milestone_name' must be a non-empty string or null")

    issues = data.get("issues")
    if not isinstance(issues, list) or not issues:
        raise ValidationError("field 'issues' must be a non-empty list")

    seen_titles: set[str] = set()
    for index, issue in enumerate(issues, start=1):
        if not isinstance(issue, dict):
            raise ValidationError(f"issue #{index} must be an object")

        title = require_non_empty_string(issue.get("title"), f"issues[{index}].title")
        require_non_empty_string(issue.get("body"), f"issues[{index}].body")

        title_key = title.casefold()
        if title_key in seen_titles:
            raise ValidationError(f"duplicate issue title in plan: '{title}'")
        seen_titles.add(title_key)

        labels = issue.get("labels")
        if labels is None:
            continue
        if not isinstance(labels, list) or any(not isinstance(label, str) or not label.strip() for label in labels):
            raise ValidationError(f"field 'issues[{index}].labels' must be a list of non-empty strings")


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

    if action in {"execute_issue", "advance_pr"}:
        data["pr_title"] = require_non_empty_string(data.get("pr_title"), "pr_title")
        data["commit_message"] = require_non_empty_string(data.get("commit_message"), "commit_message")
        issue_number = data.get("issue_number")
        if not isinstance(issue_number, int) or issue_number <= 0:
            raise ValidationError("field 'issue_number' must be a positive integer")
        data.pop("evidence_complete", None)
        data.pop("evidence_blocked", None)
        data.pop("evidence_pending_ci", None)
        if action == "advance_pr":
            pr_number = data.get("pr_number")
            if not isinstance(pr_number, int) or pr_number <= 0:
                raise ValidationError("field 'pr_number' must be a positive integer")

    if action == "review_pr":
        verdict = require_non_empty_string(data.get("verdict"), "verdict").casefold()
        if verdict not in {"approve", "approve_with_followups", "request_changes"}:
            raise ValidationError(
                "field 'verdict' must be approve, approve_with_followups, or request_changes"
            )
        data["verdict"] = verdict

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
