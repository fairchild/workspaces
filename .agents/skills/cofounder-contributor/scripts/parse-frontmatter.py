#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Parse YAML frontmatter from agent output.

Handles a subset of YAML: strings (bare/quoted), integers, booleans,
null, and inline lists.  No external dependencies.

Functions:
    parse_frontmatter(text) -> (metadata, body)
    parse_multi_document(text) -> [(metadata, body), ...]
"""

from __future__ import annotations

import re
from typing import Any


Value = str | int | bool | None | list[Any]


def _parse_yaml_value(raw: str) -> Value:
    """Parse a single YAML value from the supported subset."""
    value = raw.strip()
    if not value:
        return ""
    if value == "null":
        return None
    if value == "true":
        return True
    if value == "false":
        return False
    if re.fullmatch(r"-?\d+", value):
        return int(value)
    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith("'") and value.endswith("'")
    ):
        return value[1:-1]
    if value.startswith("[") and value.endswith("]"):
        return _parse_inline_list(value[1:-1])
    return value


def _parse_inline_list(content: str) -> list[str]:
    """Parse inline list content: ``enhancement, "area: ui"``."""
    items: list[str] = []
    current: list[str] = []
    in_quotes = False
    quote_char: str | None = None

    for char in content:
        if in_quotes:
            if char == quote_char:
                in_quotes = False
                items.append("".join(current))
                current = []
            else:
                current.append(char)
        elif char in ('"', "'"):
            in_quotes = True
            quote_char = char
            current = []
        elif char == ",":
            token = "".join(current).strip()
            if token:
                items.append(token)
            current = []
        else:
            current.append(char)

    token = "".join(current).strip()
    if token:
        items.append(token)
    return items


def _parse_yaml_subset(text: str) -> dict[str, Any]:
    """Parse simple ``key: value`` YAML lines into a dict."""
    result: dict[str, Any] = {}
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.strip()
        if not stripped:
            index += 1
            continue
        match = re.match(r"^([\w][\w_]*)\s*:\s*(.*)", stripped)
        if not match:
            raise ValueError(f"invalid YAML line: {stripped!r}")
        key = match.group(1)
        raw_value = match.group(2)
        if raw_value:
            result[key] = _parse_yaml_value(raw_value)
            index += 1
            continue

        items: list[Any] = []
        index += 1
        while index < len(lines):
            candidate = lines[index]
            candidate_stripped = candidate.strip()
            if not candidate_stripped:
                index += 1
                continue
            item_match = re.match(r"^\s*-\s+(.*)", candidate)
            if item_match:
                items.append(_parse_yaml_value(item_match.group(1)))
                index += 1
                continue
            break
        result[key] = items if items else ""
    return result


def _is_frontmatter_boundary(lines: list[str], index: int) -> bool:
    """Check if ``lines[index]`` (a ``---`` line) opens a new frontmatter block.

    Requires at least one ``key: value`` line before the next ``---`` closer.
    """
    candidate_lines: list[str] = []
    for j in range(index + 1, len(lines)):
        stripped = lines[j].strip()
        if stripped == "---":
            try:
                metadata = _parse_yaml_subset("\n".join(candidate_lines))
            except ValueError:
                return False
            return bool(metadata)
        candidate_lines.append(lines[j])
    return False


def parse_frontmatter(text: str) -> tuple[dict[str, Any], str]:
    """Parse a single frontmatter document.

    Returns ``(metadata_dict, body_string)``.
    """
    stripped = text.strip()
    if not stripped.startswith("---"):
        # Tolerate preamble text before the first ``---`` delimiter.
        idx = stripped.find("\n---\n")
        if idx == -1:
            idx = stripped.find("\n---")
        if idx >= 0:
            stripped = stripped[idx + 1 :]
        else:
            raise ValueError("text does not start with frontmatter delimiter")

    lines = stripped.split("\n")
    closing = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            closing = i
            break

    if closing is None:
        raise ValueError("no closing frontmatter delimiter found")

    yaml_text = "\n".join(lines[1:closing])
    body = "\n".join(lines[closing + 1 :]).strip()
    metadata = _parse_yaml_subset(yaml_text)
    return metadata, body


def parse_multi_document(text: str) -> list[tuple[dict[str, Any], str]]:
    """Parse multiple frontmatter documents.

    Each document is a ``---``-delimited YAML block optionally followed by
    a markdown body.  Code-fenced ``---`` lines are not treated as
    delimiters.

    Returns a list of ``(metadata_dict, body_string)`` tuples.
    """
    stripped = text.strip()
    if not stripped.startswith("---"):
        raise ValueError("text does not start with frontmatter delimiter")

    lines = stripped.split("\n")
    documents: list[tuple[dict[str, Any], str]] = []

    state = "seeking"  # seeking | in_yaml | in_body
    yaml_lines: list[str] = []
    body_lines: list[str] = []
    yaml_text: str | None = None
    in_code_fence = False

    for i, line in enumerate(lines):
        line_stripped = line.strip()

        if state == "seeking":
            if line_stripped == "---":
                state = "in_yaml"
                yaml_lines = []
            continue

        if state == "in_yaml":
            if line_stripped == "---":
                yaml_text = "\n".join(yaml_lines)
                state = "in_body"
                body_lines = []
                in_code_fence = False
            else:
                yaml_lines.append(line)
            continue

        if state == "in_body":
            if line_stripped.startswith("```"):
                in_code_fence = not in_code_fence
                body_lines.append(line)
                continue

            if not in_code_fence and line_stripped == "---":
                if _is_frontmatter_boundary(lines, i):
                    assert yaml_text is not None
                    documents.append(
                        (_parse_yaml_subset(yaml_text), "\n".join(body_lines).strip())
                    )
                    yaml_text = None
                    state = "in_yaml"
                    yaml_lines = []
                    continue

            body_lines.append(line)
            continue

    # Finalize last document
    if yaml_text is not None:
        documents.append(
            (_parse_yaml_subset(yaml_text), "\n".join(body_lines).strip())
        )

    if not documents:
        raise ValueError("no frontmatter blocks found")

    return documents
