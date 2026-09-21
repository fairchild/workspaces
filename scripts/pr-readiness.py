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
sub-heading, the text of a raw HTML block -- so an escape, a character
reference or inline HTML around the status token is resolved rather than hiding
it (#1706), a status outside a list item is still a status (#1727), and one the
page prints from raw HTML is one too (#1736). The rendered view asks GitHub
itself where a line starts -- `POST /markdown` returns the HTML the pull
request page shows -- and keeps its own source model of that question as a
second reader beside the answer (#1745). Offline, tokenless or rate-limited,
the renderer goes unasked and the gate says so rather than passing quietly.

All of them are combined as a conjunction of refusals, never a vote: a reader
can only add failures, so none of them can pass a body another one fails, and
a shape only one of them sees is still a shape the gate catches.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import subprocess
import sys
import unicodedata
import urllib.error
import urllib.request
from dataclasses import dataclass
from html.parser import HTMLParser
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
# italics, or behind a task box (`- [ ] [pending-ci]`). One spelling of each
# piece for every reader below, because three copies of them drifted apart
# once already and the gap was the same in all three (#1771).
#
# WHICH READER TAKES WHICH PIECE IS A CRITERION, not a list -- and the axis it
# turns on is the LIST MARKER, not the wrapper:
#
#   A line shows a status when the token is the FIRST thing on it, after any
#   list marker, task box, and any run of delimiter characters or spaces.
#   What follows the token does not decide it: `[blocked]`, `**[blocked]:**`,
#   `[blocked][missing]` and `_[blocked]_x` all put the token in front of a
#   reader, and a reader scanning the section sees the same thing in each.
#   A line that mentions the token part-way along -- `the lane is [blocked]x
#   by nothing` -- is prose about a status rather than one.
#
#   The WRITTEN view (`PENDING_STATUS_RE`) reads the characters an author
#   typed, which is markdown, and in markdown a status bullet is a line that
#   opens a list item -- so the marker is REQUIRED there and nowhere else.
#
#   CODE is where the two views differ, and the difference is stated rather
#   than left to be found (#1771, round 6). A FENCED block is cut out of the
#   written view before it reads (`split_fenced_blocks`) and carries no inline
#   content for the printed views, so `- [blocked] waiting` inside a fence is
#   accepted: a fence is code the page shows verbatim, which is #1727's
#   decision for the source model and the page agrees by construction. An
#   INDENTED code block is code too, and it is REFUSED -- the written view's
#   pattern allows the leading spaces and the line matches. That asymmetry
#   stands rather than being tidied: the rule here is that a reader on the
#   refusing side may add refusals and may never remove one, and dropping this
#   refusal means deciding, against the page, that no author writing an
#   indented `- [blocked]` under this heading means it. Both shapes have a
#   control.
#
#   Every PRINTED view (`PRINTED_PENDING_RE`) reads a line as the page puts it
#   on one, and takes it marker or no marker: a raw HTML block prints whatever
#   sits on the line; the model's resolved inline text and the page's own text
#   carry a marker only when the parser did not model one (a bulleted table
#   cell), and CommonMark has no task list, so `- [x] ` arrives as characters.
#
# The wrapper axis does NOT separate the readers, and the sentence here that
# said it did was wrong twice over. A post-parse line can carry a delimiter
# character: an escape and a character reference are markup the parser
# RESOLVES TO one, so `- \*\*[blocked]\*\*`, `- &#42;&#42;[blocked]&#42;&#42;`,
# `` - \`[blocked]\` ``, `- &#96;[blocked]&#96;`, `- &#95;[blocked]&#95;`,
# `- _[blocked]_x` and `- [blocked][missing]` each print the token with its
# delimiters intact -- measured through GitHub's renderer, and through this
# parser's own resolved text, on all seven (#1771, round 4). Every printed
# view therefore takes the wrapper, and "allowing them there would be allowing
# something its input cannot contain" was false of the input.
#
# The padding inside a wrapper is part of the wrapper rather than part of the
# token: a code span written `` ` [blocked] ` `` shows its spaces to a reader
# wherever the span is printed as characters (#1771).
# The leading run, as a PROPERTY rather than as a list of characters: the
# inline delimiter characters a wrapper is made of, and every character that
# occupies the line without showing anything.
#
# Round 4 enumerated three invisible characters and four more went through it;
# round 5 made the run `Cf` plus `Zs` and 22 more went through THAT -- every
# default-ignorable combining mark (U+034F, U+17B4-U+17B5, U+180B-U+180D,
# U+FE00-U+FE0F), which round 5 excluded on the stated ground that a mark
# "renders as a diacritic rather than as nothing". False for these: GitHub
# prints U+034F and U+FE00 verbatim at zero width, and the gate accepted the
# status behind them (#1771, round 6).
#
# The property the body already named as the right one is the run now:
# Unicode's Default_Ignorable_Code_Point -- the characters Unicode says
# should render as nothing -- in union with the format characters (`Cf`) and
# the space separators (`Zs`).
#
# Why the union rather than Default_Ignorable alone: 32 format characters are
# NOT default-ignorable (the prepended concatenation marks U+0600-U+0605 and
# their kin), and round 5 already refused them. A narrower run would be a
# regression dressed as a rule.
#
# THE COST, written where the ranges are: `unicodedata` exposes no
# Default_Ignorable predicate, so the ranges below are TRANSCRIBED from
# Unicode's DerivedCoreProperties. That is a snapshot. Unicode adds code
# points; this table does not. A table a reader can check beats one the
# interpreter picks -- but it goes stale silently, so the version it was
# copied from is recorded beside it and `unicode_data_notice()` says so out
# loud when the running interpreter's UCD is newer. `Cf` and `Zs` keep
# tracking the interpreter, so a new format character is covered the day
# Python knows about it; only the default-ignorable half needs a human.
DEFAULT_IGNORABLE_TRANSCRIBED_FROM = "15.1.0"
DEFAULT_IGNORABLE_RANGES = (
    (0x00AD, 0x00AD),    # SOFT HYPHEN
    (0x034F, 0x034F),    # COMBINING GRAPHEME JOINER
    (0x061C, 0x061C),    # ARABIC LETTER MARK
    (0x115F, 0x1160),    # HANGUL CHOSEONG/JUNGSEONG FILLER
    (0x17B4, 0x17B5),    # KHMER VOWEL INHERENT AQ/AA
    (0x180B, 0x180F),    # MONGOLIAN FREE VARIATION SELECTORS, VOWEL SEPARATOR
    (0x200B, 0x200F),    # ZERO WIDTH SPACE .. RIGHT-TO-LEFT MARK
    (0x202A, 0x202E),    # BIDI EMBEDDING AND OVERRIDE CONTROLS
    (0x2060, 0x206F),    # WORD JOINER .. NOMINAL DIGIT SHAPES
    (0x3164, 0x3164),    # HANGUL FILLER
    (0xFE00, 0xFE0F),    # VARIATION SELECTORS 1-16
    (0xFEFF, 0xFEFF),    # ZERO WIDTH NO-BREAK SPACE
    (0xFFA0, 0xFFA0),    # HALFWIDTH HANGUL FILLER
    (0xFFF0, 0xFFF8),    # unassigned specials, default-ignorable by property
    (0x1BCA0, 0x1BCA3),  # SHORTHAND FORMAT CONTROLS
    (0x1D173, 0x1D17A),  # MUSICAL SYMBOL BEAM/PHRASE CONTROLS
    (0xE0000, 0xE0FFF),  # TAGS AND VARIATION SELECTORS SUPPLEMENT
)
INVISIBLE_CATEGORIES = ("Cf", "Zs")
INVISIBLE_LEADING = "".join(
    sorted(
        {chr(code) for first, last in DEFAULT_IGNORABLE_RANGES for code in range(first, last + 1)}
        | {
            chr(code)
            for code in range(0x110000)
            if unicodedata.category(chr(code)) in INVISIBLE_CATEGORIES
        }
    )
)
# The MEASURED facts, pinned as literals rather than recomputed: a test that
# rebuilds the set from the interpreter it is running on cannot see the
# interpreter change under it. `requires-python = ">=3.11"` permits a range,
# and the range matters -- 3.11 (UCD 14.0.0) builds a 4,216-character run and
# accepts U+13439, 3.13 (UCD 15.1.0) builds 4,223 and refuses it (#1771,
# round 6).
MEASURED_UNIDATA_VERSION = "15.1.0"
MEASURED_LEADING_RUN_SIZE = 4223


def _unicode_version_key(version: str) -> tuple[int, ...]:
    """A Unicode version as numbers, so `14.0.0` sorts below `15.1.0`."""
    parts = []
    for piece in version.split("."):
        parts.append(int(piece) if piece.isdigit() else 0)
    return tuple(parts)


def unicode_data_notice() -> str | None:
    """Whether this interpreter's Unicode data differs from the transcription, and which way.

    Loud, not fatal: a supported interpreter is not a defect, and a gate that
    refused to run on one would be worse than the drift it is warning about.

    The DIRECTION is the part worth saying, and the first version of this
    sentence got it backwards: under an interpreter OLDER than the
    transcription it said "re-derive the ranges from DerivedCoreProperties
    14.0.0", which is re-deriving a newer table from older data (#1771,
    round 7). The two directions ask for different things:

    interpreter NEWER -- Unicode has moved and the transcription has not, so
    the table is the stale half: re-transcribe it and re-measure the size.

    interpreter OLDER -- the table leads the data the `Cf` and `Zs` halves
    come from, which is not wrong and not fixable by editing the table: the
    run is simply smaller here, so the size to expect is that interpreter's,
    and the pin belongs to the version it was measured against.
    """
    running = unicodedata.unidata_version
    if running == DEFAULT_IGNORABLE_TRANSCRIBED_FROM:
        return None
    pinned = (
        f"MEASURED_LEADING_RUN_SIZE is pinned at {MEASURED_LEADING_RUN_SIZE} against "
        f"{MEASURED_UNIDATA_VERSION}"
    )
    if _unicode_version_key(running) > _unicode_version_key(DEFAULT_IGNORABLE_TRANSCRIBED_FROM):
        return (
            f"Unicode data moved AHEAD of this gate: this interpreter's UCD is {running}, "
            f"newer than the {DEFAULT_IGNORABLE_TRANSCRIBED_FROM} the default-ignorable table "
            f"was transcribed from. The cost: any default-ignorable code point added since "
            f"{DEFAULT_IGNORABLE_TRANSCRIBED_FROM} is missing from the table, so the gate "
            f"accepts a status hidden behind one. Re-transcribe DEFAULT_IGNORABLE_RANGES from "
            f"DerivedCoreProperties {running} and re-measure the run ({pinned})."
        )
    return (
        f"This interpreter's Unicode data is BEHIND the gate's table: its UCD is {running}, "
        f"older than the {DEFAULT_IGNORABLE_TRANSCRIBED_FROM} the default-ignorable table was "
        f"transcribed from. The table itself is unaffected, but `Cf` and `Zs` come from the "
        f"interpreter, so the run here is SMALLER than the one this gate was measured with: "
        f"format and space characters added since {running} are not covered and a status "
        f"hidden behind one is accepted. Nothing to re-transcribe -- run the gate on "
        f"{DEFAULT_IGNORABLE_TRANSCRIBED_FROM} data or later, and expect this interpreter's "
        f"own size rather than the pin ({pinned})."
    )


WRAPPER_DELIMITERS = "`*_"
OPENING_WRAPPER = "[" + re.escape(WRAPPER_DELIMITERS + "\t" + INVISIBLE_LEADING) + "]*"
STATUS_TOKEN = r"\[(?:blocked|pending-ci)\]"
PENDING_STATUS_RE = re.compile(
    rf"(?im)^\s*{LIST_MARKER}\s*(?:\[[ x]\]\s*)?{OPENING_WRAPPER}{STATUS_TOKEN}"
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


# The one section this gate reads two ways, named once so the written read's
# heading and the rendered read's cannot drift apart. The contributor skill
# spells it in `evidence.py`.
EVIDENCE_STATUS_HEADING = "Evidence Status"


def heading_identity(text: str) -> str:
    """One heading's text reduced to what decides whether two headings are one.

    Runs of whitespace collapse, and case folds with `lower()` rather than
    `casefold()`. Full case folding maps characters that are not case variants
    of anything: U+017F, the long s a printer sets in `Statuſ`, folds to `s`,
    so `## Evidence Statuſ` written above the real `## Evidence Status`
    matched it -- for this gate's old `(?i)` pattern as well as for the
    contributor skill's reader -- and the rewrite then removed both sections
    (#1742). `ß` -> `ss` and `ﬁ` -> `fi` are the same shape.

    What `lower()` accepts is Unicode's own lowercase mapping, including the
    context rule that makes a shouted Greek word end in a final sigma; what it
    declines is a fold that changes the letters rather than their case. Of the
    297 codepoints the two folds disagree on, exactly one folds onto an ASCII
    letter -- U+017F onto `s` -- and every section this repo addresses is
    spelled in ASCII, which is the whole of the argument for the narrower
    fold.

    It declines two pairs a reader might not: `ß`/`SS`, and `İ`/`i`, which no
    Python fold joins either -- `casefold()` maps U+0130 to `i` plus a
    combining dot, not to `i`. A heading spelled with one of them is refused
    by name rather than read past: `unread_status_heading_failure` is that
    refusal. Normalising first was the other candidate and NFKC goes the wrong
    way, mapping a fullwidth `Ｓ` onto `s`.

    Written here and in the skill's `_helpers` for the reason `MARKDOWN` is,
    and pinned by `HeadingIdentityFoldsCaseAndNotLettersTests`.
    """
    return " ".join(text.split()).lower()


def heading_identity_text(children: list[Token] | None) -> str | None:
    """A heading's text for identity, or None when the heading shows something else.

    Text and emphasis, and nothing else. A heading is a section's heading when
    the page shows it AS that heading, so every inline construct that puts
    something of its own there disqualifies it: a code span shows the word in
    code font, a link shows a link, an image an image, strikethrough withdraws
    it, and inline HTML is a widget, a struck run or two lines
    (`## <details>Mergeability</details>`, `## Merge<del>ability</del>`,
    `## Merge<br>ability`). Each of those became this section for a rewrite
    that then replaced an author's text, which is why the skill's rule is any
    tag rather than a list of the ones that show something (#1730).

    Returning None rather than the text is how "shows something else" and "is
    a different heading" stay distinguishable at the call site. For a heading
    ARGUMENT that is a plain word -- `Mergeability`, `Validation`,
    `Performance`, `Evidence Status`, every section this repo addresses -- it
    is the same answer the skill's `section_heading_index` gives: each
    construct None is returned for carries its own markup into `inline_text`'s
    output (backticks, brackets, a target, tildes), so the text no longer
    reads as the heading, or is the inline HTML that rule refuses outright.

    For an argument that itself holds markup the two part company, and this
    one is the stricter: asked for `` `Mergeability` ``, the skill matches
    `## `Mergeability`` because its `inline_text` re-emits the backticks, and
    this returns None. No caller asks that, and the narrowing fails closed --
    the section reads as missing -- so the divergence is written down here and
    fixtured rather than closed. `TheSeederAndThisGateAskOneQuestionTests`
    measures the agreement over the plain-word headings and carries that
    fixture.

    A line break is a space here, which is `inline_text`'s own default. A
    setext heading may run over two lines, so `Evidence` over `Status` with a
    `---` under them is this section to both readers -- the page shows one
    heading reading `Evidence Status`. A single word split across the two
    lines is not: `Eviden` over `ce Status` reads with a space in it, which is
    what the page shows too.
    """
    parts: list[str] = []
    for token in children or []:
        if token.type == "text":
            parts.append(token.content)
        elif token.type in {"softbreak", "hardbreak"}:
            parts.append(" ")
        elif token.type not in {"em_open", "em_close", "strong_open", "strong_close"}:
            return None
    return "".join(parts)


def section_heading_index(tokens: list[Token], heading: str) -> int | None:
    """Where `## <heading>` opens in a parsed body, as a token index, or None.

    A parse rather than a pattern, and the same question the contributor
    skill's `section_heading_index` answers. A literal `^## <heading>` line
    read a `## Mergeability` block inside a fenced example as the body's own
    section: where that example was complete, this gate returned `ok=True` on
    a pull request whose page showed no section at all (#1742). It also missed
    every heading the page shows and the pattern does not describe -- emphasis,
    an indent of up to three spaces, a setext underline, trailing whitespace,
    a closing hash run -- so a body the factory had healed was one this gate
    then blocked, and the runtime carried a copy of this pattern to predict it.

    The first such heading wins, which is what the rendered read already did:
    a body with two is a body whose second one no reader is reading, and
    `unread_status_heading_failure` is the refusal that says so.

    Two fail-opens downstream of this read are main's and not closed here,
    and reading more heading spellings enlarges the set of bodies that reach
    each. `field_value` searches the section's raw text, so the four
    Mergeability fields and Validation's release proof are credited to text
    the page shows as CODE -- true under a literal `## Mergeability` on main
    and now true under the seven spellings this read adds. And a section below
    an unclosed `<details>` is folded on the page and a heading to this parse
    either way, which is #1742's third item, blocked on the renderer decision
    in #1745. Both are measured in `WhatTheParsedStartCostsTheEvidenceRefusalTests`
    and filed rather than carried as prose.
    """
    wanted = heading_identity(heading)
    return next(
        (
            index
            for index, token in enumerate(tokens)
            if token.level == 0
            and token.type == "heading_open"
            and token.tag == "h2"
            and (text := heading_identity_text(tokens[index + 1].children)) is not None
            and heading_identity(text) == wanted
        ),
        None,
    )


def extract_section(body: str, heading: str, *, strip: bool = True) -> str:
    """The body text under `## <heading>`, as written, up to where the section ends.

    Both ends are asked of the parser rather than matched line by line. A
    scanner reading `---` as a rule and nothing else took `----`, `- - -` and a
    line of dashes with trailing spaces for ordinary text, kept the text line
    of a setext heading inside the section it ends, read past a heading
    indented one space, and stopped at a heading the page shows inside an
    unterminated HTML block -- five shapes on which the gate and the
    contributor skill read different sections of the same body, each found by
    enumerating the two rules against each other rather than by a body that
    failed (#1734). The START was a literal line for one release longer, and
    `section_heading_index` is what it asks now (#1742).

    Stripping takes the first line's indent along with the blank lines around
    the section, so a reader that cares about indentation asks for it
    unstripped.
    """
    # Every line ending GitHub stores. `evaluate` normalises the body it
    # reads; this repeats it because the function is called directly too, and
    # a CRLF body read here without it has no sections at all.
    normalized = LINE_ENDING_RE.sub("\n", body)
    tokens = MARKDOWN.parse(normalized)
    index = section_heading_index(tokens, heading)
    if index is None:
        return ""
    lines = normalized.split("\n")
    # A setext heading is two lines, its underline included, so the section's
    # text starts where the heading BLOCK stops rather than one line below the
    # line the heading starts on -- the arithmetic `_section_bounds` does on
    # the skill's side, and the reason a `---` underline is not read as the
    # section's own first line.
    content_start = tokens[index].map[1]
    stop = next(
        (
            token.map[0]
            for token in tokens
            if token.map and token.map[0] >= content_start and section_boundary_token(token)
        ),
        len(lines),
    )
    section = "\n".join(lines[content_start:stop])
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
#
# ONE reader for every printed view: the page's own text, the model's resolved
# inline text, and the characters a raw HTML block puts on a line. They were
# two patterns differing in the wrapper, on the reasoning that a post-parse
# line could not carry one -- and it can, through an escape or a character
# reference, so the split had the post-parse reader missing seven shapes the
# page prints and the raw-block reader missing two of them (#1771, round 4).
# What separates a reader here from the written view is the list marker and
# nothing else, so there is one spelling of this line to keep in step.
PRINTED_PENDING_RE = re.compile(
    rf"(?i)^\s*(?:{LIST_MARKER}\s*)?(?:\[[ x]\]\s*)?{OPENING_WRAPPER}{STATUS_TOKEN}"
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


# A tag as HTML writes one: a name, then attributes whose quoted values may
# carry a `>`, then an optional `/` and the close. `<[^>]*>` stopped at the
# first `>` inside `<div title="CI result > [blocked] threshold">` and left the
# attribute's tail as text, where a status then anchored on a line the page
# never shows (#1736).
# `<` is excluded from the attribute NAME as well as from an unquoted value.
# Allowing it let `<div <div <div ...` match one attribute per repetition and
# then backtrack over all of them at every offset: 50 KB of `<div ` took 13
# seconds where 1 KB took 0.005, and a gate a body can make hang is a gate an
# author bypasses by timeout (#1736, round 4). A tag with a `<` in an attribute
# name is not a tag to GitHub either, so the exclusion narrows nothing real.
HTML_ATTRIBUTE = r"""[^\s"'>/=<]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?"""
HTML_TAG_RE = re.compile(rf"</?(?P<name>[A-Za-z][A-Za-z0-9-]*)(?:\s+{HTML_ATTRIBUTE})*\s*/?>")

# The tags that start a line on the page: CommonMark's HTML-block conditions 1
# and 6, plus `br`, which is a line break.
#
# Condition 6 is the long list this repo already reads HTML blocks by.
# Condition 1 is `pre`, `script`, `style` and `textarea` -- four tags that open
# a block of their own and were missing, so `<div>note<pre>[blocked] x</pre></div>`
# read as the single run `note[blocked] x` and the status anchored nowhere,
# while GitHub renders the `<pre>` as its own block (#1736, round 4).
#
# Everything else -- `<span>`, `<strong>`, `<code>`, `<a>`, and a tag the
# sanitizer does not know such as `<T>` -- is inline: it shows nothing of its
# own and the text on either side of it stays on one line.
LINE_STARTING_TAGS = frozenset(
    """pre script style textarea
    address article aside base basefont blockquote body br caption center col
    colgroup dd details dialog dir div dl dt fieldset figcaption figure footer
    form frame frameset h1 h2 h3 h4 h5 h6 head header hr html iframe legend li
    link main menu menuitem nav noframes ol optgroup option p param search
    section summary table tbody td tfoot th thead title tr track ul""".split()
)

# What ends an open comment. `-->` is the spec's end and `--!>` is what a
# browser also takes for one (`py/bad-tag-filter`); neither is a delimiter with
# no comment open, where `base --> head` is prose a reader sees whole.
COMMENT_CLOSERS = ("-->", "--!>")
# And what closes one the moment it opens: `<!-->` and `<!--->`, the spec's
# abrupt-closing forms. Read as an opener alone, the text after them stayed
# inside a comment for this reader and outside it on the page.
COMMENT_ABRUPT_CLOSERS = (">", "->")

# A `<...>` this grammar does not parse, but which opens the way a tag does.
# GitHub's parser is more forgiving than this one, and every shape it takes and
# this does not is a run that reads one way here and another on the page:
# `<div a="1"b="2">`, `<div title=>`, `<div a/b>`, `<div title=a"b>` and
# `<x:y>` all render with what follows them on a line of their own, and all
# were accepted here because the unparsed text sat in front of the status
# (#1736, round 4). `< b and c >` in prose is not one of these: a name has to
# follow the bracket.
AMBIGUOUS_TAG_RE = re.compile(r"</?(?P<name>[A-Za-z][A-Za-z0-9:._-]*)")

# What a character reference can decode to that the page treats as a new line.
NEWLINE_REFERENCE_RE = re.compile(r"\r\n?")


def html_block_text_lines(content: str) -> list[str]:
    """Every line of text a raw HTML block shows, in the order the page shows them.

    GitHub prints a raw HTML block as itself, so a status between its tags is a
    status a reader acts on -- and the parser models no inline inside an
    `html_block`, so the rendered view read nothing there at all and the
    written view caught only what its own anchor covers, a list marker in front
    of the token. `<div>` on the line below the heading and `[blocked] the UI
    lane` under it reached neither view while the page showed it (#1736).

    This is a small model of ONE question: where does a line start on the page?
    Its boundaries are written down rather than believed complete. A line
    starts at a tag in `LINE_STARTING_TAGS`, at either delimiter of a comment,
    at a newline the source carries, and at a newline a character reference
    decodes to. It does not model which elements are open, what the sanitizer
    strips, CSS, or a table's layout beyond a cell being a line.

    Why a model is allowed here and was refused for heading identity in the
    contributor skill: that is an ACCEPTANCE question, where a wrong model
    accepts a section nobody sees and a rewrite then destroys an author's text
    with no one to notice, so the rule there had to be one that cannot widen.
    This is a REFUSAL question under the standing rule that invisible text may
    refuse and may never accept (#1729): a wrong line start over-refuses, which
    fails closed, and the failure names the run it matched, so the cost to an
    author is one read. A model is tolerable where its failure is a named
    refusal and intolerable where its failure is a silent acceptance.

    The source newline is the one boundary coarser than the page: HTML collapses
    it, so `<div>` over two source lines is one line to a reader and two here.
    It is kept because dropping it would drop refusals this gate already makes,
    and it errs toward refusing.

    Text inside a comment is read like any other run. A comment renders as
    nothing, and refusing on `<!-- [blocked] x -->` costs an author a minute
    and costs the gate no soundness, where accepting on it is the hole. So no
    run is called visible or hidden, and the factory's own metadata comment is
    not special-cased: it carries JSON, whose lines open on a brace or a quote,
    and the writer places it above this heading rather than under it.

    Each run is decoded and then split, in that order, so `&#10;` makes the two
    lines the page makes and the anchor sees the second -- and `&#13;` with it,
    which decodes to a carriage return and is a line break to the page just the
    same (#1736, round 4).

    Where this grammar cannot parse a `<...>` that opens like a tag, the block
    is read TWICE: once with that text left as text, and once with it taken for
    a tag -- removed, and a line start if its name is block-level. The lines of
    both readings are returned, so a status anchors if EITHER reading puts it
    at the start of a line. That is the arc's rule made concrete: this model
    lives on the refusing side, so where its answer is uncertain it refuses
    under any plausible reading and accepts only when none of them anchors.
    The over-refusals it brings back land on malformed markup alone, and each
    names the run it matched.
    """
    readings = [_html_block_runs(content, unparsed_as_tag=False)]
    if _holds_an_unparsed_tag(content):
        readings.append(_html_block_runs(content, unparsed_as_tag=True))
    seen, lines = set(), []
    for runs in readings:
        for run in runs:
            for line in NEWLINE_REFERENCE_RE.sub("\n", html.unescape(run)).split("\n"):
                text = line.strip()
                if text and text not in seen:
                    seen.add(text)
                    lines.append(text)
    return lines


def _holds_an_unparsed_tag(content: str) -> bool:
    """Whether this block carries a `<...>` that opens like a tag and does not parse as one."""
    for index, character in enumerate(content):
        if character != "<" or HTML_TAG_RE.match(content, index) is not None:
            continue
        if AMBIGUOUS_TAG_RE.match(content, index) and ">" in content[index:]:
            return True
    return False


def _html_block_runs(content: str, *, unparsed_as_tag: bool) -> list[str]:
    """The block's runs under one reading of the `<...>` shapes this grammar cannot parse.

    Linear in the length of the block: the scan walks each character once, and
    the tag pattern is asked only where a `<` sits and only anchored at that
    index, never re-scanned from every offset.
    """
    runs: list[str] = []
    current: list[str] = []
    index, in_comment = 0, False

    def cut() -> None:
        runs.append("".join(current))
        current.clear()

    while index < len(content):
        if in_comment:
            closer = next((end for end in COMMENT_CLOSERS if content.startswith(end, index)), None)
            if closer is not None:
                cut()
                in_comment, index = False, index + len(closer)
                continue
        elif content.startswith("<!--", index):
            cut()
            opened = index + len("<!--")
            abrupt = next(
                (end for end in COMMENT_ABRUPT_CLOSERS if content.startswith(end, opened)), None
            )
            in_comment = abrupt is None
            index = opened + (len(abrupt) if abrupt is not None else 0)
            continue
        elif (tag := HTML_TAG_RE.match(content, index)) is not None:
            if tag["name"].lower() in LINE_STARTING_TAGS:
                cut()
            index = tag.end()
            continue
        elif unparsed_as_tag and content[index] == "<":
            opener = AMBIGUOUS_TAG_RE.match(content, index)
            closer = content.find(">", index)
            if opener is not None and closer != -1:
                if opener["name"].lower() in LINE_STARTING_TAGS:
                    cut()
                index = closer + 1
                continue
        current.append(content[index])
        index += 1
    cut()
    return runs


def rendered_status_lines(body: str) -> list[str]:
    """Every line a reader sees under `## Evidence Status`.

    ONE list, because the kind of text a line is no longer decides anything.
    It was two -- `parsed` for inline text the markdown parser had resolved,
    `printed` for the characters a raw HTML block puts on the page -- on the
    reasoning that the two take different readers. They do not: a post-parse
    line can carry a delimiter character, so both take the reader that allows
    the wrapper, and a field nothing reads differently is a distinction
    remembered rather than carried (#1771, round 4).

    What the two sources still are is two SOURCES, and every caller asks both:
    a raw block contributes no parsed lines at all, and an inline run
    contributes no printed ones, so a caller that drops either loses a status
    the page shows.
    """
    return _status_lines(body)


def _status_lines(body: str) -> list[str]:
    """Each line under the heading, as the page puts it on one.

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
    written side. A raw HTML block has no inline either, and the page prints it
    anyway, so its own lines are read through `html_block_text_lines` (#1736).

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
            and heading_identity(rendered_inline_text(tokens[index + 1].children))
            == heading_identity(EVIDENCE_STATUS_HEADING)
        ):
            index += 1
            continue
        index += 3  # heading_open, its inline, heading_close
        while index < len(tokens):
            token = tokens[index]
            if section_boundary_token(token):
                break
            if token.type == "inline":
                for part in rendered_inline_text(token.children).split("\n"):
                    lines.append(part.strip())
                    # A `<...>` that opens like a tag and parses as none reaches
                    # here as text, because this parser does not call it a tag
                    # either -- `<x:y>[blocked] x</x:y>` is one run of prose to
                    # it. Whether the page shows that bracket or strips it is
                    # the renderer's answer and not one this model has, so the
                    # line is read both ways and a status anchors if either
                    # reading starts a line with it (#1736, round 4).
                    if _holds_an_unparsed_tag(part):
                        lines.extend(html_block_text_lines(part))
            elif token.type == "html_block":
                lines.extend(html_block_text_lines(token.content))
            index += 1
    return lines


# GitHub's own answer to the one question the model above asks: where does a
# line start on the page? `POST /markdown` in `gfm` mode returns the HTML the
# pull request page shows, and a line start read off that HTML needs no tag
# grammar, no comment state and no block-element list (#1745).
#
# The two readers combine the way the written and rendered views already do --
# a conjunction of refusals, never a vote. A status either of them puts at the
# start of a line fails the gate, so the renderer can only ever ADD refusals
# and the model is never the sole accepter when the renderer answered. The
# model's over-refusals survive on purpose: `<x:y>[blocked] x</x:y>` renders
# as one literal line the page starts with `<x:y>`, so the renderer would
# accept it and the model still refuses, which is the standing rule that a
# reader on the refusing side may add refusals and may never remove them
# (#1729).
MARKDOWN_API_URL = "https://api.github.com/markdown"
MARKDOWN_API_VERSION = "2022-11-28"
# One call per gate run against a body GitHub caps at 65,536 characters. Ten
# seconds is far past the ~0.2 s the call takes from a laptop and short enough
# that a gate waiting on an unreachable renderer still finishes well inside
# the workflow's ten-minute timeout.
RENDER_TIMEOUT_SECONDS = 10
DEFAULT_REPOSITORY = "fairchild/workspaces"


class RendererUnavailable(Exception):
    """GitHub did not render the body. The message is why, in one clause."""


def repository_context() -> str:
    """The repository the renderer resolves `#123` and `@name` against."""
    return os.environ.get("GITHUB_REPOSITORY") or DEFAULT_REPOSITORY


def http_failure_reason(error: urllib.error.HTTPError) -> str:
    """Why a non-2xx answer arrived, naming the rate limit when that is the cause."""
    headers = error.headers or {}
    if error.code in {403, 429} and headers.get("x-ratelimit-remaining") == "0":
        reset = headers.get("x-ratelimit-reset") or "the next window"
        return f"the renderer's rate limit is spent (it resets at {reset})"
    return f"the renderer answered HTTP {error.code}"


def render_markdown(text: str) -> str:
    """The HTML GitHub shows for `text`, or `RendererUnavailable` saying why not.

    `POST /markdown` needs no permission beyond a token that authenticates: it
    reads nothing of the repository except the `context` it resolves
    references against, so CI passes `github.token` and a laptop passes
    whatever `gh` already exported. An unauthenticated call is not attempted,
    because the anonymous allowance is 60 an hour shared across the whole
    host, and a gate spending it would pass for one author and fail for the
    next with no change in the body.
    """
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        raise RendererUnavailable("no GH_TOKEN or GITHUB_TOKEN in the environment")
    payload = json.dumps({"text": text, "mode": "gfm", "context": repository_context()})
    request = urllib.request.Request(
        MARKDOWN_API_URL,
        data=payload.encode("utf-8"),
        method="POST",
        headers={
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": MARKDOWN_API_VERSION,
            "Authorization": f"Bearer {token}",
            "User-Agent": "workspaces-pr-readiness",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=RENDER_TIMEOUT_SECONDS) as response:
            return response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        raise RendererUnavailable(http_failure_reason(error)) from error
    except (urllib.error.URLError, OSError) as error:
        raise RendererUnavailable(f"the renderer was unreachable ({error})") from error


# Elements whose contents are not the document's own top level: a heading
# inside one is a heading in someone else's structure -- a quotation, a list
# item -- and neither opens this section nor ends it. `> ## Note` inside the
# section ended it, and a `> ## Evidence Status` example quoted in another
# section opened one and refused a body every other reader accepts.
#
# `<details>` is deliberately NOT here. Part B's rule is that folded text is
# text a reader opens, so a `## Evidence Status` written below an unclosed
# `<details>` renders inside the collapsed element and is still this section.
# The distinction is whether the container changes what the text MEANS: a
# quotation and a list item say "this is someone else's heading", a fold says
# only "click to see it".
OPAQUE_CONTAINERS = frozenset({"blockquote", "li"})


class PageLineReader(HTMLParser):
    """The lines a reader sees under `## Evidence Status` on the rendered page.

    A line ends where the page ends one: at the boundary of an element laid
    out as a block -- read off `LINE_STARTING_TAGS`, the list the source model
    already keeps, so the two readers cannot drift on what a block is -- and
    at `<br>`, which breaks a line wherever it appears, including inside a
    paragraph. That last case is the one the source model cannot see: it drops
    a parsed inline tag and keeps the text either side on one line, so
    `Context <br>[blocked] x` read as a single run there and reads as two
    lines here (#1755).

    The section ends at a heading and at nothing else. `<hr>` used to end it
    too, on the argument that `extract_section` ends at a dash rule. It does
    -- but a rule of asterisks reaches the page as the same `<hr>`, and the
    source model runs past that one on purpose, so ending here meant
    `## Evidence Status`, `***`, then a status the page shows at a line start
    was read by neither view. A rule is decoration to a reader anyway: what
    starts a new section on a page is a heading. The cost is the mirror and it
    is the tolerated one -- after a DASH rule the written view stops and this
    reader does not, so a status below `---` under this heading draws a
    refusal the source alone would not make, which fails closed and quotes the
    line (#1745, round 2).

    Three decisions about what the page shows.

    `<details>` is read. Its text is folded and a reader opens the fold, so a
    status that appears on a click is a status, and refusing is the side this
    reader errs on. A `## Evidence Status` section written below an unclosed
    `<details>` renders inside the collapsed element, and the section is read
    there like any other -- which is why the heading is taken wherever it
    appears rather than only at the top level (#1742, item 3). Whether a
    section may be placed inside a fold at all is the writer's question and
    stays with the contributor skill's placement check.

    A code BLOCK is not read; a code SPAN is. Both reach the page inside a
    `<code>` element, and the difference on the page is the `<pre>` around the
    block: a fenced or indented block is an example someone is quoting, which
    the written view already drops, and a span is ordinary text in a sentence.
    Dropping both meant `Context <br>` + `` `[blocked]` `` -- a status the page
    prints at the start of its own line -- was read as `Context` and `x`, and
    the body passed. A raw `<pre>` an author wrote holds no `<code>`, so its
    text is read: that is one of the four shapes this reader exists for.

    A newline inside `<pre>` starts a line. Anywhere else it is whitespace,
    because that is what the page does with it.
    """

    def __init__(self, *, a_nested_heading_may_open_it: bool = False) -> None:
        super().__init__(convert_charrefs=True)
        self.lines: list[str] = []
        self.opened = False
        self._current: list[str] = []
        self._in_section = False
        self._heading: list[str] | None = None
        self._code_depth = 0
        self._pre_depth = 0
        self._nesting = 0
        self._section_depth: int | None = None
        self._a_nested_heading_may_open_it = a_nested_heading_may_open_it

    def _boundary_depth(self) -> int:
        """The nesting depth a heading has to sit at to bound this section.

        The depth the section was opened at, so a section the second pass
        found inside a container ends at that container's next heading rather
        than at the container's end. A heading shallower than this one ends it
        too: the callers compare with `<=`, because a section inside a
        quotation is over once the document has left the quotation. Zero
        before anything opens: a top-level heading is what a first pass is
        looking for.
        """
        return 0 if self._section_depth is None else self._section_depth

    def _cut(self) -> None:
        text = " ".join("".join(self._current).split())
        if text:
            self.lines.append(text)
        self._current.clear()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        name = tag.lower()
        if name == "br" and self._heading is not None:
            # A break splits a line wherever it sits, and a heading is not an
            # exception: `> ## Context<br>[blocked] x` is two lines on the
            # page, and collecting the heading whole read it as one and let
            # the status through (#1745, round 4).
            self._heading.append("\n")
            return
        if name in OPAQUE_CONTAINERS:
            self._nesting += 1
        elif name == "h2":
            # Every h2 is read, at any depth: whether it is this section's,
            # someone else's, or a line of text depends on its own words and
            # on where it sits, and only `handle_endtag` knows both.
            self._cut()
            self._heading = []
            return
        elif name == "h1" and self._nesting <= self._boundary_depth():
            self._cut()
            self._in_section = False
            return
        if not self._in_section:
            return
        if name in LINE_STARTING_TAGS:
            self._cut()
        if name == "code":
            self._code_depth += 1
        elif name == "pre":
            self._pre_depth += 1

    def handle_endtag(self, tag: str) -> None:
        name = tag.lower()
        if name in OPAQUE_CONTAINERS:
            self._nesting = max(0, self._nesting - 1)
        if name == "h2" and self._heading is not None:
            # The breaks inside it are line boundaries; its identity is the
            # whole of its text, the way `## Evidence<br>Status` names this
            # section while showing a reader two lines.
            pieces = "".join(self._heading).split("\n")
            self._heading = None
            # `heading_identity` is the repo's one rule for when two headings
            # are one, shared with the written view and the contributor skill
            # (#1759), so a printer's long s in `Statuſ` is not this
            # section to any reader.
            is_section = heading_identity(" ".join(pieces)) == heading_identity(
                EVIDENCE_STATUS_HEADING
            )
            if is_section and (not self._nesting or self._a_nested_heading_may_open_it):
                self._current.clear()
                self._in_section = True
                self.opened = True
                self._section_depth = self._nesting
                return
            if self._nesting <= self._boundary_depth():
                # A heading at the section's own depth ends it -- including a
                # section the second pass opened inside a container, which
                # otherwise ran to the end of that container and refused on
                # lines under a sibling heading (#1745, round 4).
                #
                # Or SHALLOWER than it. A section found inside a quotation
                # ends at the top-level heading that follows the quotation as
                # surely as at a sibling inside it: leaving the document is
                # leaving the section, and `==` alone kept reading past
                # `## Notes` written after the quotation closed (#1745,
                # round 5).
                self._current.clear()
                self._in_section = False
                return
            # A heading in someone else's structure: it is a line the page
            # shows like any other, cut at every break it holds.
            if self._in_section:
                for piece in pieces:
                    self._current.append(piece)
                    self._cut()
            return
        if not self._in_section:
            return
        if name in LINE_STARTING_TAGS:
            self._cut()
        if name == "code":
            self._code_depth = max(0, self._code_depth - 1)
        elif name == "pre":
            self._pre_depth = max(0, self._pre_depth - 1)

    def handle_data(self, data: str) -> None:
        if self._heading is not None:
            self._heading.append(data)
            return
        if not self._in_section or (self._code_depth and self._pre_depth):
            return
        if not self._pre_depth:
            self._current.append(data)
            return
        head, *rest = data.split("\n")
        self._current.append(head)
        for part in rest:
            self._cut()
            self._current.append(part)

    def finish(self) -> list[str]:
        self.close()
        self._cut()
        return self.lines


def page_status_lines(rendered: str) -> list[str]:
    """Every line the rendered page shows under `## Evidence Status`.

    Read twice where the first read finds no section at all. A heading inside
    a quotation or a list item is someone else's heading and does not open
    this section -- unless it is the only one there is, which is what an
    author writes by opening a container and not closing it. GitHub's
    sanitizer balances that container around the rest of the document, so the
    one `## Evidence Status` in the body renders inside a `<blockquote>` it
    was never meant to be in, and reading nothing there let a status the page
    plainly shows reach neither view (#1745, round 3).

    "Unless it is the only one there is" rather than a rule about which
    containers were closed: the rendered HTML is balanced either way -- a
    quotation closes before the document continues and an unclosed container
    closes at the very end -- and telling those apart is a second model of the
    thing this reader exists to stop modelling. Counting instead is one
    sentence, and it fails toward refusing: the second read can only find a
    section the first did not, so it can only add lines.
    """
    reader = PageLineReader()
    reader.feed(rendered)
    lines = reader.finish()
    if reader.opened:
        return lines
    nested = PageLineReader(a_nested_heading_may_open_it=True)
    nested.feed(rendered)
    return nested.finish()


@dataclass(frozen=True)
class PageView:
    """What the renderer said about a body, or why it said nothing.

    `unverified` is the whole fallback contract in one field: when it is set
    the gate saw no page at all and stands on the source model's refusals, and
    it says so in its output and in the comment it leaves, because an author
    who cleared a gate that could not reach the renderer cleared a different
    gate from the one CI runs.
    """

    lines: tuple[str, ...] = ()
    unverified: str | None = None


_PAGE_VIEWS: dict[str, PageView] = {}


def page_view(body: str) -> PageView:
    """The page's answer for this body, asked of GitHub once per run.

    Cached on the body text: the Factory review lane evaluates the same body
    through this same `evaluate`, and the gate's cost should be one request
    however many times a caller asks.
    """
    if body not in _PAGE_VIEWS:
        try:
            rendered = render_markdown(body)
        except RendererUnavailable as unavailable:
            _PAGE_VIEWS[body] = PageView(unverified=str(unavailable))
        else:
            _PAGE_VIEWS[body] = PageView(lines=tuple(page_status_lines(rendered)))
    return _PAGE_VIEWS[body]


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
    # Exact is `## Evidence Status` at column 0, in any letter case: the shape
    # the factory's writer produces and replaces. One indented up to three
    # spaces renders the same and counts as a variant, so a status line under
    # it fails the gate instead of going unread.
    #
    # A line scan, and narrower than the section `extract_section` reads since
    # #1742: a heading written with emphasis or over a setext underline is a
    # section to that reader and not a heading to this count, so a body with
    # one of those above the real heading reads as ONE exact heading here while
    # the page shows two. `unread_status_heading_failure` is the parse-backed
    # half that sees them, and `evaluate` asks it where this check is
    # satisfied. This one keeps the line scan because its message names the
    # exact spelling to write, which is the repair an author can act on.
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


def status_heading_candidates(body: str) -> list[tuple[int, str]]:
    """Every heading this gate's start considers for `## Evidence Status`, with its line and text.

    The candidates, not the section: a top-level h2 whose text
    `heading_identity_text` reads -- so emphasis is transparent and a heading
    carrying a tag, a code span, a link or strikethrough is not here at all --
    and whose text matches the heading case-insensitively the way `re` matches
    it.

    Two folds, on purpose. `re`'s IGNORECASE is the loosest in reach and not
    an arbitrary choice: it is the fold this gate's own literal start used
    until #1742. It is NOT the set that reader would have taken -- a heading
    written with emphasis, one indented up to three spaces, a setext one and
    one with a closing hash run are candidates here and were never matched by
    that literal line, and a heading the parser puts inside a raw HTML block
    was matched by it and is not a candidate here. The overlap is the fold,
    not the set. `heading_identity` is the tight one that decides which
    candidate IS the section, and the gap between the two folds is part of
    what `unread_status_heading_failure` reports; reading the loose side wider
    can only add a refusal (#1729).

    What is excluded is excluded because this repo already decided it: a
    heading carrying inline HTML is not this section and the factory's repair
    writes a plain one BELOW it, leaving both on the page (#1730). Counting
    the rejected one here would refuse the body that repair produces -- a body
    the factory heals and the gate then blocks, which is the failure this lane
    exists to prevent.
    """
    tokens = MARKDOWN.parse(LINE_ENDING_RE.sub("\n", body))
    loose = re.compile(rf"(?i){re.escape(' '.join(EVIDENCE_STATUS_HEADING.split()))}")
    found: list[tuple[int, str]] = []
    for index, token in enumerate(tokens):
        if not (token.type == "heading_open" and token.tag == "h2" and token.level == 0):
            continue
        text = heading_identity_text(tokens[index + 1].children)
        if text is None:
            continue
        collapsed = " ".join(text.split())
        if loose.fullmatch(collapsed):
            found.append(((token.map or [0])[0] + 1, collapsed))
    return found


def unread_status_heading_failure(body: str) -> str | None:
    """Why the heading a reader sees is not the section this gate reads, or None.

    The check that keeps this gate's narrowing from being silent. Its section
    START is a parse now, and its identity fold declines a fold that changes
    letters (#1742) -- both correct, and both turn a heading the gate used to
    read into a heading it reads past. Where the section carries a `[blocked]`
    line, a section nobody reads is a refusal nobody makes: the old literal
    `(?mi)^## Evidence Status` matched `## EVİDENCE STATUS`, because `re`'s
    IGNORECASE folds the whole Unicode table, and `## Evidence Statuſ` with it.

    Three shapes, and what they have in common is a disagreement this gate
    already holds and used to keep to itself: the line scan and the parse
    answer differently about whether this body has the section, and the author
    hears neither answer.

    More than one candidate is the shape `evidence_status_heading_failure`
    cannot see -- that check is a line scan, so `## **Evidence Status**` above
    the real heading counts as one exact heading while the page shows two, and
    a `[blocked]` line or an unclosed fence under the wrong one is not this
    section's. The message names the heading this gate actually reads, which
    is not always the first candidate: the candidate list uses the loose fold,
    so a long-s heading above the real one is in it and is not the section.

    One candidate this gate's identity declines is the second: the page shows
    a heading reading as this section, spelled with a character that is not a
    case variant of anything, and no reader here takes it.

    A heading line the parse puts inside a raw HTML block is the third, and it
    is this branch's own fail-open (#1742, round 2). A `## Evidence Status`
    line with no blank line above it, under `</details>`, an `<img>` tag, an
    opening `<div>` or a comment a browser ends at `--!>`, is inside a raw
    HTML block to CommonMark: the old literal start matched it wherever it
    sat, this parse finds no heading, and the `[blocked]` line the page
    plainly shows went from a refusal to a pass. The refusal names the
    heading's line and the block's, because the repair is one blank line and
    an author cannot see a block boundary.

    That third one is asked first, and whatever the candidate count. Gating it
    on an empty candidate list made it a refusal about a whole body rather
    than about a line: the same swallowed heading placed above a real section
    written with emphasis or over a setext underline leaves one candidate, the
    question was never asked, and the `[blocked]` line under the swallowed one
    passed. A section elsewhere in the body does not make that status readable
    -- the section read starts at the real heading and so does the page
    reader's (#1767). First, because a line no reader takes for a heading at
    all is a wider disagreement than which of several visible headings is
    read, and its message is the one naming where the hidden status sits.

    Where the covering block is CODE rather than raw HTML, this stays silent:
    a fenced or indented `## Evidence Status` is an example, the page shows it
    as code, and "no section" is the right answer for an optional section.
    That is the one line this refusal must not cross, and it has a fixture.

    The contributor skill's owner read already fails closed on the first two
    -- it refuses for any heading count but one -- so this is the readiness
    gate saying the same thing rather than a new rule. It names the line,
    because an author cannot see a long s.
    """
    normalized = LINE_ENDING_RE.sub("\n", body)
    if swallowed := _swallowed_status_heading_failure(normalized):
        return swallowed
    headings = status_heading_candidates(normalized)
    if not headings:
        return None
    if len(headings) > 1:
        places = ", ".join(f"line {line}" for line, _ in headings)
        tokens = MARKDOWN.parse(normalized)
        index = section_heading_index(tokens, EVIDENCE_STATUS_HEADING)
        read = (
            f"this gate reads the one at line {(tokens[index].map or [0])[0] + 1}"
            if index is not None
            else "none of them is the section to this gate"
        )
        return (
            f"A reader sees {len(headings)} headings that read as "
            f"'## {EVIDENCE_STATUS_HEADING}' ({places}); {read}, so a status under the "
            "others is not this section's. Keep one."
        )
    line, text = headings[0]
    if heading_identity(text) == heading_identity(EVIDENCE_STATUS_HEADING):
        return None
    return (
        f"The heading at line {line} reads as '## {EVIDENCE_STATUS_HEADING}' but is spelled "
        f"'{text}', which differs by more than letter case, so no reader takes it as that "
        f"section. Write '## {EVIDENCE_STATUS_HEADING}'."
    )


# The heading line this gate's line scan calls exact: `## Evidence Status` at
# column 0, in any letter case. `evidence_status_heading_failure` matches the
# same shape and reports only a count; this one keeps the line number, which
# is what a refusal an author can act on needs.
EXACT_STATUS_HEADING_RE = re.compile(
    rf"(?im)^## {re.escape(EVIDENCE_STATUS_HEADING)}[ \t]*$"
)


def _a_status_is_kept_out(normalized: str, block: Token) -> bool:
    """Whether a swallowed heading is keeping a pending status out of the gate's reach.

    Two places one can be. Inside the block itself, where an author wrote the
    heading and the status in one comment or one `<pre>`; and below the block,
    where the heading was swallowed by an opener a line above it and the
    status sits in ordinary markdown underneath -- which is the shape all four
    of the refusal's own cases have.

    The second is asked by giving the text a real heading and handing it to the
    gate's own two views. Nothing new reads anything here: the question "would
    this have refused, had the line been a heading?" is answered by the readers
    that would have answered it.

    That text starts after the BLOCK, not after the heading. A block prints its
    contents as characters, so a `## Notes` line inside it is text to every
    reader -- but handed to a markdown parser it is a heading, and it closed
    the synthetic section before the status below the block was reached. The
    block's own contents are the first half's job and are read there as text,
    which is the reading the page agrees with.

    Read as text, and therefore through `PRINTED_PENDING_RE`: markup inside a
    raw block is characters, so a status wrapped in backticks, asterisks or
    underscores there is a status the page prints wrapped, not one a parser
    unwraps.
    """
    if any(PRINTED_PENDING_RE.match(text) for text in html_block_text_lines(block.content)):
        return True
    below = "\n".join(normalized.split("\n")[(block.map or [0, 0])[1] :])
    probe = f"## {EVIDENCE_STATUS_HEADING}\n{below}"
    written, _ = split_fenced_blocks(extract_section(probe, EVIDENCE_STATUS_HEADING, strip=False))
    # Both sources of printed lines, in one read. The case that needs the
    # raw-block half is a SECOND raw block below the swallowing one holding an
    # unmarked status: the written view needs a list marker, and an inline run
    # contributes nothing for a raw block (#1771, round 3).
    return bool(PENDING_STATUS_RE.search(written)) or any(
        PRINTED_PENDING_RE.match(text) for text in rendered_status_lines(probe)
    )


def _swallowed_status_heading_failure(normalized: str) -> str | None:
    """Why a heading line the page shows is no heading at all, or None.

    Asked for every exact heading line the scan finds, whatever the parse made
    of the rest of the body. A line the scan calls an exact heading and the
    parser puts inside a raw HTML block is the shape this branch exists for; a
    line inside a fenced or indented code block is not, because there the page
    shows an example and no section is the honest answer.

    And only where a status is being kept out by it (`_a_status_is_kept_out`).
    A body may carry an exact heading line inside a comment it closed or a
    `<pre>` it wrote, with nothing pending under it, and that body has no
    Evidence Status section -- which is allowed, since the section is
    optional. Refusing it said an author had hidden something they had not
    hidden. The failure this branch exists to prevent is a pending line a
    swallowed heading keeps out of the section, and where there is no pending
    line there is nothing to keep out.

    The whole block is read rather than the part of it below the heading:
    slicing a block's runs by source line is the modelling this reader is
    written to avoid, and reading the whole of it errs toward refusing. Text
    inside a comment counts, the way it does everywhere else in this gate --
    a `[blocked]` under a commented-out heading refuses and names it, because
    a run this gate cannot see on the page may refuse and may never accept
    (#1729, #1744).

    The block is found by its own token rather than by re-deriving where HTML
    starts: `html_block`'s map covers the lines CommonMark gave it, which is
    the same answer `extract_section` and `rendered_status_lines` read.
    """
    tokens = MARKDOWN.parse(normalized)
    for match in EXACT_STATUS_HEADING_RE.finditer(normalized):
        line = normalized[: match.start()].count("\n")
        block = next(
            (
                token
                for token in tokens
                if token.type == "html_block" and token.map and token.map[0] <= line < token.map[1]
            ),
            None,
        )
        if block is None or not _a_status_is_kept_out(normalized, block):
            continue
        return (
            f"The heading at line {line + 1} is inside a raw HTML block (opened at line "
            f"{(block.map or [0])[0] + 1}), so no reader takes it as the section and the "
            "status under it is never read. Put a blank line between the block and the "
            "heading."
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


PENDING_FAILURE = "Requested evidence is blocked or still pending CI."
# Long enough to recognise a line by, short enough to read in a comment bullet.
MATCHED_LINE_LIMIT = 120


def matched_line_note(line: str) -> str:
    """What the gate matched, for an author who cannot see it in what they wrote."""
    shown = line if len(line) <= MATCHED_LINE_LIMIT else f"{line[: MATCHED_LINE_LIMIT - 1]}\u2026"
    return f'The page shows this line under the heading: "{shown}".'


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

    # The line scan first, since its message names the exact spelling to use;
    # the parse-backed one only where that check is satisfied, so one body
    # does not draw two failures about the same heading.
    if heading_failure := evidence_status_heading_failure(body):
        failures.append(heading_failure)
        # The swallowed heading is the exception, because it is a different
        # fact about a different line: the count says how many spellings to
        # keep, and this says a status the page prints sits inside a block no
        # reader's section reaches. An author who deletes a heading on the
        # count's advice still has the hidden status, so both are said (#1767).
        if swallowed := _swallowed_status_heading_failure(body):
            failures.append(swallowed)
    elif unread_heading := unread_status_heading_failure(body):
        failures.append(unread_heading)
    status_section = extract_section(body, EVIDENCE_STATUS_HEADING, strip=False)
    evidence_status, unclosed_fence = split_fenced_blocks(status_section)
    if unclosed_fence:
        failures.append(
            f'Evidence Status opens a code fence that never closes: "{unclosed_fence}". '
            "Close it so the status lines after it are read."
        )
    written_pending = PENDING_STATUS_RE.search(evidence_status)
    # The page first, then the source model. Both are refusers and either one
    # is enough, so the order decides only which line the failure names -- and
    # the page's line is the one an author can go and look at.
    if (drift := unicode_data_notice()) is not None:
        # Loud where a human reads it, rather than in a comment nobody runs.
        notices.append(drift)
    page = page_view(body)
    if page.unverified:
        notices.append(
            f"Rendered view unverified: {page.unverified}. The gate read this body with its "
            "source model alone, which refuses on the page's behalf but never accepts for it."
        )
    # Every printed line through one reader: the page's own text, the model's
    # resolved inline text, and the characters a raw HTML block puts on a
    # line. `page.lines` holds what GitHub's HTML shows -- the element's text
    # with its delimiter characters intact, `**[blocked]** waiting` where the
    # author wrote `\*\*[blocked]\*\*` -- and asking it a reader that allowed
    # no wrapper accepted seven shapes the page prints a status on (#1771,
    # round 4). All three sources are asked, because each holds lines the
    # other two do not.
    rendered_pending = next(
        (
            line
            for line in (*page.lines, *rendered_status_lines(body))
            if PRINTED_PENDING_RE.match(line)
        ),
        None,
    )
    if written_pending or rendered_pending is not None:
        # The written view's match is a line the author typed and can find by
        # eye. The rendered view's may not be: it reads a table cell, a decoded
        # reference, and the text a raw HTML block puts on a line, so a refusal
        # an author disagrees with is unreadable without the run that caused it
        # (#1736). Named only when the rendered view is the only one that saw
        # it, which is exactly when the author has nothing to look at.
        failures.append(
            PENDING_FAILURE
            if written_pending
            else f"{PENDING_FAILURE} {matched_line_note(rendered_pending)}"
        )

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
        lines = ["✅ **PR readiness gate passed.**"]
    else:
        lines = ["⚠️ **PR readiness gate failed** — this PR body is missing readiness signals:", ""]
        lines += [f"- {failure}" for failure in result.failures]
    # Notices belong on the PR, not only in the Actions log: the one that
    # matters here says the rendered view went unread, and a run that passed
    # without it passed a different gate from the one CI runs (#1745).
    if result.notices:
        lines += ["", *[f"- _{notice}_" for notice in result.notices]]
    if result.ok:
        return "\n".join(lines) + "\n"
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
