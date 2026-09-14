"""How a pull request body opens, read once for everything that cares.

A body opens with one paragraph and no heading: why the pull request exists,
what it solves, then what changed. The readiness gate refuses a body that opens
with anything else, and the review page reads that paragraph as its plain
language — so the definition lives here rather than twice, and what the page
shows a reader is what the gate checked.

Above the paragraph a body may carry lines that are not it: the contributor
runtime's persona byline, and the `Review page: <url>` line the generator
inserts. Those are skipped. HTML comments are skipped too, which is what makes
an unedited template fail: its guidance is a comment, and the first thing a
reader sees is the `## What` heading under it.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# Kinds an opening block can be. Everything but `prose` is a refusal, and the
# name is what the failure message says the body opened with.
PROSE = "prose"
OPENING_NAMES: dict[str, str] = {
    "heading": "a heading",
    "list": "a list",
    "table": "a table",
    "fence": "a code block",
    "quote": "a quotation",
    "markup": "an HTML block",
    "empty": "nothing",
}

# A browser ends a comment at `--!>` as well as at `-->`, so a comment's extent
# here is the extent a reader's browser gives it. The review page reads comments
# through this same pattern.
COMMENT_RE = re.compile(r"<!--.*?(?:-->|--!>)", re.DOTALL)
# A whole line in italics is a byline: `*April Clearwater, Application Lead*`.
BYLINE_RE = re.compile(r"(?:\*[^*\s][^*]*\*|_[^_\s][^_]*_)")
# A labeled link on its own line: `Review page: https://…`.
LINK_LINE_RE = re.compile(r"(?i)^[A-Za-z][A-Za-z /-]{0,24}:\s*<?https?://\S+>?$")
# CommonMark: an ATX heading is up to three spaces of indent, one to six `#`,
# then a space/tab or end of line — an empty heading (`###` with no text) is
# still a heading. Four spaces of indent is a code block, not a heading, and
# indented code can't interrupt a paragraph, so it stays out of this pattern.
HEADING_RE = re.compile(r"^ {0,3}#{1,6}(?:[ \t]|$)")

_KIND_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("heading", HEADING_RE),
    ("fence", re.compile(r"^(?:```|~~~)")),
    ("list", re.compile(r"^\s*(?:[-*+]\s|\d+[.)]\s)")),
    ("table", re.compile(r"^\s*\|")),
    ("quote", re.compile(r"^\s*>")),
    # A tag, comment, declaration or processing instruction. An autolink such as
    # `<https://…>` is not one: it is a paragraph that opens on a link.
    ("markup", re.compile(r"^\s*<(?:[!?/]|[A-Za-z][A-Za-z0-9-]*(?:[\s/>]|$))")),
)


@dataclass(frozen=True)
class Opening:
    """The first thing a reader of this body sees."""

    kind: str
    text: str

    @property
    def is_paragraph(self) -> bool:
        return self.kind == PROSE


def visible(body: str) -> str:
    """The body with every HTML comment gone — what a reader actually sees."""
    return COMMENT_RE.sub("", body or "")


def _skippable(line: str) -> bool:
    stripped = line.strip()
    return bool(BYLINE_RE.fullmatch(stripped) or LINK_LINE_RE.match(stripped))


def _kind(line: str) -> str:
    for name, pattern in _KIND_PATTERNS:
        if pattern.match(line):
            return name
    return PROSE


def read_opening(body: str) -> Opening:
    """The body's opening block: a paragraph, or what stands where one should.

    The paragraph runs from its first line to the blank line or heading that
    ends it, joined into one string — a paragraph wrapped over four lines in
    the source is one paragraph to a reader and is one here.
    """
    lines = visible(body).splitlines()
    index = 0
    while index < len(lines) and (not lines[index].strip() or _skippable(lines[index])):
        index += 1
    if index >= len(lines):
        return Opening(kind="empty", text="")

    kind = _kind(lines[index])
    if kind != PROSE:
        return Opening(kind=kind, text="")

    collected: list[str] = []
    for line in lines[index:]:
        if not line.strip() or HEADING_RE.match(line):
            break
        collected.append(line.strip())
    return Opening(kind=PROSE, text=" ".join(collected).strip())


def leading_paragraph(body: str) -> str:
    """The opening paragraph, or empty when the body opens with something else."""
    return read_opening(body).text
