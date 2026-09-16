#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py==4.2.0"]
# ///
"""Validate PR readiness signals: the body contract every non-draft PR owes.

Two entry points, one `evaluate()`: CI feeds it the GitHub `pull_request`
event, and `--body-file` feeds it a body an author has not published yet, so
the same failures and the same wording arrive before `gh pr create` instead of
one CI round trip later. `--check-evidence-delivery` separately opts into a
read-only live PR/artifact check using Factory's shared delivery policy. It
reports laptop delivery, never Factory inspection or approval.

The `## Evidence Status` section is read two ways, and a pending line seen by
either one fails the gate. The written view matches the lines as an author
typed them; the rendered view parses the body as GitHub Flavored Markdown and
reads every line the page shows -- a list item, a paragraph, a table cell, a
sub-heading -- so an escape, a character reference or inline HTML around the
status token is resolved rather than hiding it (#1706), and a status outside a
list item is still a status (#1727). The two are combined as a conjunction of
refusals, never a vote: the rendered view can only add failures, so it cannot
pass a body the written view fails, and a shape only one of them sees is still
a shape the gate catches.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from markdown_it import MarkdownIt
from markdown_it.token import Token

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import pr_body
from release_policy import RELEASE_PATHS


DEFAULT_SURFACE = "desktop / web / agent-runtime / infra / docs"

# A floor, not a target: it refuses an opening like "Fixes the thing.", which is
# prose and says nothing of why the PR exists, and a short paragraph that does say
# it clears the floor. The example below carries the shape.
LEADING_PARAGRAPH_MIN_CHARS = 40

# Shown on failure as an example, not a block to paste and fill in: the shape is
# a paragraph, and a labelled skeleton is what produced the bodies this replaces.
LEADING_PARAGRAPH_EXAMPLE = """\
Decisions on the steward's board wait hours for a click: on 2026-09-13 nine pull
requests each waited eleven hours on one. This PR lets a decision be answered
from a macOS notification, so a tap and a board click are the same event
everywhere downstream. Off by default behind an experimental feature.
12 files, +1496 -13."""

# The authored PR body skeleton. Producers derive their sections from this
# file rather than from copied strings, so adding a field to the template
# reaches every generated body without a second edit.
PR_TEMPLATE_PATH = REPO_ROOT / ".github" / "pull_request_template.md"
GIT_TIMEOUT_SECONDS = 20

# Accepted spellings per required Mergeability field, canonical first. The
# gate's job is to prove the readiness *questions* were answered, not to
# enforce one label string — near-miss labels ("Residual risk:", "Scope:")
# kept failing substantively-complete PRs, so each field accepts the
# variants agents actually write.
FIELD_LABELS: dict[str, tuple[str, ...]] = {
    "Surface": ("Surface", "Scope"),
    "User-facing behavior changed": (
        "User-facing behavior changed",
        "User-facing behavior change",
        "User-facing behavior",
        "User-facing changes",
        "Behavior changed",
    ),
    "Non-happy paths considered": (
        "Non-happy paths considered",
        "Non-happy paths",
        "Edge cases",
        "Failure modes",
        "Error paths",
    ),
    "Residual risk or follow-up": (
        "Residual risk or follow-up",
        "Residual risks",
        "Residual risk",
        "Follow-ups",
        "Follow-up",
        "Risks",
        "Risk",
    ),
    "Release/ops preconditions": (
        "Release/ops preconditions",
        "Release preconditions",
        "Ops preconditions",
    ),
}

# Hint text per Mergeability field, keyed by the canonical label. This is the
# only place a field's example wording is hardcoded; which fields appear, and
# in what order, comes from `mergeability_field_labels()` reading the template
# — so a field added to the template shows up here with a generic fallback
# hint instead of silently vanishing from the paste-ready block.
FIELD_HINTS: dict[str, str] = {
    "Surface": f"<{DEFAULT_SURFACE} — plus what part>",
    "User-facing behavior changed": '<what changed, or "No">',
    "Non-happy paths considered": '<error paths / edge cases, or "n/a" with why>',
    "Release/ops preconditions": '<what must happen before/at release, or "None">',
    "Residual risk or follow-up": '<what could still break or is deferred, or "None">',
}
DOC_EVIDENCE_EXEMPT_SUFFIXES = (".md", ".mdx", ".markdown", ".txt")
DOC_EVIDENCE_EXEMPT_PREFIXES = ("docs/", "backlog/")


@dataclass(frozen=True)
class Result:
    failures: list[str]
    notices: list[str]

    @property
    def ok(self) -> bool:
        return not self.failures


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def load_json(path: str | None, default: Any) -> Any:
    if not path:
        return default
    with Path(path).open(encoding="utf-8") as file:
        return json.load(file)


# A body reads the way GitHub renders it. A CR or CRLF ends a line the way LF
# does. A heading may sit up to three spaces in, and four is a code block. A
# list item opens on `-`, `*`, `+`, or one to nine digits and `.` or `)`.
HEADING_INDENT = r" {0,3}"
LIST_MARKER = r"(?:[-*+]|[0-9]{1,9}[.)])"
LINE_ENDING_RE = re.compile(r"\r\n?")
# A status token is read however a reader sees it written: in code, bold or
# italics, or behind a task box (`- [ ] [pending-ci]`).
PENDING_STATUS_RE = re.compile(
    rf"(?im)^\s*{LIST_MARKER}\s*(?:\[[ x]\]\s*)?[`*_]*\[(?:blocked|pending-ci)\][`*_]*(?:\s|$)"
)
FENCE_OPENER_RE = re.compile(r" {0,3}(?P<run>`{3,}|~{3,})(?P<info>.*)")


def fence_opener(line: str) -> str:
    """The run of backticks or tildes a line opens a fence with, or "" when it opens none.

    Fences follow CommonMark: an opener sits at most three spaces in, since four
    is an indented code block, and a backtick opener's info string holds no
    backtick, so a line that opens on a code span opens nothing.
    """
    opener = FENCE_OPENER_RE.fullmatch(line)
    if not opener or (opener["run"].startswith("`") and "`" in opener["info"]):
        return ""
    return opener["run"]


def closes_fence(line: str, run: str) -> bool:
    """Whether a line closes the fence `run` opened: the same character, at least as long, at most three spaces in."""
    return re.fullmatch(rf" {{0,3}}{re.escape(run[0])}{{{len(run)},}}[ \t]*", line) is not None


def section_boundary_token(token: Token) -> bool:
    """Whether a parsed token starts something other than the section above it.

    A top-level heading of level 1 or 2, however the author made it -- hashes
    or an underline -- or a top-level dash rule. One definition for both of
    this gate's views: the rendered read asks it about the tokens it walks,
    and the written read asks it about the same tokens to find where to stop
    slicing. A rule of asterisks or underscores ends nothing, and an h3 is a
    sub-heading inside the section.

    The contributor skill's `is_section_boundary` is this rule, written there
    for its own reader; the cross-file test in `test_pr_readiness.py` fails
    when the two answer differently on any shape where they can.
    """
    if token.level != 0:
        return False
    if token.type == "hr":
        return token.markup.startswith("-")
    return token.type == "heading_open" and token.tag in {"h1", "h2"}


def extract_section(body: str, heading: str, *, strip: bool = True) -> str:
    """The body text under `## <heading>`, as written, up to where the section ends.

    The end is asked of the parser rather than matched line by line. A scanner
    reading `---` as a rule and nothing else took `----`, `- - -` and a line
    of dashes with trailing spaces for ordinary text, kept the text line of a
    setext heading inside the section it ends, read past a heading indented
    one space, and stopped at a heading the page shows inside an unterminated
    HTML block -- five shapes on which the gate and the contributor skill read
    different sections of the same body, each found by enumerating the two
    rules against each other rather than by a body that failed (#1734).

    Stripping takes the first line's indent along with the blank lines around
    the section, so a reader that cares about indentation asks for it
    unstripped.
    """
    # Every line ending GitHub stores. `evaluate` normalises the body it
    # reads; this repeats it because the function is called directly too, and
    # a CRLF body read here without it has no sections at all.
    normalized = LINE_ENDING_RE.sub("\n", body)
    start = re.search(rf"(?mi)^## {re.escape(heading)}\n", normalized)
    if not start:
        return ""
    lines = normalized.split("\n")
    heading_line = normalized[: start.start()].count("\n")
    tokens = MARKDOWN.parse(normalized)
    stop = next(
        (
            token.map[0]
            for token in tokens
            if token.map and token.map[0] > heading_line and section_boundary_token(token)
        ),
        len(lines),
    )
    section = "\n".join(lines[heading_line + 1 : stop])
    return section.strip() if strip else section


# GitHub renders a PR body as GitHub Flavored Markdown, and a status line
# matched by pattern is not always the line a reader sees: `- \[pending-ci]`,
# `- &#91;pending-ci&#93;` and `- <span>[pending-ci]</span>` each render as a
# visible `[pending-ci]` item and none of them match `PENDING_STATUS_RE`
# (#1706). This second reading takes the section as rendered, so the escape is
# resolved, the references decode and the tags show nothing.
#
# The parser is CommonMark plus the two GitHub constructs a status line can
# meet -- a table, whose cell is a line a reader sees, and strikethrough, which
# withdraws one (#1727). The contributor skill's `_helpers` defines the same
# parser for the owner read of this same section. It is written twice rather
# than imported once: this gate runs on every PR in the repo from its own PEP
# 723 pin, and importing a skill's private module would let a change inside
# that directory stop the gate repo-wide and would put that directory on
# `sys.path` for every run, where today only `--check-evidence-delivery`
# reaches it. `ParserDefinitionTests` fails when the two lines drift.
MARKDOWN = MarkdownIt("commonmark").enable(["table", "strikethrough"])
# CommonMark has no task list, so `- [x] ` reaches the rendered text as the
# characters `[x] ` in front of the status token -- the same optional box the
# written view allows for, read here as text rather than as a box. A list
# marker can reach the text the same way: a line the parser did not model as a
# list item carries its own marker as characters, which is what a bulleted row
# of a table does -- `- [blocked] | x |` above a delimiter row is one table
# whose first cell reads `- [blocked]`. Marking it optional here keeps a
# reader's view of that cell and the gate's the same (#1727).
RENDERED_PENDING_RE = re.compile(
    rf"(?i)^(?:{LIST_MARKER}\s*)?(?:\[[ x]\]\s*)?\[(?:blocked|pending-ci)\](?:\s|$)"
)


def rendered_inline_text(children: list[Token] | None) -> str:
    """Inline tokens as the text GitHub renders them.

    The parser has already resolved a backslash escape and decoded a character
    reference, so both arrive as ordinary text. Inline HTML renders nothing of
    its own and contributes nothing here; a code span contributes its content
    without the backticks, the way ``- `[pending-ci]` `` reads as a status
    line; and a break arrives as a newline, because GitHub renders a break in a
    pull request body as a line break -- `POST /markdown` in `gfm` mode closes
    the line at `<br>` for a plain newline inside a list item as well as for a
    trailing backslash. The caller splits there, so what one list item renders
    as two lines is read as two.

    Strikethrough keeps its tildes, the reading `evidence.py` gives it: a
    struck-out status is not the status, and `~~[blocked]~~` in front of a line
    is a line a reader sees withdrawn. Dropping them instead would make the
    gate refuse a line the owner read accepts, which is the disagreement
    between the two readers this parser exists to end.
    """
    parts: list[str] = []
    for token in children or []:
        if token.type == "html_inline":
            continue
        if token.type in {"s_open", "s_close"}:
            parts.append("~~")
            continue
        parts.append("\n" if token.type in {"softbreak", "hardbreak"} else token.content)
    return "".join(parts)


def rendered_status_lines(body: str) -> list[str]:
    """The text of every line a reader sees under `## Evidence Status`.

    A line is what the page puts on one: an inline run the parser models -- a
    list item, a paragraph, a table cell, a sub-heading, a line inside a quote
    -- cut at every break it holds, since one item carrying a break renders as
    two lines and a status on the second is as visible as one on the first.
    Reading only list items let a visible `[blocked]` cell through the gate
    while GitHub rendered it (#1727), and the owner read in the contributor
    skill refuses a table, a paragraph, a quote and a sub-heading under this
    heading outright -- so every one of them is a line whose status a reader
    acts on. Code under the heading, fenced or indented, is a code block and
    has no inline of its own, which is what `split_fenced_blocks` says on the
    written side.

    The section is the one the written view reads, found by what renders rather
    than by what was typed: it opens at a top-level h2 whose rendered text is
    `Evidence Status`, in any letter case, and closes at the next top-level h1
    or h2 or dash rule -- the same boundaries `extract_section` reads (#1674). A rule of asterisks or underscores is not one of them, so the
    section runs past it here as it does there, and a line below it stays
    readable rather than falling into a gap between the two views. Every
    matching heading is read, since a body with two of them is already
    ambiguous (`evidence_status_heading_failure`) and reading both can only add
    a failure to one that stands.
    """
    tokens = MARKDOWN.parse(body)
    lines: list[str] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if not (
            token.type == "heading_open"
            and token.tag == "h2"
            and token.level == 0
            and " ".join(rendered_inline_text(tokens[index + 1].children).split()).casefold()
            == "evidence status"
        ):
            index += 1
            continue
        index += 3  # heading_open, its inline, heading_close
        while index < len(tokens):
            token = tokens[index]
            if section_boundary_token(token):
                break
            if token.type == "inline":
                lines.extend(
                    part.strip() for part in rendered_inline_text(token.children).split("\n")
                )
            index += 1
    return lines


def split_fenced_blocks(text: str) -> tuple[str, str | None]:
    """The text without its fenced code blocks, and the opening line of a fence left unclosed.

    A reader sees a fenced line as an example, not as status. An unclosed fence
    keeps its lines, so nothing after it goes unread.
    """
    kept: list[str] = []
    fenced: list[str] = []
    run = ""
    for line in text.split("\n"):
        if run:
            fenced.append(line)
            if closes_fence(line, run):
                fenced.clear()
                run = ""
        elif run := fence_opener(line):
            fenced.append(line)
        else:
            kept.append(line)
    if run:
        return "\n".join(kept + fenced), fenced[0].strip()
    return "\n".join(kept), None


def template_body(path: Path | None = None) -> str:
    try:
        return (path or PR_TEMPLATE_PATH).read_text(encoding="utf-8")
    except OSError:
        return ""


def mergeability_field_labels(path: Path | None = None) -> list[str]:
    """Field labels the PR template declares under `## Mergeability`, in order.

    Producers that seed a Mergeability block read the contract from here, so
    the template stays the one place a required field is added or renamed.
    """
    section = extract_section(template_body(path), "Mergeability")
    return [
        match.group("label").strip()
        for match in re.finditer(r"(?m)^[ \t]*[-*][ \t]*(?P<label>[^:\n]+):", section)
    ]


def mergeability_paste_block(path: Path | None = None) -> str:
    """The paste-ready Mergeability block CI and preflight hand out on failure.

    Built by walking the template-derived field list rather than a second
    hardcoded copy, so a field the template declares can never go missing
    from the block the gate itself tells people to paste — the bug that let
    this gate demand an answer its own guidance never asked for.
    """
    lines = ["## Mergeability", ""]
    for label in mergeability_field_labels(path):
        hint = FIELD_HINTS.get(label, "<fill in>")
        lines.append(f"- {label}: {hint}")
    return "\n".join(lines)


def leading_paragraph_failure(body: str) -> str | None:
    """Whether this body opens the way a reader needs it to.

    The first read of a PR is its opening, and a body that opened on `## Summary`
    spent that read on a heading and a bullet. What goes there now is one
    paragraph saying why the PR exists and what it solves. Anything else in that
    position — a heading, a list, a table, a fence, an unedited template whose
    guidance is an HTML comment — is what this refuses.
    """
    opening = pr_body.read_opening(body)
    if not opening.is_paragraph:
        found = pr_body.OPENING_NAMES.get(opening.kind, "something other than a paragraph")
        return (
            f"The body does not open with a paragraph; it opens with {found}. "
            "One paragraph, no heading above it, comes first: why this PR exists, "
            "what it solves, then what changed."
        )
    if len(opening.text) < LEADING_PARAGRAPH_MIN_CHARS:
        return (
            f"The opening paragraph is {len(opening.text)} characters, too short to say "
            "why this PR exists, what it solves, and what changed."
        )
    return None


def evidence_status_heading_failure(body: str) -> str | None:
    # Exact is `## Evidence Status` at column 0, in any letter case: the only
    # heading `extract_section` reads and the factory's writer can replace. One
    # indented up to three spaces renders the same and counts as a variant, so a
    # status line under it fails the gate instead of going unread.
    headings = re.findall(
        rf"(?im)^{HEADING_INDENT}#+[ \t]+Evidence[ \t]+Status(?:[ \t]+#+)?[ \t]*$",
        body,
    )
    exact_count = sum(
        re.fullmatch(r"(?i)## Evidence Status", heading) is not None for heading in headings
    )
    variant_count = len(headings) - exact_count
    if exact_count > 1 or variant_count:
        return (
            "Ambiguous Evidence Status headings; use at most one exact "
            "'## Evidence Status' heading and no variants."
        )
    return None


def field_value(section: str, label: str) -> str | None:
    """Value of a labeled line, tolerant of how the label is actually written.

    Accepts any registered synonym for the field, an optional list bullet,
    bold markers around the label, and ':' or '—' as the separator.
    """
    plain = section.replace("**", "")
    for variant in FIELD_LABELS.get(label, (label,)):
        pattern = re.compile(
            rf"(?im)^[ \t]*(?:[-*][ \t]*)?{re.escape(variant)}[ \t]*[:—][ \t]*(?P<value>.*)$"
        )
        if match := pattern.search(plain):
            return match.group("value").strip()
    return None


def is_blank_value(value: str | None, *, default: str | None = None) -> bool:
    if value is None:
        return True
    normalized = normalize(value)
    if not normalized or normalized in {"-", "n/a", "tbd", "todo", "pending"}:
        return True
    return default is not None and normalized == normalize(default)


def label_names(pr: dict[str, Any]) -> list[str]:
    return [item.get("name", "") for item in pr.get("labels", []) if isinstance(item, dict)]


def has_checked_box(body: str, label: str, *, rendered_only: bool = False) -> bool:
    # A box that holds a PR back is read as leniently as a pending line. A box
    # that excuses one from evidence counts only as GitHub renders it, with a
    # space or tab on each side of `[x]`.
    gap = r"[ \t]+" if rendered_only else r"\s*"
    return bool(re.search(rf"(?im)^\s*{LIST_MARKER}{gap}\[x\]{gap}{re.escape(label)}\b", body))


# A command someone can re-run, and what it printed. Either half alone is not
# a report: a command with no result is a plan, a result with no command is a
# claim nobody can check.
TEST_COMMAND_RE = re.compile(
    # A path-shaped command cannot carry a leading `\b`: nothing before the
    # `.` in `./scripts/foo.sh` is a word character, so the boundary never
    # holds and the alternative is unreachable. The word-initial names take
    # the boundary; the rest do not.
    r"(?i)(?:\b(?:swift\s+(?:test|build)|(?:pnpm|npm|yarn|bun)\s+(?:run\s+)?\S*test"
    r"|pytest|python3?\s+-m\s+(?:pytest|unittest)|uv\s+run|go\s+test|cargo\s+test"
    r"|xcodebuild\s+test|mise\s+run|make\s+test|bash\s+-n|actionlint|shellcheck"
    r"|swift-format|git\s+diff\s+--check|validate-release-changes)\b"
    r"|\./\S+\.(?:sh|py|ts|js)\b|\./scripts/\S+)"
)
TEST_RESULT_RE = re.compile(
    r"(?i)\b(?:pass(?:es|ed|ing)?|green|succeed(?:s|ed)?|ok|clean"
    # A count with no verdict beside it is not a result: "this patch changes
    # 12 files" sat in the window under a command and read as its output. The
    # verdict words above already carry every real report.
    r")\b"
    # A result is often reported as an absence -- "no lint errors", "zero
    # failures", "0 warnings" -- and those are what a linter prints when it
    # is happy.
    r"|\b(?:no|zero|0)\s+(?:\w+\s+){0,2}(?:errors?|failures?|warnings?)\b"
)
# A run that failed is not evidence that anything passed. "12 tests failed"
# carries a count and a test noun and was read as a result.
TEST_FAILURE_RE = re.compile(
    # `errors?` and `red` are ordinary words in a passing report -- "12 tests
    # passed, covering error handling" is not a failure -- so a failure noun
    # counts only where it is reporting a count or a status, and never where
    # the sentence says what the tests cover.
    r"(?i)(?<!covering )(?<!including )(?<!handling )(?<!for )(?<!about )"
    r"\bfail(?:s|ed|ing|ure|ures)?\b"
    r"|\b\d+\s+errors?\b|\berrors?\s*[=:]\s*[1-9]|\berrored\b"
    r"|\b(?:0|no)\s+tests?\b|\bcollected\s+0\b|\bno tests? ran\b"
    # A single-digit bound read `exit code 127` as a pass, and runners write
    # the number behind `code`, `status`, `with`, or nothing at all.
    r"|\bexit(?:ed|s)?\s*(?:with\s+)?(?:code|status)?\s*[:=]?\s*[1-9]\d*\b"
    r"|\bnon-?zero exit\b|\bstatus\s*[:=]\s*(?:error|failed|failure|red)\b"
    r"|\bprocess (?:completed|exited) with (?:exit )?(?:code|status) [1-9]\d*\b"
)
# A line that says the run did not happen. Without this, "`swift test` was
# not run" and a sentence several lines later mentioning a count read as a
# report of a passing run.
NOT_RUN_RE = re.compile(
    r"(?i)\b(?:not|never|couldn't|could not|cannot|can't|unable to|failed to|"
    r"didn't|did not|skipped?|skipping|pending|todo|to do)\b"
    # A plan is not a report. "We will run swift test after review" names a
    # command and, two lines down, a count of the tests the change adds.
    r"|\b(?:will|shall|going to|plan to|intend to|should|需)\s+(?:be\s+)?run\b"
    r"|\bonce\s+(?:ci|the\s+\w+)\s+(?:runs|finishes|completes)\b"
    r"|\bafter\s+(?:review|merge|approval)\b"
)
# Anything a person can see lives here. `WorkspaceManagerCore` and the CLI are
# Swift that renders nothing, so an image proves nothing about them. An image
# is evidence *of* what someone looks at; anywhere else it is a picture of
# text.
# All of `Sources/`, deliberately. `WorkspaceManagerCore` renders nothing
# itself but defines the labels, icons and colors the app draws, so a screenshot
# is real evidence about a change there -- and refusing a genuine app capture is
# a worse failure than accepting a picture of text on a Swift PR. The line this
# draws is against the agent scripts, the workflows and the docs.
# `WorkspaceManagerCLI` draws nothing, so an image proves nothing about it;
# `WorkspaceManagerCore` defines the labels and colors the app draws, so a
# real app capture is evidence about a change there.
NON_VISUAL_SOURCE_PREFIXES = ("Sources/WorkspaceManagerCLI/",)
VISUAL_SURFACE_PREFIXES = (
    "Sources/",
    "web/",
    "web-next/",
    "ios/",
    "prototypes/",
    "fixtures/ui-state/",
)
# A closing paren is required: `![x](https://` is a broken link, not evidence.
IMAGE_EVIDENCE_RE = re.compile(r"!\[[^\]\n]*\]\([^)\s]+\)")
# The extension ends the URL. `…/x.png.evil` is not a png.
IMAGE_LINK_RE = re.compile(
    r"(?i)https?://[^\s)\]]+\.(?:png|jpe?g|gif|webp|svg|webm|mp4)"
    r"(?:[?#][^\s)\]]*)?(?=[\s)\]]|$)"
)
# The host, at the host's own position. A substring test would accept
# `https://evil.example/evidence.cloudcompute.com/x.png` as an upload of ours.
# The scheme has to start the URL, not sit inside one:
# `https://evil.example/https://evidence.cloudcompute.com/x.txt` is somebody
# else's host with ours written in its path.
# Nothing that can carry a URL may precede the scheme:
# `https://evil.example/?next=https://evidence.cloudcompute.com/x.txt` is
# somebody else's host with ours in its query.
# Every character a URL can carry before ours, and none that only delimits
# one: a markdown link's `(` and `[` sit outside the URL, so excluding them
# would refuse the ordinary `[log](https://evidence...)` form.
_STORE_PREFIX = r"(?<![\w/.:=&?#~+%;,!$'*@-])"
EVIDENCE_STORE_RE = re.compile(
    rf"(?i){_STORE_PREFIX}https://evidence\.cloudcompute\.com/\S+"
)
EVIDENCE_STORE_LOG_RE = re.compile(
    rf"(?i){_STORE_PREFIX}https://evidence\.cloudcompute\.com/"
    r"[^\s)\]]+\.txt(?=[\s)\]]|$)"
)


# "no lint errors" and "zero failures" are pass phrasings that contain the
# words a failure is spelled with. Stripped before the failure search, they
# stop the failure pattern from swallowing the result pattern beside it --
# `TEST_RESULT_RE` accepts `no \w+ errors?`, and without this that branch was
# dead the moment a failure guard existed.
NEGATED_FAILURE_RE = re.compile(
    r"(?i)\b(?:no|zero|0|without|free of)\s+"
    r"(?:(?!errors?\b|failures?\b|fail(?:s|ed|ing)?\b|warnings?\b|regressions?\b)"
    r"\w+\s+){0,2}"
    r"(?:errors?|failures?|fail(?:s|ed|ing)?|warnings?|regressions?)\b"
)


def _reports_a_failure(text: str) -> bool:
    return bool(TEST_FAILURE_RE.search(NEGATED_FAILURE_RE.sub(" ", text)))


# How far past a command its output may sit. A fenced block of runner output
# with a blank line before it is the common shape, and it fits inside this.
NAMED_TEST_WINDOW_LINES = 8


def has_named_test_signal(body: str) -> bool:
    """A command and what it printed, in one breath.

    Matched within a bounded window under the command, not anywhere in the
    body: a planned `swift test` in one paragraph and the words "green status
    icon" in another are not a report of a run. The window skips blank lines
    and fences, which is ordinary formatting, and ends at a heading or the
    next command, which is where the next statement begins.
    """
    lines = body.splitlines()
    for index, line in enumerate(lines):
        if not TEST_COMMAND_RE.search(line):
            continue
        # A blank line, a fence, or a sentence of explanation between the
        # command and its output is ordinary formatting, so the window skips
        # those rather than ending on them. It ends at a heading or at the
        # next command, which is where the next statement begins.
        window = [line]
        for follower in lines[index + 1 : index + NAMED_TEST_WINDOW_LINES]:
            stripped = follower.strip()
            if stripped.startswith("#") or TEST_COMMAND_RE.search(follower):
                break
            if stripped and not stripped.startswith(("```", "~~~")):
                window.append(follower)
        joined = " ".join(window)
        # The guard reads the whole statement, not only its first line: the
        # window is what decides, so a "was not run" on the command line and a
        # count three lines down was read as a report of a passing run.
        if NOT_RUN_RE.search(joined):
            continue
        if TEST_RESULT_RE.search(joined) and not _reports_a_failure(joined):
            return True
    return False


def has_image_evidence(body: str) -> bool:
    return bool(IMAGE_EVIDENCE_RE.search(body) or IMAGE_LINK_RE.search(body))


def touches_a_visual_surface(files: list[str]) -> bool:
    return any(
        path.startswith(VISUAL_SURFACE_PREFIXES)
        and not path.startswith(NON_VISUAL_SOURCE_PREFIXES)
        for path in files
    )


def has_any_evidence(body: str, files: list[str] | None = None) -> bool:
    """Whether this body carries a signal that anything was verified.

    An image used to satisfy this on its own, for any change at all, which is
    what made rendering a test summary to an SVG worth doing. It now satisfies
    it only where there is something to see. Michael, 2026-09: "We will never
    again choose to create an svg of text just to have evidence. That was a
    reward hack I allowed to go through for a while."
    """
    visual = touches_a_visual_surface(files or [])
    return any(
        (
            has_named_test_signal(body),
            bool(EVIDENCE_STORE_LOG_RE.search(body)),
            has_image_evidence(body) and visual,
            bool(EVIDENCE_STORE_RE.search(body)) and visual,
            has_checked_box(body, "Not a testable change", rendered_only=True),
        )
    )


def changed_release_files(files: list[str]) -> list[str]:
    return [path for path in files if path in RELEASE_PATHS]


def is_docs_only(files: list[str]) -> bool:
    return bool(files) and all(
        path.endswith(DOC_EVIDENCE_EXEMPT_SUFFIXES)
        or path.startswith(DOC_EVIDENCE_EXEMPT_PREFIXES)
        for path in files
    )


def evaluate(pr: dict[str, Any], files: list[str]) -> Result:
    # Every `^`, `$` and `\n` below reads a bare LF.
    body = LINE_ENDING_RE.sub("\n", pr.get("body") or "")
    title = pr.get("title") or ""
    labels = label_names(pr)
    failures: list[str] = []
    notices: list[str] = []

    if pr.get("draft"):
        notices.append("Draft PR: readiness gate is advisory until the PR is ready for review.")
        return Result(failures, notices)

    if paragraph_failure := leading_paragraph_failure(body):
        failures.append(paragraph_failure)

    mergeability = extract_section(body, "Mergeability")
    if not mergeability:
        failures.append("Missing ## Mergeability section from the PR body.")
    else:
        required = {
            "Surface": DEFAULT_SURFACE,
            "User-facing behavior changed": None,
            "Non-happy paths considered": None,
            "Residual risk or follow-up": None,
        }
        for field, default in required.items():
            value = field_value(mergeability, field)
            if is_blank_value(value, default=default):
                failures.append(f"Mergeability field is empty or still default: {field}.")

    blocking_labels = sorted(label for label in labels if label.startswith("blocked:"))
    if blocking_labels:
        failures.append(f"Blocking label present: {', '.join(blocking_labels)}.")

    if has_checked_box(body, "Blocked on evidence"):
        failures.append("PR is checked as blocked on evidence.")

    if heading_failure := evidence_status_heading_failure(body):
        failures.append(heading_failure)
    status_section = extract_section(body, "Evidence Status", strip=False)
    evidence_status, unclosed_fence = split_fenced_blocks(status_section)
    if unclosed_fence:
        failures.append(
            f'Evidence Status opens a code fence that never closes: "{unclosed_fence}". '
            "Close it so the status lines after it are read."
        )
    if PENDING_STATUS_RE.search(evidence_status) or any(
        RENDERED_PENDING_RE.match(line) for line in rendered_status_lines(body)
    ):
        failures.append("Requested evidence is blocked or still pending CI.")

    if re.search(r"(?i)\bdo not merge(?:\s+this\s+pr|\s+until|\b)", f"{title}\n{body}"):
        failures.append("PR text contains a merge-stop instruction.")

    if not has_any_evidence(body, files) and not is_docs_only(files):
        if has_image_evidence(body) and not touches_a_visual_surface(files):
            failures.append(
                "The only evidence in the PR body is an image, and this change is not one "
                "anyone looks at. State the command you ran and the line it printed."
            )
        else:
            failures.append("No test/evidence signal found in PR body.")

    release_files = changed_release_files(files)
    if release_files:
        release_preconditions = field_value(mergeability, "Release/ops preconditions")
        if is_blank_value(release_preconditions):
            failures.append(
                "Release-sensitive files changed; fill 'Release/ops preconditions' in the PR body."
            )

        if re.search(r"(?i)(secret|credential).{0,80}(must|need|required).{0,80}before merging", body):
            failures.append(
                "Release PR says secrets/credentials must be added before merging; use blocked:secrets until complete."
            )

        validation = extract_section(body, "Validation")
        if not re.search(r"(?i)(validate-release-changes|bash -n|actionlint|workflow syntax)", validation):
            failures.append(
                "Release-sensitive files changed; validation should include validate-release-changes, bash -n, actionlint, or workflow syntax proof."
            )

    return Result(failures, notices)


COMMENT_MARKER = "<!-- pr-readiness-gate -->"

EVIDENCE_HINT = (
    "the command you ran and the line it printed (`swift test` — `Test run with 1992 "
    "tests passed`), an uploaded `.txt` log, a screenshot or recording for a change "
    "someone looks at, or a checked `- [x] Not a testable change` box"
)


def guidance_markdown(result: Result) -> str:
    """What failed, and exactly what to paste to fix it.

    The gate's failures used to surface only in the Actions log, so every
    author rediscovered the expected format by archaeology. This turns a
    failure into a self-correcting loop — agents and humans both see the
    missing pieces, on the PR itself in CI and on stdout in preflight.
    """
    if result.ok:
        return "✅ **PR readiness gate passed.**\n"
    lines = ["⚠️ **PR readiness gate failed** — this PR body is missing readiness signals:", ""]
    lines += [f"- {failure}" for failure in result.failures]
    if any("paragraph" in failure for failure in result.failures):
        lines += [
            "",
            "The body opens with one paragraph and no heading — why the PR exists, what it",
            "solves, then what changed and how big it is. Here is the shape by example; it",
            "is not a block to paste and fill in:",
            "",
            "```markdown",
            LEADING_PARAGRAPH_EXAMPLE,
            "```",
        ]
    if any("Mergeability" in failure for failure in result.failures):
        lines += [
            "",
            "Paste and fill this block (labels are matched tolerantly — common synonyms,",
            "bold, and `—` separators are accepted; answers must not be blank/n-a-only):",
            "",
            "```markdown",
            mergeability_paste_block(),
            "```",
        ]
    if any("evidence signal" in failure for failure in result.failures):
        lines += ["", f"Evidence is satisfied by {EVIDENCE_HINT}."]
    lines += [
        "",
        "_Full template: `.github/pull_request_template.md` — check a body before you push it with "
        "`uv run --script scripts/pr-readiness.py --body-file <path>`. In CI this comment updates "
        "automatically on the next push or body edit._",
    ]
    return "\n".join(lines) + "\n"


def comment_markdown(result: Result) -> str:
    """The sticky PR comment: the same guidance, keyed by an upsert marker."""
    return f"{COMMENT_MARKER}\n{guidance_markdown(result)}"


def emit(result: Result) -> None:
    for notice in result.notices:
        print(f"::notice::{notice}" if os.environ.get("GITHUB_ACTIONS") else f"NOTICE: {notice}")

    if result.failures:
        print("PR readiness failed:")
        for failure in result.failures:
            prefix = "::error::" if os.environ.get("GITHUB_ACTIONS") else "ERROR:"
            print(f"{prefix}{failure}")
    else:
        print("PR readiness passed.")

    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary_path).open("a", encoding="utf-8") as summary:
            summary.write("## PR Readiness\n\n")
            if result.ok:
                summary.write("- Status: pass\n")
            else:
                summary.write("- Status: fail\n")
                for failure in result.failures:
                    summary.write(f"- {failure}\n")
            for notice in result.notices:
                summary.write(f"- Notice: {notice}\n")

    # The workflow posts this as a sticky PR comment (see pr-readiness.yml).
    if comment_path := os.environ.get("READINESS_COMMENT_PATH"):
        Path(comment_path).write_text(comment_markdown(result), encoding="utf-8")


def git_changed_files(base: str) -> list[str]:
    """Paths this branch would put in the PR: committed against `base`, plus
    anything still dirty in the working tree."""
    files: list[str] = []

    def collect(args: list[str]) -> str:
        try:
            done = subprocess.run(
                ["git", *args],
                capture_output=True,
                text=True,
                cwd=REPO_ROOT,
                timeout=GIT_TIMEOUT_SECONDS,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return ""
        return done.stdout if done.returncode == 0 else ""

    def add(path: str) -> None:
        path = path.strip().strip('"')
        if path and path not in files:
            files.append(path)

    for line in collect(["status", "--porcelain"]).splitlines():
        if len(line) > 3:
            path = line[3:]
            add(path.split(" -> ", 1)[1] if " -> " in path else path)
    for ref in (f"origin/{base}", base):
        committed = collect(["diff", "--name-only", f"{ref}...HEAD"])
        if committed.strip():
            for line in committed.splitlines():
                add(line)
            break
    return files


def body_file_pr(path: Path, *, title: str, labels: list[str]) -> dict[str, Any]:
    return {
        "title": title,
        "body": path.read_text(encoding="utf-8"),
        "draft": False,
        "labels": [{"name": name} for name in labels],
    }


def evidence_delivery_modules():
    """Load network/image dependencies only for the explicit delivery command."""
    contributor_scripts = REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts"
    if str(contributor_scripts) not in sys.path:
        sys.path.insert(0, str(contributor_scripts))
    import github_state
    import review_evidence

    return github_state, review_evidence


def check_evidence_delivery(pr_number: int, *, expected_head: str = "") -> int:
    """Exercise Factory's bounded fetch policy locally, then discard staged files.

    This command never runs the reviewer, posts a receipt, or changes PR state.
    Live head/base/body revalidation prevents a download from certifying stale
    PR inputs. Required-check facts remain facts, not an approval decision.
    """
    github_state, review_evidence = evidence_delivery_modules()
    env = os.environ.copy()
    owner, name = github_state.repo_owner_name(env)
    report: dict[str, Any] = {
        "scope": "local_evidence_delivery",
        "repository": f"{owner}/{name}",
        "pr_number": pr_number,
        "factory_inspection": "not_performed",
        "review_approval": "not_evaluated",
    }
    prepared = None
    try:
        pr = github_state.fetch_detailed_pull_request(owner, name, pr_number, env)
        if pr is None:
            report.update(status="unavailable", reason_code="pr_unavailable")
            return 1
        checks = github_state.fetch_review_checks(pr_number, env)
        requested_evidence = []
        issue_number, _ = github_state.extract_pr_issue_reference(str(pr.get("body", "")))
        if issue_number is not None:
            issue = github_state.fetch_detailed_issue(owner, name, issue_number, env)
            if issue is None:
                report.update(status="unavailable", reason_code="requested_evidence_unavailable")
                return 1
            requested_evidence, contract_refusal = github_state.requested_evidence_contract(
                str(issue.get("body", ""))
            )
            if contract_refusal is not None:
                # Delivery over a contract that cannot be read would prepare
                # evidence for the items that survived the cut and call the
                # PR delivered; the reason names the line to move.
                report.update(
                    status="unavailable",
                    reason_code="requested_evidence_unreadable",
                    reason=contract_refusal,
                )
                return 1
        prepared = review_evidence.prepare_review_evidence(
            pr, checks, REPO_ROOT, expected_head=expected_head,
            requested_evidence=requested_evidence,
        )
        if prepared.status == "ready":
            current = github_state.fetch_detailed_pull_request(owner, name, pr_number, env)
            if current is None:
                report.update(status="unavailable", reason_code="pr_unavailable")
                return 1
            for field, reason in (("headRefOid", "stale_head"), ("baseRefOid", "stale_base"),
                                  ("body", "invalid_evidence")):
                if current.get(field) != pr.get(field):
                    prepared.fail(review_evidence.EvidencePreparationError(reason))
                    break
        report.update(
            status="delivered" if prepared.status == "ready" and prepared.artifacts else (
                "no_images_selected" if prepared.status == "ready" else "unavailable"
            ),
            preparation=prepared.outcome(),
            required_checks=checks,
            artifacts=[
                {key: value for key, value in artifact.items() if key not in {"local_path", "author_claim"}}
                for artifact in prepared.artifacts
            ],
            note="Staged files are removed after this local check. Factory must independently deliver and inspect the images.",
        )
        return 0 if prepared.status == "ready" else 1
    finally:
        if prepared is not None:
            prepared.cleanup()
        print(json.dumps(report, indent=2, sort_keys=True))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--changed-files", help="JSON file containing a list of changed file paths.")
    parser.add_argument(
        "--body-file",
        help=(
            "Preflight a PR body from a local file, before `gh pr create`. Runs the "
            "same checks CI runs and reports the same failures. Start from "
            ".github/pull_request_template.md."
        ),
    )
    parser.add_argument(
        "--check-evidence-delivery", type=int, metavar="PR",
        help="Opt in to live read-only evidence delivery for an existing PR; does not inspect images or approve review.",
    )
    parser.add_argument(
        "--expected-head", default="", metavar="SHA",
        help="Require this head SHA with --check-evidence-delivery.",
    )
    parser.add_argument("--title", default="", help="PR title to check alongside --body-file.")
    parser.add_argument(
        "--label",
        action="append",
        default=[],
        metavar="NAME",
        help="Label the PR will carry; repeatable. Only meaningful with --body-file.",
    )
    parser.add_argument(
        "--base",
        default="main",
        help="Base branch --body-file diffs against to infer changed files (default: main).",
    )
    args = parser.parse_args(argv)
    if args.check_evidence_delivery is not None:
        if args.check_evidence_delivery <= 0:
            parser.error("--check-evidence-delivery requires a positive PR number")
        if (args.body_file or args.changed_files or args.label or args.title or args.base != "main"
                or any(arg == "--event" or arg.startswith("--event=") for arg in argv)):
            parser.error("--check-evidence-delivery is separate from body/event checks")
    elif args.expected_head:
        parser.error("--expected-head requires --check-evidence-delivery")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.check_evidence_delivery is not None:
        return check_evidence_delivery(args.check_evidence_delivery, expected_head=args.expected_head)
    if args.body_file:
        body_path = Path(args.body_file)
        if not body_path.is_file():
            print(f"ERROR:No such body file: {body_path}")
            return 2
        pr = body_file_pr(body_path, title=args.title, labels=args.label)
        files = load_json(args.changed_files, None)
        if files is None:
            files = git_changed_files(args.base)
            print(f"Preflight: {body_path} against {len(files)} changed file(s) vs {args.base}.")
    else:
        event = load_json(args.event, {})
        pr = event.get("pull_request") or event
        files = load_json(args.changed_files, [])
    result = evaluate(pr, files)
    emit(result)
    if args.body_file and not result.ok:
        print()
        print(guidance_markdown(result), end="")
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
