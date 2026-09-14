#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Parse YAML frontmatter from agent output.

Handles a subset of YAML: strings (bare/quoted), integers, booleans,
null, and inline lists. Complex review fields additionally support bounded
block-form mappings/lists or JSON flow values. No external dependencies.

Functions:
    parse_frontmatter(text) -> (metadata, body)
    parse_multi_document(text) -> [(metadata, body), ...]
"""

from __future__ import annotations

import json
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


def _ends_with_unescaped_quote(s: str) -> bool:
    """Return True if *s* ends with an unescaped ``"``."""
    if not s.endswith('"'):
        return False
    preceding = s[:-1]
    n_backslashes = len(preceding) - len(preceding.rstrip("\\"))
    return n_backslashes % 2 == 0


def _collect_multiline_quoted(
    opening: str, lines: list[str], index: int, key: str
) -> tuple[str, int]:
    """Collect a multi-line quoted string value.

    *opening* is the first line's content after the ``"`` opener.
    Reads continuation lines from *lines* starting at *index* until a
    line ending with an unescaped ``"`` is found.

    Returns ``(collected_value, next_index)``.
    """
    parts = [opening]
    while index < len(lines):
        rstripped = lines[index].rstrip()
        if _ends_with_unescaped_quote(rstripped):
            parts.append(rstripped[:-1])
            return "\n".join(parts), index + 1
        parts.append(lines[index])
        index += 1
    raise ValueError(f"unterminated multi-line quoted string for key {key!r}")


def _collect_block_list(lines: list[str], index: int) -> tuple[list[Any], int]:
    """Collect indented ``- value`` items into a list.

    Returns ``(items, next_index)``.
    """
    items: list[Any] = []
    while index < len(lines):
        if not lines[index].strip():
            index += 1
            continue
        item_match = re.match(r"^\s*-\s+(.*)", lines[index])
        if not item_match:
            break
        items.append(_parse_yaml_value(item_match.group(1)))
        index += 1
    return items, index


REVIEW_METADATA_FIELDS = {"image_observations", "review_findings"}


def _parse_review_metadata(text: str) -> Any:
    """Decode only the complex review contract, without widening legacy YAML.

    Block mappings/lists, scalar values, and JSON flow values suffice for the
    runtime's review template. Anchors, tags, and arbitrary YAML objects are
    not interpreted. Reject ambiguous keys/indentation and bound recursion.
    """
    if len(text.encode()) > 65536 or len(text.splitlines()) > 256:
        raise ValueError("review metadata exceeds size limit")
    records = []
    for line in text.splitlines():
        if not line.strip():
            continue
        prefix = line[:len(line) - len(line.lstrip())]
        if "\t" in prefix:
            raise ValueError("tabs are not supported in review metadata indentation")
        records.append((len(prefix), line.strip()))

    def json_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate review metadata key")
            result[key] = value
        return result

    def check_depth(value: Any, depth: int = 0) -> None:
        if depth > 6:
            raise ValueError("review metadata exceeds nesting limit")
        children = value.values() if isinstance(value, dict) else value if isinstance(value, list) else []
        for child in children:
            check_depth(child, depth + 1)

    def scalar(value: str) -> Any:
        if value.startswith(("[", "{")):
            try:
                parsed = json.loads(value, object_pairs_hook=json_pairs)
                check_depth(parsed)
                return parsed
            except (ValueError, RecursionError) as error:
                raise ValueError("invalid or oversized JSON review flow value") from error
        return _parse_yaml_value(value)

    def block(index: int, indent: int, depth: int) -> tuple[Any, int]:
        if depth > 6:
            raise ValueError("review metadata exceeds nesting limit")
        sequence = records[index][1].startswith("- ")
        result: Any = [] if sequence else {}
        while index < len(records):
            current_indent, content = records[index]
            if current_indent < indent:
                break
            if current_indent != indent:
                raise ValueError("inconsistent review metadata indentation")
            if sequence:
                if not content.startswith("- "):
                    raise ValueError("mixed review metadata list and mapping")
                item = content[2:]
                if re.match(r"^[\w]+:\s|^[\w]+:$", item):
                    # Parse a list item's first key and its following keys as
                    # one mapping at the item's content indentation.
                    records[index] = (indent + 2, item)
                    value, index = block(index, indent + 2, depth + 1)
                else:
                    value, index = scalar(item), index + 1
                result.append(value)
                continue
            match = re.fullmatch(r"([\w]+):(?:\s+(.*)|\s*)", content)
            if not match:
                raise ValueError("invalid review metadata mapping")
            key, value = match.group(1), match.group(2) or ""
            if key in result:
                raise ValueError("duplicate review metadata key")
            index += 1
            if not value and index < len(records) and records[index][0] > indent:
                result[key], index = block(index, records[index][0], depth + 1)
            else:
                result[key] = scalar(value)
        return result, index

    if not records:
        return ""
    if len(records) == 1 and records[0][1].startswith(("[", "{")):
        return scalar(records[0][1])
    result, end = block(0, records[0][0], 0)
    if end != len(records):
        raise ValueError("inconsistent review metadata indentation")
    return result


def _collect_review_metadata(lines: list[str], index: int, indent: int, raw: str) -> tuple[Any, int]:
    if raw:
        return _parse_review_metadata(raw), index
    end = index
    while end < len(lines):
        line = lines[end]
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        end += 1
    return _parse_review_metadata("\n".join(lines[index:end])), end


def _parse_yaml_subset(text: str) -> dict[str, Any]:
    """Parse simple ``key: value`` YAML lines into a dict.

    Supports single-line values, multi-line quoted strings, and
    block lists (``- item``).
    """
    result: dict[str, Any] = {}
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        stripped = lines[index].strip()
        if not stripped:
            index += 1
            continue

        match = re.match(r"^([\w][\w_]*)\s*:\s*(.*)", stripped)
        if not match:
            raise ValueError(f"invalid YAML line: {stripped!r}")

        key = match.group(1)
        raw_value = match.group(2)
        indent = len(lines[index]) - len(lines[index].lstrip())
        index += 1

        if key in REVIEW_METADATA_FIELDS:
            if key in result:
                raise ValueError("duplicate review metadata field")
            result[key], index = _collect_review_metadata(lines, index, indent, raw_value)
            continue

        if not raw_value:
            # No inline value — expect a block list on subsequent lines.
            items, index = _collect_block_list(lines, index)
            result[key] = items if items else ""
            continue

        # Check for multi-line quoted string (opens with " but doesn't
        # close on this line).  rstrip so trailing whitespace after a
        # closing quote doesn't falsely trigger multi-line mode.
        trimmed = raw_value.rstrip()
        if trimmed.startswith('"') and not _ends_with_unescaped_quote(trimmed):
            result[key], index = _collect_multiline_quoted(
                trimmed[1:], lines, index, key
            )
            continue

        result[key] = _parse_yaml_value(raw_value)
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
