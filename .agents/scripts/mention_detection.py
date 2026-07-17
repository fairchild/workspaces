"""Single source of truth for agent @-slug mention detection across responder lanes.

Mention triage (scripts/agent-triage-request.py) dispatches on these slugs, and the
Factory comment responder (scripts/factory-responder-payload.py) stands down when one
is present, so both lanes must read a comment identically. Fenced code blocks and
inline code spans are stripped before matching: a slug quoted in backticks neither
fires triage nor suppresses the responder.
"""

from __future__ import annotations

import re
from collections.abc import Sequence

SUPPORTED_AGENTS = ("april-clearwater", "plat", "peter", "claude")
MENTION_PATTERNS = {
    agent: re.compile(
        rf"(?<![A-Za-z0-9_-])@{re.escape(agent)}(?![A-Za-z0-9_-])", re.IGNORECASE
    )
    for agent in SUPPORTED_AGENTS
}

_FENCE_LINE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")


def _strip_fenced_blocks(text: str) -> str:
    """Drop fenced code blocks the way GitHub renders them.

    A closing fence uses the same character and at least the opening run length,
    with nothing but whitespace after it. An unterminated fence swallows the rest
    of the text, matching rendered output. A backtick run followed by more
    backticks on the same line is an inline span, not a fence (CommonMark forbids
    backticks in a backtick fence's info string).
    """
    kept: list[str] = []
    fence_char = ""
    fence_len = 0
    for line in text.splitlines():
        match = _FENCE_LINE_RE.match(line)
        remainder = line[match.end() :] if match else ""
        if fence_len:
            closes = (
                match is not None
                and match.group(1)[0] == fence_char
                and len(match.group(1)) >= fence_len
                and not remainder.strip()
            )
            if closes:
                fence_char, fence_len = "", 0
            continue
        opens = match is not None and not (
            match.group(1)[0] == "`" and "`" in remainder
        )
        if opens:
            fence_char, fence_len = match.group(1)[0], len(match.group(1))
        else:
            kept.append(line)
    return "\n".join(kept)


def _strip_inline_code_spans(text: str) -> str:
    """Drop inline code spans: a backtick run closed by an equal-length run.

    Longer or shorter runs do not close a span, and spans do not cross blank
    lines, so a stray unmatched backtick stays literal and cannot hide mentions
    in later paragraphs. A linear scan, not a regex, so backtick floods in
    untrusted comment bodies cannot trigger pathological backtracking.
    """
    pieces: list[str] = []
    index = 0
    length = len(text)
    while index < length:
        run_start = text.find("`", index)
        if run_start == -1:
            pieces.append(text[index:])
            break
        pieces.append(text[index:run_start])
        run_end = run_start
        while run_end < length and text[run_end] == "`":
            run_end += 1
        run_len = run_end - run_start
        closer = "`" * run_len
        paragraph_end = text.find("\n\n", run_end)
        limit = length if paragraph_end == -1 else paragraph_end
        search = run_end
        close_at = -1
        while search < limit:
            found = text.find(closer, search, limit)
            if found == -1:
                break
            found_end = found
            while found_end < length and text[found_end] == "`":
                found_end += 1
            if found_end - found == run_len:
                close_at = found
                break
            search = found_end
        if close_at == -1:
            pieces.append(closer)
            index = run_end
        else:
            pieces.append(" ")
            index = close_at + run_len
    return "".join(pieces)


def strip_code_sections(text: str) -> str:
    return _strip_inline_code_spans(_strip_fenced_blocks(text or ""))


def find_agent_mentions(
    text: str, candidates: Sequence[str] = SUPPORTED_AGENTS
) -> list[str]:
    stripped = strip_code_sections(text)
    return [agent for agent in candidates if MENTION_PATTERNS[agent].search(stripped)]
