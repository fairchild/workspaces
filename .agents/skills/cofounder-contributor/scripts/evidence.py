"""Evidence parsing, reconciliation, and delta computation."""

from __future__ import annotations

import bisect
import json
import re
import shlex
import sys
from collections.abc import Iterable, Iterator
from itertools import islice

from _helpers import (
    GITHUB_API_TIMEOUT,
    REPO_ROOT,
    has_markdown_section,
    insert_markdown_section,
    log,
    markdown_section,
    run_optional,
    strip_markdown_section,
)

# An item's own text carries em-dashes as a matter of house style, so a
# non-greedy item group ends the item at its first internal em-dash and makes a
# correctly authored item impossible to write. Splitting is anchored on the
# contract wherever the requested items are in hand: the candidate split whose
# item IS a requested item wins, so neither half's internal punctuation can
# terminate the item. Where the contract is absent the boundary is a guess, and
# the guess is documented on `split_evidence_status_line`.
EVIDENCE_STATUS_PREFIX_RE = re.compile(
    r"^- \[(?P<status>complete|blocked|pending-ci)\] (?P<rest>.+)$"
)
# Zero-width on both sides, so two separators sharing one space still yield
# two candidate splits rather than one.
EVIDENCE_SEPARATOR_RE = re.compile(r"(?<=\s)(?:--|—|–)(?=\s)")
# Reading every candidate split is worth doing for a line a person wrote and
# pointless for one no person wrote. A GitHub body runs to 65,536 characters,
# so without a bound a single bullet decides how long the gate takes; past
# this length the line is unreadable rather than slow, which puts it in
# `invalid_lines` where the gate reports it.
EVIDENCE_STATUS_LINE_LIMIT = 4_000
# What `_normalize_evidence_key` can take off an item's ends, and so the only
# characters a candidate's key may be shorter by than the text it came from.
EVIDENCE_STRIPPABLE_CHARS = frozenset("`.,;:)")
# A status line a person wrote carries one or two candidate readings. Past
# this many the reconciler is guessing rather than reading, and it refuses to
# act on a guess -- which also stops it classifying a reading per separator on
# a line dense in them.
EVIDENCE_STATUS_READING_LIMIT = 32
# How much of the two word sets an item and an entry key must share before
# the fallback reads them as the same requirement. Measured over their union,
# so the floor tightens as the item shortens -- which is the direction that
# matters, a short item being the one a longer entry can swallow whole.
EVIDENCE_WORD_OVERLAP_FLOOR = 0.7
# A bare index is the structured-update key, not an item name. Parsed as one it
# silently becomes an entry no requested item can match -- unless the contract
# really does ask for it, which the requested items settle.
NUMERIC_EVIDENCE_ITEM_RE = re.compile(r"#?\d+\.?")
# An indented line under a bullet continues it, unless it opens a block of its
# own: another bullet, an ordered item, or a quote. `>=` is a threshold, not a
# quote marker.
MARKDOWN_BLOCK_OPENER_RE = re.compile(r"(?:[-*+]\s|\d+[.)]\s|>(?!=))")
# A fence opens with three or more backticks or tildes. A backtick fence's info
# string cannot itself contain a backtick, which is what separates an opening
# fence from a line starting with a code span.
MARKDOWN_FENCE_RE = re.compile(r"(?P<run>`{3,}|~{3,})(?P<info>.*)$")
# The three line endings markdown has. `str.splitlines` also breaks on a
# vertical tab, a form feed and four other separators, which markdown renders
# as ordinary characters -- and a fence pushed onto its own line that way is
# read as unindented, opening a block that hides every bullet below it.
MARKDOWN_LINE_ENDING_RE = re.compile(r"\r\n|\r|\n")
EVIDENCE_METADATA_RE = re.compile(
    r"^<!-- evidence-status:v(?P<version>[^\n]+)\n(?P<payload>.*?)\n-->[ \t]*(?:\n|$)",
    re.MULTILINE | re.DOTALL,
)
STRUCTURED_EVIDENCE_UPDATE_RE = re.compile(
    r"^(?P<index>\d+)\s*--\s*(?P<detail>.+)$"
)
EVIDENCE_METADATA_VERSION = 1
EVIDENCE_FALLBACK_SENTENCE = "Follow the repo evidence bar for the touched surfaces."
SWIFT_TEST_NO_MATCH_TEXT = "No matching test cases were run"
VISUAL_EVIDENCE_RE = re.compile(
    r"\b(?:screenshots?|screen recordings?|visual (?:proof|evidence)|"
    r"(?:ui|interface|screen|window) captures?|before/after (?:images?|screenshots?))\b",
    re.IGNORECASE,
)
# A `ci` item names one check in backticks and asserts it is green. Two
# shapes are accepted, both requiring a CI keyword somewhere in the item:
#
#   `Lint, Test, Build` green on the PR head      -- name, then "green"
#   `check-links` check passes on the PR head     -- name, then a CI noun,
#                                                    then a pass verdict
#
# The second shape exists because "green" is not how most people write it,
# but its verdict words are ordinary English ("passes", "succeeded") and would
# match almost any backticked token without the noun binding them. Compare
# "`pnpm check` passes locally" or "the CI regression in `isValidRepoFullName`
# passes its new cases": neither names a check, and a `ci` entry naming a check
# that does not exist never completes -- strictly worse than the `other` it
# replaced. Name-after-verdict phrasing ("job green ... (`someFunction`
# cases)") does not classify for the same reason.
CI_EVIDENCE_NOUN = r"check|job|workflow|suite|lane|run"
CI_EVIDENCE_PASS = r"pass(?:es|ing|ed)?|succeed(?:s|ing|ed)?|success(?:ful)?"
CI_EVIDENCE_NAME_RES = (
    re.compile(r"(?i)`(?P<check>[^`]+)`[^`]*\bgreen\b"),
    re.compile(
        rf"(?i)`(?P<check>[^`]+)`\s+(?:{CI_EVIDENCE_NOUN})\b[^`]{{0,24}}?"
        rf"\b(?:{CI_EVIDENCE_PASS})\b"
    ),
)
CI_EVIDENCE_KEYWORD_RE = re.compile(r"(?i)\b(?:ci|check|workflow|job)\b")
# An explicit owner directive outranks every mechanical kind. Reading "shows X
# in the PR diff (owner-attested)" as diff-verifiable would be silently
# reassigning authority the author took the trouble to name; if the contract
# is wrong, the fix is to correct the issue text. Nothing classified `other`
# today changes because of this -- it only stops future widening from
# overriding an author who said who should sign.
OWNER_ATTESTED_RE = re.compile(
    r"(?i)owner[- ]attest\w*"
    r"|\b(?:owner|maintainer)\b[^\n]{0,24}?"
    r"\b(?:attest\w*|confirm\w*|verif\w*|approv\w*|sign[- ]?off|signs? off"
    r"|judg\w*|decid\w*|agree\w*)\b"
)
# A `diff` item asserts something a reader confirms by reading the diff.
# Completion is the counterpart review itself, bound to the review URL and
# head SHA, so a reviewer always closes it -- which makes this the safer
# direction to widen. The #1377 dogfood run parked a two-line docs change on
# the owner because "shows the link in the PR diff" matched none of the
# original phrasings, though the diff was the entire proof.
#
# The verbs bind tightly to "in the diff" rather than floating: "the owner
# must be present for the sign-off described in the diff" is not a diff
# assertion, and neither is a sentence that mentions the diff only after its
# real claim. A multi-clause item whose diff phrase is a subclause can still
# classify -- the same is true of the phrasings that predate this -- but the
# reviewer completing it reads the item text, so the assertion is not
# unexamined.
DIFF_EVIDENCE_RE = re.compile(
    r"(?i)^diff:"
    r"|(?:readable|visible|apparent|evident|confirmable) (?:from|in) the (?:pr )?diff"
    r"|verifiable by reading the (?:pr )?diff"
    r"|the (?:pr )?diff (?:shows|proves|demonstrates|contains|includes)"
    r"|\b(?:shows?|contains?|includes?|appears?)\b[^\n]{0,60}?\bin the (?:pr )?diff\b"
)
# Test runners the hosted lane cannot execute. `swift test` is absent on
# purpose: the lane runs that one, so it stays kind `test` and nothing about
# it changes. Everything here is a runner a person runs, which is why the
# kind it produces completes on what the person wrote down rather than on a
# job the factory could have started.
ATTESTED_TEST_COMMAND_RE = re.compile(
    r"(?i)^(?:cd\s+[^\s&;|]+\s*&&\s*)?"
    r"(?:"
    r"(?:pnpm|npm|yarn|bun)(?:\s+(?:--dir|--filter|-C|-w)\s+\S+)*\s+(?:run\s+)?test\b"
    r"|pytest\b"
    r"|python3?\s+-m\s+(?:pytest|unittest)\b"
    r"|uv\s+run\b[^`\n]{0,80}?test"
    r")"
)
# "A test in `<path>` asserting X" and its neighbours. The item has to *open*
# with a test noun, optionally behind an article and the adjectives people
# actually write. Anchoring there is what keeps "A written audit of every exit
# path", "A captured real restart, not a unit test" and "A statement of
# whether the shared state is reachable" where they belong: those name a
# person's judgement, and no test run answers them.
ATTESTED_TEST_STATEMENT_RE = re.compile(
    r"(?i)^\**(?:a|an|one|the|each|every|all)?\s*"
    r"(?:new|added|failing|red|regression|parser|unit|integration|first|"
    r"targeted|additional|full|whole|entire|existing|named)?\s*"
    r"(?:test|tests|case|cases|spec|specs|suite|suites)\b"
    # "Case" is the word people also reach for when they mean a situation.
    # "A case where the sidebar is scrolled away and the context is still
    # readable" wants a picture, and no test run answers it -- so the noun
    # has to be doing test work somewhere in the item before it counts.
    r"[^\n]{0,120}?"
    r"(?:\bassert\w*|\bcover\w*|\bexercis\w*|\bfails? on\b|\bred before\b"
    r"|\bgreen\b|\bpass\w*|\bproves?\b|`[^`]+`)"
)
# The other half of the same shape: the item names a test file, glob or suite
# in backticks and says it passes. "Every `scripts/tests/*.py` passes under
# `uv run --script`" is the most-written evidence item in this repo and it
# classified `other`.
# A path, not a name. `build-and-test` is a CI check; `scripts/tests/*.py` is
# a place tests live. Requiring a separator or an extension is what tells them
# apart, and getting it wrong would send a check name down the attested lane
# where no check is ever polled.
# What makes a path a test path. The last alternative is deliberately
# case-sensitive inside a case-insensitive pattern: `FooTests.swift` names
# tests and `docs/latest.md` does not, and only the capital tells them apart.
TEST_PATH_TOKEN = r"(?:\btests?\b|[_./-]tests?|\btest[_-]|(?-i:[a-z0-9]Tests?)[./])"
TEST_PATH_SPAN_RE = re.compile(
    rf"`[^`\n]*/[^`\n]*{TEST_PATH_TOKEN}[^`\n]*`"
    rf"|`[^`\n]*{TEST_PATH_TOKEN}[^`\n]*\.[a-z]{{1,4}}`",
    # Case-insensitive like its neighbours: `Tests/FooTests.swift` is a test
    # path, and reading only the lowercase spelling would undercount every
    # Swift one, which is where the capital lives.
    re.IGNORECASE,
)
EVIDENCE_PASS_WORD_RE = re.compile(
    r"(?i)\b(?:pass(?:es|ed|ing)?|green|succeed(?:s|ed)?|clean)\b"
)
# A `perf` item asks for a measurement, and the measurement is the artifact.
# The planner is told to request these (`peter-planner.md`), the PR template
# enforces a Performance section, and every one of them classified `other` --
# unautomatable, blocked, parked on the owner.
PERF_EVIDENCE_RE = re.compile(
    r"(?i)\bbefore\s*(?:/|and|,|\s+to\s+)\s*after\b[^\n]{0,48}?"
    # A metric word, not "numbers": "word count before and after, both numbers
    # in the body" is a diff you can read, and routing it through the
    # Performance section would leave it pending on a section it never wanted.
    r"\b(?:measurement|metric|timing|latency|duration|delta|benchmark|perf"
    r"|baseline|throughput|cpu|memory|footprint|allocation|fps"
    r"|p50|p95|p99|ms|seconds?)"
    r"|\b(?:p50|p95|p99)\b[^\n]{0,60}?\bbefore\b[^\n]{0,24}?\bafter\b"
    r"|\bbefore/after/delta\b"
    r"|\bperf(?:ormance)?\s+(?:numbers|measurements|deltas?|baselines?|comparison)\b"
)
# Evidence a person produces by looking, waiting or deciding. A test noun in
# the item does not make it runnable: "a test protocol covering a manual
# production restart" is a protocol someone follows, and "performance
# comparison of animation smoothness judged by eye" is a person watching. Both
# stay `other`, where a person is asked for them.
MANUAL_JUDGEMENT_RE = re.compile(
    r"(?i)\b(?:manual(?:ly)?|by hand|by eye|hand-run|judged|judgement|judgment"
    r"|eyeball\w*|someone|a person|a human|protocol|walkthrough|walk-through"
    r"|dogfood\w*|play(?:ed|ing)? with)\b"
)
# A statement in the PR body that names a test runner. Unanchored: the body is
# prose about what was run, not a contract item.
TEST_RUNNER_MENTION_RE = re.compile(
    # `uv run` sits outside the group: the trailing word boundary belongs to
    # the fixed runner names, and applying it to a path would refuse
    # `uv run --script scripts/tests/test_foo.py`, where every "test" is
    # followed by a word character.
    r"\b(?:swift\s+test|(?:pnpm|npm|yarn|bun)\s+(?:run\s+)?test|pytest"
    r"|python3?\s+-m\s+(?:pytest|unittest)|go\s+test|cargo\s+test"
    r"|xcodebuild\s+test)\b"
    r"|\buv\s+run\b[^`\n]{0,80}?test",
    re.IGNORECASE,
)
# And what that runner printed. Both halves have to be present: a command with
# no result is a plan, and a result with no command is a claim nobody else can
# re-run. This is Michael's fallback bar -- "just stating the tests that ran
# and covered the feature" -- written strictly enough to check.
# Every accepted form carries a count. A runner that ran printed one, and a
# count is what separates a report from an intention: "if all tests pass,
# merge" says nothing ran, and "all tests pass" is a claim with no run behind
# it. This is the strict half of Michael's fallback bar -- what the command
# printed, not what the author expects of it.
TEST_RESULT_RE = re.compile(
    r"(?i)\bran\s+\d+\s+tests?\b"
    r"|\b\d+\s+(?:tests?|cases?|files?|examples?|assertions?|specs?|suites?)\s+"
    r"(?:pass(?:ed|ing|es)?|ok|green|succeeded)\b"
    r"|\b\d+\s+pass(?:ed|ing)\b"
    r"|\btest run with \d+ tests? passed\b"
    r"|\b\d+/\d+\s+(?:tests?|passed|green)\b"
)
# Kinds the hosted `macos-26` evidence lane can gather; `ci` and `diff`
# complete through the verifier workflow and review lane instead (#1120), and
# `test-attested` and `perf` complete on what the PR body says.
MACOS_EVIDENCE_KINDS = frozenset({"test", "build", "screenshot"})
EVENT_COMPLETED_KINDS = frozenset({"ci", "diff"})
# Kinds the macOS lane must not rewrite. `ci` and `diff` are completed by
# their own lanes off an event; `test-attested` and `perf` are completed by
# the next factory turn reading the PR body, or by the person who filled it
# editing the line. Either way the macOS lane knows nothing about them, and a
# lane resolving an item it did not gather would be inventing a result.
LANE_EXEMPT_KINDS = EVENT_COMPLETED_KINDS | frozenset({"test-attested", "perf"})
SAFE_CANDIDATE_ENV_KEYS = {
    "CI",
    "COLORTERM",
    "HOME",
    "LANG",
    "LC_ALL",
    "LOGNAME",
    "NO_COLOR",
    "PATH",
    "SHELL",
    "TEMP",
    "TERM",
    "TMP",
    "TMPDIR",
    "TZ",
    "USER",
    "XDG_CACHE_HOME",
}


def _code_span_ranges(text: str) -> list[tuple[int, int]]:
    """Half-open ranges covering each code span, by CommonMark's own rules.

    A `--` inside one is an argument rather than a boundary: `resolve_persona.py
    -- mara` is one name.

    A backtick run opens a span and the next run of equal length closes it; a
    run that finds no match is literal text. Backslash escapes hide a backtick
    in ordinary prose but do nothing inside a span, which is why this reads
    left to right rather than masking escapes up front: `\\`` opens nothing,
    while the same sequence inside a span still closes it.
    """
    ranges: list[tuple[int, int]] = []
    index, length = 0, len(text)
    while index < length:
        if text[index] == "\\":
            index += 2
            continue
        if text[index] != "`":
            index += 1
            continue
        opened = index
        while index < length and text[index] == "`":
            index += 1
        width = index - opened
        probe = index
        while probe < length:
            if text[probe] != "`":
                probe += 1
                continue
            run = probe
            while probe < length and text[probe] == "`":
                probe += 1
            if probe - run == width:
                ranges.append((opened, probe))
                index = probe
                break
    return ranges


def _evidence_status_boundaries(rest: str) -> list[tuple[int, int, str]]:
    """`(item_end, detail_start, separator)` for every reading, leftmost first.

    Offsets rather than text, because at most one reading is ever acted on and
    cutting both halves of every candidate is what made a long line quadratic.
    Span membership is a binary search over ranges the scan already returns
    ordered and disjoint, and "both halves carry something" is read off the
    line's first and last non-blank character instead of stripping two fresh
    slices per candidate. Both leave the same readings the loop always had.
    """
    spans = _code_span_ranges(rest)
    span_starts = [start for start, _ in spans]
    first_visible = len(rest) - len(rest.lstrip())
    last_visible = len(rest.rstrip())
    boundaries: list[tuple[int, int, str]] = []
    for separator in EVIDENCE_SEPARATOR_RE.finditer(rest):
        cut = separator.start()
        enclosing = bisect.bisect_right(span_starts, cut) - 1
        if enclosing >= 0 and spans[enclosing][0] < cut < spans[enclosing][1]:
            continue
        if first_visible < cut and separator.end() < last_visible:
            boundaries.append((cut, separator.end(), separator.group()))
    return boundaries


def _evidence_key_floors(rest: str, cuts: list[int]) -> list[int]:
    """The shortest key `_normalize_evidence_key` could give each prefix.

    Normalizing drops whitespace, backticks at the two ends and trailing
    `.,;:)`; nothing else leaves, and case folding only ever adds. So a prefix
    already holding more characters than the longest requested item is long
    cannot BE a requested item, whatever the rest of it says.

    Which matters because separators are matched zero-width on both sides, so
    consecutive ones share a space and a line can carry a candidate every two
    characters. Normalizing a fresh slice at each of them is quadratic in the
    line, and this reads the answer off one forward pass instead.
    """
    floors: list[int] = []
    floor, index = 0, 0
    for cut in cuts:
        while index < cut:
            char = rest[index]
            if not char.isspace() and char not in EVIDENCE_STRIPPABLE_CHARS:
                floor += 1
            index += 1
        floors.append(floor)
    return floors


def _evidence_status_items(line: str) -> Iterator[str]:
    """Every item the line could be read as, leftmost first."""
    prefix = EVIDENCE_STATUS_PREFIX_RE.match(line)
    if not prefix or len(line) > EVIDENCE_STATUS_LINE_LIMIT:
        return
    rest = prefix.group("rest")
    for item_end, _, _ in _evidence_status_boundaries(rest):
        yield rest[:item_end].strip()


def split_evidence_status_line(
    line: str,
    requested_evidence: list[str] | None = None,
) -> tuple[str, str, str] | None:
    """The one reading of a status line to act on, or None.

    The reading that wins is the one whose item IS a requested item, so an
    em-dash inside either half cannot terminate the item.

    Absent the contract the boundary is a guess. The ASCII `--` this module
    renders outranks a dash character and the FIRST of them wins, because a
    rendered line carries exactly one and a second is detail prose. With no
    ASCII separator the line is hand-written in the house style, where the item
    is what carries em-dashes, so the last one wins. A separator inside a code
    span is an argument rather than a boundary and is not a candidate at all.

    Only `reconcile_pending_ci_evidence` reads a line without the contract, and
    it refuses to act whenever the guess is load-bearing.
    """
    if len(line) > EVIDENCE_STATUS_LINE_LIMIT:
        return None
    prefix = EVIDENCE_STATUS_PREFIX_RE.match(line)
    if not prefix:
        return None
    rest, status = prefix.group("rest"), prefix.group("status")
    boundaries = _evidence_status_boundaries(rest)
    if not boundaries:
        return None
    if requested_evidence:
        wanted = {_normalize_evidence_key(item) for item in requested_evidence}
        longest = max(len(key) for key in wanted)
        floors = _evidence_key_floors(rest, [cut for cut, _, _ in boundaries])
        for (item_end, detail_start, _), floor in zip(
            reversed(boundaries), reversed(floors)
        ):
            if floor > longest:
                continue
            item = rest[:item_end].strip()
            if _normalize_evidence_key(item) in wanted:
                return status, item, rest[detail_start:].strip()
    ascii_cuts = [cut for cut in boundaries if cut[2] == "--"]
    item_end, detail_start, _ = ascii_cuts[0] if ascii_cuts else boundaries[-1]
    return status, rest[:item_end].strip(), rest[detail_start:].strip()


def _is_requested_item(item: str, requested_evidence: list[str] | None) -> bool:
    if not requested_evidence:
        return False
    key = _normalize_evidence_key(item)
    return any(_normalize_evidence_key(other) == key for other in requested_evidence)


def is_numeric_evidence_item(item: str) -> bool:
    return NUMERIC_EVIDENCE_ITEM_RE.fullmatch(item.strip()) is not None


def _fence_indent_columns(line: str) -> int | None:
    """Columns of indentation before a fence, or None if this is not one.

    CommonMark states the three-space rule in columns and counts a tab as
    advancing to the next multiple of four, so counting characters instead
    reads a tab-indented row as a fence. It also counts only spaces and tabs
    as indentation, so a row of backticks behind any other whitespace -- a
    non-breaking space is the one that turns up in pasted prose -- is a
    paragraph rendered as literal text, whatever it looks like.

    Both mistakes fail the same way: an opener with no closer takes every
    bullet below it out of the contract, and the gate then passes without
    evidence a reader can plainly see was asked for.
    """
    columns = 0
    for char in line:
        if char == " ":
            columns += 1
        elif char == "\t":
            columns += 4 - columns % 4
        elif char in "`~":
            return columns
        else:
            return None
    return None


def _is_fence_line(fence: re.Match[str]) -> bool:
    """Is this a fence at all, rather than a line starting with a code span?

    A backtick fence's info string cannot itself contain a backtick, which is
    exactly what separates the two.
    """
    return not (fence.group("run").startswith("`") and "`" in fence.group("info"))


def _fence_toggles(fence: re.Match[str], fenced: str | None) -> bool:
    """Does this fence open a block, or close the one that is open?

    A closer is the same character as its opener, at least as long, and carries
    no info string, so a shorter run or a different character cannot end a
    block it did not start.
    """
    if fenced is None:
        return True
    run, info = fence.group("run"), fence.group("info")
    return run[0] == fenced[0] and len(run) >= len(fenced) and not info.strip()


def _wrapped_bullets(section: str) -> list[str]:
    """One string per markdown bullet, with wrapped lines folded back in.

    A continuation line is indented and opens no block of its own: markdown
    reads it as part of the bullet above, so the contract reads it that way
    too. A blank line, a line at column zero, or an indented line that starts
    its own block ends the bullet, which keeps a following paragraph, nested
    list, or quote out of the item text. A fenced block -- opened at three
    columns of indentation or fewer, as CommonMark asks -- is skipped whole,
    so a bullet quoted as sample code is not read as a requested item.
    """
    bullets: list[str] = []
    open_bullet = False
    fenced: str | None = None
    for line in MARKDOWN_LINE_ENDING_RE.split(section):
        stripped = line.strip()
        fence = MARKDOWN_FENCE_RE.fullmatch(stripped)
        if fence and _is_fence_line(fence):
            # Over-indented it is code, and behind other whitespace it is
            # prose, so either way it toggles nothing -- but neither is it
            # part of the bullet above, and folding it in would put a row of
            # backticks in the item text.
            indent = _fence_indent_columns(line)
            if indent is not None and indent <= 3 and _fence_toggles(fence, fenced):
                fenced = None if fenced else fence.group("run")
            open_bullet = False
            continue
        if fenced:
            continue
        if stripped.startswith("- "):
            bullets.append(line[2:].strip())
            open_bullet = True
            continue
        if (
            open_bullet
            and stripped
            and line[:1].isspace()
            and not MARKDOWN_BLOCK_OPENER_RE.match(stripped)
        ):
            bullets[-1] = f"{bullets[-1]} {stripped}"
            continue
        open_bullet = False
    return bullets


def extract_requested_evidence(body: str) -> list[str]:
    evidence_section = markdown_section(body, "Requested Evidence")
    fallback_sentence = EVIDENCE_FALLBACK_SENTENCE.casefold()
    return [
        item
        for item in _wrapped_bullets(evidence_section)
        if item.lower() != "none" and item.casefold() != fallback_sentence
    ]


def _strip_evidence_metadata(body: str) -> str:
    stripped = EVIDENCE_METADATA_RE.sub("", body).strip()
    return re.sub(r"\n{3,}", "\n\n", stripped)


def _latest_evidence_metadata_match(body: str) -> re.Match[str] | None:
    matches = list(EVIDENCE_METADATA_RE.finditer(body))
    if not matches:
        return None
    return matches[-1]


def _extract_evidence_metadata(body: str) -> dict[str, object] | None:
    match = _latest_evidence_metadata_match(body)
    if not match:
        return None
    try:
        version = int(match.group("version"))
    except (TypeError, ValueError):
        return None
    if version != EVIDENCE_METADATA_VERSION:
        return None
    try:
        payload = json.loads(match.group("payload"))
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict):
        return None
    return payload


def _insert_evidence_metadata(body: str, payload: dict[str, object]) -> str:
    metadata = (
        f"<!-- evidence-status:v{EVIDENCE_METADATA_VERSION}\n"
        f"{json.dumps(payload, indent=2, ensure_ascii=False)}\n"
        f"-->"
    )
    cleaned = _strip_evidence_metadata(body).strip()
    pattern = r"(?m)^## Evidence Status\s*$"
    if re.search(pattern, cleaned):
        return re.sub(pattern, f"{metadata}\n\n## Evidence Status", cleaned, count=1)
    if cleaned:
        return f"{cleaned}\n\n{metadata}"
    return metadata


def _explicit_evidence_contract(requested_evidence: list[str]) -> bool:
    return bool(requested_evidence)


def _structured_evidence_entries(
    body: str,
    requested_evidence: list[str],
) -> dict[str, object] | None:
    if not _explicit_evidence_contract(requested_evidence):
        return None
    match = _latest_evidence_metadata_match(body)
    if match is None:
        return None
    try:
        version = int(match.group("version"))
    except (TypeError, ValueError):
        return {
            "section_present": has_markdown_section(body, "Evidence Status"),
            "entries": {},
            "invalid_lines": [f"metadata version '{match.group('version')}' is not a valid integer"],
            "duplicate_items": [],
            "source": "structured-invalid",
        }
    if version != EVIDENCE_METADATA_VERSION:
        return None
    try:
        payload = json.loads(match.group("payload"))
    except json.JSONDecodeError as exc:
        return {
            "section_present": has_markdown_section(body, "Evidence Status"),
            "entries": {},
            "invalid_lines": [f"metadata payload is not valid JSON: {exc.msg}"],
            "duplicate_items": [],
            "source": "structured-invalid",
        }
    if not isinstance(payload, dict):
        return {
            "section_present": has_markdown_section(body, "Evidence Status"),
            "entries": {},
            "invalid_lines": ["metadata payload must be a JSON object"],
            "duplicate_items": [],
            "source": "structured-invalid",
        }
    raw_entries = payload.get("entries")
    if not isinstance(raw_entries, list):
        return {
            "section_present": has_markdown_section(body, "Evidence Status"),
            "entries": {},
            "invalid_lines": ["metadata payload must contain an 'entries' list"],
            "duplicate_items": [],
            "source": "structured-invalid",
        }

    entries: dict[str, dict[str, str]] = {}
    duplicate_items: list[str] = []
    invalid_lines: list[str] = []
    for position, raw_entry in enumerate(raw_entries, start=1):
        if not isinstance(raw_entry, dict):
            invalid_lines.append(f"entry {position} is not an object")
            continue
        try:
            index = int(raw_entry["index"])
        except (KeyError, TypeError, ValueError):
            invalid_lines.append(f"entry {position} is missing a valid integer index")
            continue
        if index < 1 or index > len(requested_evidence):
            invalid_lines.append(
                f"entry {position} index {index} is out of range for {len(requested_evidence)} requested items"
            )
            continue
        status = str(raw_entry.get("status", "")).strip()
        detail = str(raw_entry.get("detail", "")).strip()
        if status not in {"complete", "blocked", "pending-ci"}:
            invalid_lines.append(f"entry {position} has invalid status '{status}'")
            continue
        if not detail:
            invalid_lines.append(f"entry {position} has an empty detail")
            continue
        item = requested_evidence[index - 1]
        stored_item = raw_entry.get("item")
        if stored_item is not None and str(stored_item).strip() != item:
            invalid_lines.append(
                f"entry {position} item does not match requested evidence index {index}"
            )
            continue
        if item in entries:
            duplicate_items.append(item)
            continue
        entries[item] = {
            "status": status,
            "detail": detail,
        }

    return {
        "section_present": has_markdown_section(body, "Evidence Status"),
        "entries": {} if invalid_lines else entries,
        "invalid_lines": invalid_lines,
        "duplicate_items": duplicate_items,
        "source": "structured-invalid" if invalid_lines else "structured",
    }


def extract_evidence_status_entries(
    body: str,
    requested_evidence: list[str] | None = None,
) -> dict[str, object]:
    section_present = has_markdown_section(body, "Evidence Status")
    evidence_section = markdown_section(body, "Evidence Status")
    entries: dict[str, dict[str, str]] = {}
    invalid_lines: list[str] = []
    duplicate_items: list[str] = []

    for raw_line in MARKDOWN_LINE_ENDING_RE.split(evidence_section):
        line = raw_line.strip()
        if not line:
            continue
        if not line.startswith("- "):
            invalid_lines.append(line)
            continue
        split = split_evidence_status_line(line, requested_evidence)
        if not split:
            invalid_lines.append(line)
            continue
        status, item, detail = split
        # A bare index is the structured-update key. Read as an item name it
        # becomes an entry nothing can match -- unless the contract asks for
        # exactly that, which only the requested items can say.
        if is_numeric_evidence_item(item) and not _is_requested_item(item, requested_evidence):
            invalid_lines.append(line)
            continue
        if item in entries:
            duplicate_items.append(item)
            continue
        entries[item] = {
            "status": status,
            "detail": detail,
        }

    return {
        "section_present": section_present,
        "entries": entries,
        "invalid_lines": invalid_lines,
        "duplicate_items": duplicate_items,
        "source": "markdown",
    }


def _normalize_evidence_key(text: str) -> str:
    t = text.strip().strip("`").strip()
    t = re.sub(r"\s+", " ", t).casefold()
    t = t.rstrip(".,;:)")
    return t


def _indistinguishable(texts: list[str]) -> list[str]:
    """Which of these the gate cannot tell apart, second occurrence onward.

    One entry answers one requirement, which needs both sides to be
    distinguishable. Two requested items that normalize to one key are the
    same requirement to everything downstream -- `matched` is keyed by item
    text, so byte-identical items are literally one key. Two entries that
    normalize to one key are two answers the gate cannot choose between, and
    which one a requirement takes decides its status. Either is reported as
    malformed, where the author can still fix it, rather than resolved.
    """
    seen: set[str] = set()
    duplicates: list[str] = []
    for text in texts:
        key = _normalize_evidence_key(text)
        if key and key in seen and text not in duplicates:
            duplicates.append(text)
        seen.add(key)
    return duplicates


def _match_evidence_entries(
    requested_evidence: list[str],
    entries: dict[str, dict[str, str]],
) -> tuple[dict[str, str], list[str]]:
    """Which entry proves each requested item, and which items were outbid.

    An entry proves one requirement. Matching many-to-one is how a requirement
    nobody proved reports complete: one `- [complete] alpha -- beta -- proof`
    line answered both `alpha` and `alpha -- beta`, and `proof` and `proof.`
    normalize to one key and so to one entry. `unexpected_items` sees nothing
    either, being computed from the entries claimed rather than the claims.

    Three tiers, strongest first: exact text, the same normalized key, then
    word overlap over the union of the two word sets. A tier is reached only
    by what the one above it left over, so a contract written back exactly
    normalizes nothing. Each item takes the first entry still free at its
    tier, and both sides are walked in a canonical order derived from their
    text -- what is proved depends on the contract and the body, not on the
    order either was written in. An entry's status decides the review gate,
    so which item takes which entry cannot turn on where a bullet sits.

    The assignment is deliberately not a maximum matching. Where two items
    could both be proved by swapping which entry each takes, the second is
    reported unproved instead. An earlier revision searched for that swap,
    and the augmenting walk, the per-tier re-placement rule and the candidate
    cap it needed changed nothing across every live and cross-product pair in
    the repository. Failing here costs an author one restated status line;
    the machinery cost three review rounds of its own defects.

    An item left unmatched is contested rather than merely missing when an
    entry another requirement took would have proved it: it meets the floor
    against that entry, or the entry carries all of its words -- the
    containment the rule this replaces scored 1.0 and completed on.
    """
    matched: dict[str, str] = {}
    claimed: set[str] = set()
    ordered_items = sorted(
        dict.fromkeys(requested_evidence),
        key=lambda item: (_normalize_evidence_key(item), item),
    )
    ordered_entries = sorted(entries, key=lambda key: (_normalize_evidence_key(key), key))

    def take(item: str, candidates: Iterable[str]) -> None:
        free = next((key for key in candidates if key not in claimed), None)
        if free is not None:
            matched[item] = free
            claimed.add(free)

    for item in ordered_items:
        if item in entries:
            take(item, (item,))
    unmatched = [item for item in ordered_items if item not in matched]
    if not unmatched:
        return matched, []

    # An item made only of backticks and trailing punctuation normalizes to
    # nothing, and two such strings are not the same requirement -- they are
    # two strings the gate cannot read. An empty key matches nothing, on
    # either side.
    entries_by_key: dict[str, list[str]] = {}
    for entry_key in ordered_entries:
        if normalized := _normalize_evidence_key(entry_key):
            entries_by_key.setdefault(normalized, []).append(entry_key)
    for item in unmatched:
        if normalized := _normalize_evidence_key(item):
            take(item, entries_by_key.get(normalized, ()))
    unmatched = [item for item in unmatched if item not in matched]
    if not unmatched:
        return matched, []

    # Overlap is measured over the union of the two word sets, so text the
    # entry carries and the item does not costs score. Normalized by the
    # item's own words a short item scores 1.0 against any entry containing
    # it, which is how `alpha` claimed `alpha -- beta`'s entry.
    entry_words = {key: set(_normalize_evidence_key(key).split()) for key in ordered_entries}
    item_words = {item: set(_normalize_evidence_key(item).split()) for item in unmatched}

    def overlapping(words: set[str], other: set[str]) -> bool:
        if not words or not other:
            return False
        return len(words & other) / len(words | other) >= EVIDENCE_WORD_OVERLAP_FLOOR

    for item in unmatched:
        words = item_words[item]
        if words:
            take(item, (key for key in ordered_entries if overlapping(words, entry_words[key])))

    contested = [
        item
        for item in requested_evidence
        if item not in matched
        and (words := item_words.get(item))
        and any(
            words <= entry_words[key] or overlapping(words, entry_words[key])
            for key in claimed
        )
    ]
    return matched, contested


def evaluate_evidence_accounting(body: str, requested_evidence: list[str]) -> dict[str, object]:
    if not _explicit_evidence_contract(requested_evidence):
        return {
            "section_present": has_markdown_section(body, "Evidence Status"),
            "entries": {},
            "invalid_lines": [],
            "duplicate_items": [],
            "source": "none",
            "missing_items": [],
            "contested_items": [],
            "duplicate_requested_items": [],
            "indistinguishable_entries": [],
            "blocked_items": [],
            "pending_ci_items": [],
            "complete_items": [],
            "unexpected_items": [],
            "blocked_on_evidence": "blocked on evidence" in body.casefold(),
            "contract_required": False,
        }

    # _structured_evidence_entries returns a non-None dict even when metadata is malformed
    # (source="structured-invalid"). The `or` only triggers when there is no hidden metadata
    # at all, falling back to markdown parsing.
    parsed = _structured_evidence_entries(
        body, requested_evidence
    ) or extract_evidence_status_entries(body, requested_evidence)
    entries = parsed["entries"]

    matched: dict[str, str]
    contested_items: list[str] = []
    if parsed["source"] == "structured":
        matched = {
            item: item
            for item in requested_evidence
            if item in entries
        }
    else:
        matched, contested_items = _match_evidence_entries(requested_evidence, entries)

    missing_items = [item for item in requested_evidence if item not in matched]
    blocked_items = [
        item
        for item in requested_evidence
        if item in matched and entries[matched[item]]["status"] == "blocked"
    ]
    pending_ci_items = [
        item
        for item in requested_evidence
        if item in matched and entries[matched[item]]["status"] == "pending-ci"
    ]
    complete_items = [
        item
        for item in requested_evidence
        if item in matched and entries[matched[item]]["status"] == "complete"
    ]
    matched_keys = set(matched.values())
    unexpected_items = [item for item in entries if item not in matched_keys]
    return {
        **parsed,
        "missing_items": missing_items,
        "contested_items": contested_items,
        "duplicate_requested_items": _indistinguishable(requested_evidence),
        "indistinguishable_entries": _indistinguishable(list(entries)),
        "blocked_items": blocked_items,
        "pending_ci_items": pending_ci_items,
        "complete_items": complete_items,
        "unexpected_items": unexpected_items,
        "blocked_on_evidence": "blocked on evidence" in body.casefold(),
        "contract_required": True,
    }


def _truncate(text: str, max_len: int = 80) -> str:
    text = str(text)
    if len(text) <= max_len:
        return text
    return text[: max_len - 3] + "..."


def _format_malformed_preview(invalid_lines: list[object], max_shown: int = 2) -> str:
    parts: list[str] = []
    for i, line in enumerate(invalid_lines[:max_shown]):
        parts.append(f'line {i + 1}: "{_truncate(str(line))}"')
    remaining = len(invalid_lines) - max_shown
    if remaining > 0:
        parts.append(f"{remaining} more")
    return "(" + "; ".join(parts) + ")"


def _format_missing_preview(
    missing_items: list[object], requested_evidence: list[str], max_shown: int = 3,
) -> str:
    parts: list[str] = []
    for item in missing_items[:max_shown]:
        item_str = str(item)
        try:
            idx = requested_evidence.index(item_str) + 1
        except ValueError:
            idx = "?"
        parts.append(f'[{idx}] "{_truncate(item_str)}"')
    remaining = len(missing_items) - max_shown
    if remaining > 0:
        parts.append(f"{remaining} more")
    return "; ".join(parts)


def validate_evidence_accounting(body: str, requested_evidence: list[str]) -> tuple[dict[str, object], list[str]]:
    if not requested_evidence:
        return evaluate_evidence_accounting(body, []), []
    accounting = evaluate_evidence_accounting(body, requested_evidence)
    errors: list[str] = []
    if not accounting["section_present"]:
        errors.append("missing required '## Evidence Status' section")
    invalid_lines = accounting["invalid_lines"]
    if invalid_lines:
        preview = _format_malformed_preview(invalid_lines)
        if accounting["source"] == "structured-invalid":
            errors.append(f"malformed hidden evidence metadata: {preview}")
        else:
            errors.append(
                "malformed Evidence Status entries; expected "
                "'- [complete|blocked|pending-ci] <requested_evidence item> -- <proof note>' "
                f"{preview}"
            )
    duplicate_items = accounting["duplicate_items"]
    if duplicate_items:
        parts = [f'"{_truncate(str(item))}"' for item in duplicate_items[:3]]
        remaining = len(duplicate_items) - 3
        if remaining > 0:
            parts.append(f"{remaining} more")
        preview = "; ".join(parts)
        errors.append(f"duplicate Evidence Status entries for: {preview}")
    duplicate_requested_items = accounting["duplicate_requested_items"]
    if duplicate_requested_items:
        preview = _format_missing_preview(duplicate_requested_items, requested_evidence)
        errors.append(
            "requested evidence asks for the same item more than once, and one "
            f"entry cannot prove it twice; make each item distinct: {preview}"
        )
    indistinguishable_entries = accounting["indistinguishable_entries"]
    if indistinguishable_entries:
        parts = [f'"{_truncate(str(item))}"' for item in indistinguishable_entries[:3]]
        remaining = len(indistinguishable_entries) - 3
        if remaining > 0:
            parts.append(f"{remaining} more")
        errors.append(
            "two Evidence Status entries read as the same item, so which one "
            "proves a requirement is arbitrary; make each entry distinct: "
            + "; ".join(parts)
        )
    contested_items = accounting["contested_items"]
    if contested_items:
        preview = _format_missing_preview(contested_items, requested_evidence)
        errors.append(
            "these requested items have no Evidence Status entry of their own: "
            "each is outbid for the entries it matches, reads as too many of "
            "them to name one, or is wholly contained in an entry that already "
            f"accounts for another item; give each item its own entry: {preview}"
        )
    missing_items = accounting["missing_items"]
    if missing_items:
        preview = _format_missing_preview(missing_items, requested_evidence)
        errors.append(
            "PR body must account for every requested evidence item exactly; "
            f"missing: {preview}"
        )
    if accounting["blocked_items"] and not accounting["blocked_on_evidence"]:
        errors.append(
            "blocked evidence entries require 'blocked on evidence' language in the Validation section"
        )
    if accounting["pending_ci_items"] and not accounting["blocked_on_evidence"]:
        errors.append(
            "pending-ci evidence entries require 'blocked on evidence' language in the Validation section"
        )
    return accounting, errors


def classify_evidence_error(error: str) -> str:
    if error.startswith("missing required '## Evidence Status'"):
        return "evidence_section_missing"
    if error.startswith("malformed Evidence Status entries"):
        return "evidence_format"
    if error.startswith("malformed hidden evidence metadata"):
        return "evidence_metadata"
    if error.startswith("duplicate Evidence Status entries"):
        return "evidence_duplicate"
    if error.startswith("these requested items have no Evidence Status entry"):
        return "evidence_contested"
    if error.startswith("requested evidence asks for the same item"):
        return "evidence_contract_duplicate"
    if error.startswith("two Evidence Status entries read as the same item"):
        return "evidence_duplicate"
    if "missing:" in error:
        return "evidence_missing"
    return "evidence_format"


def classify_evidence_errors(errors: list[str]) -> list[dict[str, str]]:
    return [{"category": classify_evidence_error(e), "message": e} for e in errors]


def parse_structured_evidence_updates(
    entries: object,
    *,
    requested_evidence: list[str],
    status: str,
    field_name: str,
    used_indexes: set[int],
) -> tuple[list[dict[str, object]], list[str]]:
    errors: list[str] = []
    parsed: list[dict[str, object]] = []
    if entries is None:
        return parsed, errors
    if not isinstance(entries, list):
        return parsed, [f"field '{field_name}' must be a list"]

    for raw_entry in entries:
        text = str(raw_entry).strip()
        match = STRUCTURED_EVIDENCE_UPDATE_RE.match(text)
        if not match:
            errors.append(
                f"{field_name} entries must use '<requested_evidence index> -- <proof note>' (got: {text})"
            )
            continue
        index = int(match.group("index"))
        if index < 1 or index > len(requested_evidence):
            errors.append(
                f"{field_name} index {index} is out of range for {len(requested_evidence)} requested evidence items"
            )
            continue
        if index in used_indexes:
            errors.append(f"requested evidence index {index} was listed more than once")
            continue
        used_indexes.add(index)
        parsed.append(
            {
                "index": index,
                "item": requested_evidence[index - 1],
                "status": status,
                "detail": match.group("detail").strip(),
            }
        )
    return parsed, errors


def _owner_written_entries(
    published_body: str,
    requested_evidence: list[str],
) -> dict[int, dict[str, object]]:
    """Entries in the published PR body that no longer say what the machine wrote.

    `published_body` is GitHub's copy, never a model's proposed one: a model
    asked to rewrite a PR body can write any line it likes, and reading its
    output as "what a person wrote" would let it launder a completion past the
    lane that refused it. GitHub's copy can only have been edited by someone
    with write access to the PR.

    Every lane that writes `## Evidence Status` writes the hidden metadata
    beside it in the same pass, so the two agree until a person edits the
    markdown. A line that has drifted from its metadata is a person's, and the
    revise lane replaces the whole section on every turn -- so a test summary
    an owner pasted survived exactly until the next revision. Drift is the
    only signal here that does not depend on recognising the machine's own
    phrasings, which change.

    An entry the machine never wrote is not drift, it is a first draft, so a
    body carrying no metadata preserves nothing.
    """
    if not _explicit_evidence_contract(requested_evidence) or not published_body.strip():
        return {}
    rendered = extract_evidence_status_entries(published_body, requested_evidence)
    written = rendered.get("entries")
    if not isinstance(written, dict) or rendered.get("invalid_lines"):
        return {}
    metadata = _structured_evidence_entries(published_body, requested_evidence)
    if not isinstance(metadata, dict) or metadata.get("source") != "structured":
        return {}
    machine = metadata.get("entries")
    if not isinstance(machine, dict) or not machine:
        return {}
    positions = {
        _normalize_evidence_key(item): position
        for position, item in enumerate(requested_evidence, start=1)
    }
    preserved: dict[int, dict[str, object]] = {}
    for item, entry in written.items():
        position = positions.get(_normalize_evidence_key(item))
        if position is None:
            continue
        requested = requested_evidence[position - 1]
        recorded = machine.get(requested)
        # Only an entry the machine had already written can have drifted, and
        # the status is half of what a person changes -- `[blocked]` to
        # `[complete]` with the same words after it is the commonest edit of
        # all.
        if not isinstance(recorded, dict):
            continue
        if (recorded.get("status"), recorded.get("detail")) == (
            entry.get("status"),
            entry.get("detail"),
        ):
            continue
        preserved[position] = {
            "index": position,
            "item": requested,
            "status": entry["status"],
            "detail": entry["detail"],
        }
    return preserved


def render_execution_summary_body(
    summary_body: str,
    *,
    requested_evidence: list[str],
    evidence_complete: object,
    evidence_blocked: object,
    evidence_pending_ci: object,
    published_body: str = "",
) -> tuple[str, list[str]]:
    if not _explicit_evidence_contract(requested_evidence):
        return summary_body, []

    used_indexes: set[int] = set()
    complete_entries, errors = parse_structured_evidence_updates(
        evidence_complete,
        requested_evidence=requested_evidence,
        status="complete",
        field_name="evidence_complete",
        used_indexes=used_indexes,
    )
    blocked_entries, blocked_errors = parse_structured_evidence_updates(
        evidence_blocked,
        requested_evidence=requested_evidence,
        status="blocked",
        field_name="evidence_blocked",
        used_indexes=used_indexes,
    )
    pending_ci_entries, pending_ci_errors = parse_structured_evidence_updates(
        evidence_pending_ci,
        requested_evidence=requested_evidence,
        status="pending-ci",
        field_name="evidence_pending_ci",
        used_indexes=used_indexes,
    )
    errors.extend(blocked_errors)
    errors.extend(pending_ci_errors)
    if errors:
        return summary_body, errors

    evidence_map = {
        int(entry["index"]): entry
        for entry in complete_entries + blocked_entries + pending_ci_entries
    }
    evidence_map.update(_owner_written_entries(published_body, requested_evidence))
    evidence_lines = [
        f"- [{entry['status']}] {entry['item']} -- {entry['detail']}"
        for index, entry in sorted(evidence_map.items())
    ]
    structured_entries = [
        {
            "index": entry["index"],
            "item": entry["item"],
            "status": entry["status"],
            "detail": entry["detail"],
            "kind": _evidence_item_kind(str(entry["item"])),
        }
        for _, entry in sorted(evidence_map.items())
    ]

    rendered = insert_markdown_section(
        _strip_evidence_metadata(summary_body),
        "Evidence Status",
        "\n".join(evidence_lines),
        before_heading="Validation",
    )
    rendered = _insert_evidence_metadata(
        rendered,
        {
            "entries": structured_entries,
        },
    )
    # Read off the map, not off the synthesized lists: an entry a person
    # wrote is the one that decides whether this PR is still blocked.
    blocked_like_entries = [
        entry
        for _, entry in sorted(evidence_map.items())
        if str(entry.get("status", "")) in {"blocked", "pending-ci"}
    ]
    if blocked_like_entries and "blocked on evidence" not in rendered.casefold():
        blocked_note = "; ".join(str(entry["detail"]) for entry in blocked_like_entries)
        validation = markdown_section(rendered, "Validation")
        if validation:
            validation = f"{validation.rstrip()}\n- blocked on evidence: {blocked_note}"
        else:
            validation = f"- blocked on evidence: {blocked_note}"
        rendered = insert_markdown_section(rendered, "Validation", validation, before_heading="Risks")
    return rendered, []


def _named_tests_are_green(accounting: dict[str, object]) -> bool:
    """Whether a test in the contract actually ran and passed.

    A completed `ci` item is not one: `check-links` and `actionlint` are green
    checks that run no tests, and reading them as "the tests pass" would make
    the softened verdict below available on a PR whose tests nobody ran.
    """
    return any(
        _evidence_item_kind(str(item)) in {"test", "test-attested"}
        for item in accounting.get("complete_items", [])
    )


def _needs_a_person_to_look(item: str) -> bool:
    """Whether this blocked item is one no amount of reading answers.

    A screenshot request, on-screen copy someone has to read, a protocol
    someone has to follow, a call someone has to make. `screenshot` kind
    catches the first; the other three arrive as `other`, and the phrasings
    that put them there are exactly what says a person is required.
    """
    return (
        _evidence_item_kind(item) == "screenshot"
        or VISUAL_EVIDENCE_RE.search(item) is not None
        or OWNER_ATTESTED_RE.search(item) is not None
        or MANUAL_JUDGEMENT_RE.search(item) is not None
    )


def review_evidence_gate_error(verdict: str, accounting: dict[str, object], errors: list[str]) -> str | None:
    if verdict == "request_changes":
        return None
    if errors:
        return "; ".join(errors)
    blocked_items = accounting["blocked_items"]
    if blocked_items:
        # A blocked item that needs a person to look at something is not
        # approvable: no amount of reading replaces looking. A blocked item
        # that needs nobody to look, on a PR whose named tests ran and passed,
        # is a gap a reviewer can weigh -- and `approve_with_followups` is the
        # verdict that says "approved, and here is what is still unproven". A
        # bare `approve` still means the contract is whole.
        needs_a_person = [item for item in blocked_items if _needs_a_person_to_look(str(item))]
        weighable = (
            verdict == "approve_with_followups"
            and not needs_a_person
            and _named_tests_are_green(accounting)
        )
        if not weighable:
            if needs_a_person:
                # The items the message is about, not the whole blocked set:
                # naming a mechanical item in a sentence about needing a
                # person sends the reader to the wrong line.
                preview = "; ".join(str(item) for item in needs_a_person[:3])
                return (
                    "requested evidence still needs a person to look at it and review must "
                    f"stay in request_changes; blocked: {preview}"
                )
            preview = "; ".join(str(item) for item in blocked_items[:3])
            return (
                "requested evidence is still blocked; approve_with_followups needs at least "
                "one named test complete on this head, otherwise review must stay in "
                f"request_changes; blocked: {preview}"
            )
    # Pending `diff` items do not block approve: the approving review IS the
    # verification act, and the review lane writes the completion (bound to
    # the review URL and head SHA) immediately after the approval lands.
    pending_ci_items = [
        item
        for item in accounting.get("pending_ci_items", [])
        if _evidence_item_kind(str(item)) != "diff"
    ]
    if pending_ci_items:
        preview = "; ".join(str(item) for item in pending_ci_items[:3])
        return (
            "requested evidence is pending CI and review must stay in request_changes; "
            f"pending-ci: {preview}"
        )
    return None


def _normalize_evidence_item(item: str) -> str:
    return item.strip().strip("`").strip()


def _ci_check_name(item: str) -> str | None:
    """The CI check an evidence item requires green on the PR head, or None.

    Fail-closed: CI-ish phrasing without an extractable backticked name
    stays kind `other` (blocked, owner follow-up) rather than guessing.
    """
    text = item.strip()
    if not CI_EVIDENCE_KEYWORD_RE.search(text):
        return None
    for pattern in CI_EVIDENCE_NAME_RES:
        match = pattern.search(text)
        if match is not None and match.group("check").strip():
            return match.group("check").strip()
    return None


def _is_owner_attested(item: str) -> bool:
    return OWNER_ATTESTED_RE.search(_normalize_evidence_item(item)) is not None


def _is_diff_evidence(item: str) -> bool:
    return DIFF_EVIDENCE_RE.search(_normalize_evidence_item(item)) is not None


def _is_attested_test(item: str) -> bool:
    """Whether the item names tests a person runs and reports.

    Three shapes, all of them written in this repo's issues: a command for a
    runner the hosted lane has no toolchain for, an item opening with a test
    noun, and an item naming a test file or glob and saying it passes.
    """
    # The raw item, not the normalized one: `_normalize_evidence_item` strips
    # backticks off the ends, which unbalances a code span sitting at either
    # end -- and the span is exactly what the path rule reads.
    text = item.strip()
    if MANUAL_JUDGEMENT_RE.search(text):
        return False
    if ATTESTED_TEST_COMMAND_RE.match(text.lstrip("`")):
        return True
    if ATTESTED_TEST_STATEMENT_RE.match(text):
        return True
    return bool(
        TEST_PATH_SPAN_RE.search(text) and EVIDENCE_PASS_WORD_RE.search(text)
    )


def _evidence_item_kind(item: str) -> str:
    normalized = _normalize_evidence_item(item).casefold()
    if normalized.startswith("swift test"):
        return "test"
    if normalized.startswith("swift build"):
        return "build"
    if VISUAL_EVIDENCE_RE.search(normalized):
        return "screenshot"
    if _is_owner_attested(item):
        return "other"
    if _ci_check_name(item) is not None:
        return "ci"
    if _is_diff_evidence(item):
        return "diff"
    if PERF_EVIDENCE_RE.search(normalized) and not MANUAL_JUDGEMENT_RE.search(item):
        return "perf"
    if _is_attested_test(item):
        return "test-attested"
    return "other"


def _needs_macos_evidence(requested_evidence: list[str]) -> bool:
    return any(_evidence_item_kind(item) in MACOS_EVIDENCE_KINDS for item in requested_evidence)


def _has_unautomatable_evidence(requested_evidence: list[str]) -> bool:
    return any(_evidence_item_kind(item) == "other" for item in requested_evidence)


def _needs_screenshot_evidence(requested_evidence: list[str]) -> bool:
    return any(_evidence_item_kind(item) == "screenshot" for item in requested_evidence)


def _extract_test_commands(requested_evidence: list[str]) -> list[str]:
    return [
        _normalize_evidence_item(item)
        for item in requested_evidence
        if _evidence_item_kind(item) == "test"
    ]


# How far past a runner mention the result line may sit. A command and its
# summary land within a couple of lines of each other in every shape people
# write -- a fenced block, a bullet, a sentence.
ATTESTED_TEST_WINDOW_LINES = 4
ATTESTED_TEST_QUOTE_LIMIT = 180
# The Performance section's own fields, as `.github/pull_request_template.md`
# writes them and `pr-perf-evidence.yml` enforces them.
PERF_FIELD_RE = re.compile(
    r"(?i)^\s*[-*]?\s*(?P<label>before|after|delta)\b[^:\n]{0,24}:\s*(?P<value>.+)$"
)
# A measurement, not a number. "Before Summary: issue #123" carries a digit
# and measures nothing; a unit is what makes the two sides comparable.
PERF_MEASUREMENT_RE = re.compile(
    r"(?i)[-+]?\d+(?:[.,]\d+)?\s*"
    r"(?:ms|µs|us|ns|s\b|secs?\b|seconds?\b|min\b|minutes?\b|%|percent"
    r"|[kmg]b\b|bytes?\b|fps\b|hz\b|ops\b|req\b|x\b|cores?\b|threads?\b)"
)


def _item_evidence_tokens(item: str) -> list[str]:
    """What a body statement must name to be about *this* item.

    Without this the check is body-global: one `pnpm test` sentence completes
    a `pytest` requirement sitting beside it, which is not evidence of
    anything. The runner the item names, and the paths it names, are what
    make a statement the answer to this item rather than to its neighbour.
    """
    text = item.strip()
    tokens = [
        match.group(0).casefold()
        for match in TEST_RUNNER_MENTION_RE.finditer(text)
    ]
    for span in re.finditer(r"`([^`\n]+)`", text):
        candidate = span.group(1).strip().strip("*")
        if "/" in candidate or "." in candidate:
            tokens.append(candidate.rsplit("/", 1)[-1].casefold())
    return [token for token in tokens if token]


def _attested_test_statement(body: str, item: str = "") -> str | None:
    """A statement in the PR body naming a test run and what it printed.

    Both halves are required. A command with no result is a plan; a result
    with no command is a claim nobody else can re-run. Together they are
    Michael's fallback bar -- "just stating the tests that ran and covered the
    feature" -- and they are checkable, which is why this can complete an item
    the factory has no toolchain to run.
    """
    if not body.strip():
        return None
    tokens = _item_evidence_tokens(item) if item else []
    lines = MARKDOWN_LINE_ENDING_RE.split(body)
    for index, line in enumerate(lines):
        if not TEST_RUNNER_MENTION_RE.search(line):
            continue
        if tokens and not any(token in line.casefold() for token in tokens):
            continue
        # A heading ends the statement. Reading past one would quote the
        # Performance section back as though it were a test result.
        window = []
        for follower in lines[index : index + ATTESTED_TEST_WINDOW_LINES]:
            if window and follower.lstrip().startswith("#"):
                break
            window.append(follower)
        if not TEST_RESULT_RE.search(" ".join(window)):
            continue
        quoted = [window[0]]
        if not TEST_RESULT_RE.search(window[0]):
            quoted += [
                follower for follower in window[1:] if TEST_RESULT_RE.search(follower)
            ][:1]
        flattened = " ".join(" ".join(quoted).split())
        if len(flattened) > ATTESTED_TEST_QUOTE_LIMIT:
            flattened = flattened[: ATTESTED_TEST_QUOTE_LIMIT - 1].rstrip() + "\u2026"
        return flattened
    return None


def _perf_numbers(body: str) -> str | None:
    """The before and after the PR body's Performance section carries.

    Both, or nothing: one side of a comparison measures nothing. Delta rides
    along when it is there, since it is the line a reader actually reads.
    """
    section = markdown_section(body, "Performance")
    if not section:
        return None
    found: dict[str, str] = {}
    for line in MARKDOWN_LINE_ENDING_RE.split(section):
        match = PERF_FIELD_RE.match(line)
        if match is None:
            continue
        value = match.group("value").strip()
        if not PERF_MEASUREMENT_RE.search(value):
            continue
        found.setdefault(match.group("label").casefold(), value)
    if "before" not in found or "after" not in found:
        return None
    return "; ".join(
        f"{label} {found[label]}" for label in ("before", "after", "delta") if label in found
    )


def synthesize_initial_execution_evidence(
    requested_evidence: list[str],
    *,
    visual_evidence_available: bool = True,
    body: str = "",
) -> tuple[list[str], list[str], list[str]]:
    evidence_complete: list[str] = []
    evidence_blocked: list[str] = []
    evidence_pending_ci: list[str] = []
    for index, item in enumerate(requested_evidence, start=1):
        normalized = _normalize_evidence_item(item)
        kind = _evidence_item_kind(item)
        if kind == "build":
            evidence_pending_ci.append(
                f"{index} -- self-hosted macOS evidence workflow will run `{normalized}` from the exact commit under review"
            )
        elif kind == "test":
            evidence_pending_ci.append(
                f"{index} -- self-hosted macOS evidence workflow will run `{normalized}` from the exact commit under review"
            )
        elif kind == "screenshot":
            if visual_evidence_available:
                evidence_pending_ci.append(
                    f"{index} -- self-hosted macOS evidence workflow will capture this evidence from the exact commit under review"
                )
            else:
                evidence_blocked.append(
                    f"{index} -- Xcode Cloud capture lane #1088 is not available; orchestrator or owner must provide the documented visual-evidence handshake"
                )
        elif kind == "ci":
            evidence_pending_ci.append(
                f"{index} -- named CI check `{_ci_check_name(item)}` must be green on the PR head; "
                "the factory evidence verifier completes this automatically when checks finish"
            )
        elif kind == "diff":
            evidence_pending_ci.append(
                f"{index} -- verifiable by reading the PR diff; completed by the counterpart review of the current head"
            )
        elif kind == "test-attested":
            attested = _attested_test_statement(body, item)
            if attested:
                evidence_complete.append(f"{index} -- named tests in the PR body: {attested}")
            else:
                evidence_pending_ci.append(
                    f"{index} -- the hosted lane has no toolchain for this runner; state the "
                    "command and the line it printed in this PR body, and the next factory "
                    "turn completes this entry (or edit the line yourself)"
                )
        elif kind == "perf":
            numbers = _perf_numbers(body)
            if numbers:
                evidence_complete.append(
                    f"{index} -- measured in the PR body's Performance section: {numbers}"
                )
            else:
                evidence_pending_ci.append(
                    f"{index} -- fill this PR body's Performance section with Before and "
                    "After measurements, and the next factory turn completes this entry "
                    "(or edit the line yourself)"
                )
        else:
            evidence_blocked.append(
                f"{index} -- automation cannot reconcile this evidence item automatically; owner follow-up required"
            )
    return evidence_complete, evidence_blocked, evidence_pending_ci


def safe_swift_test_command_args(command: str) -> list[str] | None:
    try:
        parts = shlex.split(command)
    except ValueError:
        return None

    if parts == ["swift", "test"]:
        return parts

    if len(parts) == 4 and parts[:3] == ["swift", "test", "--filter"] and parts[3].strip():
        return parts

    if (
        len(parts) == 3
        and parts[:2] == ["swift", "test"]
        and parts[2].startswith("--filter=")
        and parts[2] != "--filter="
    ):
        return parts

    return None


def safe_swift_build_command_args(command: str) -> list[str] | None:
    try:
        parts = shlex.split(command)
    except ValueError:
        return None
    return parts if parts == ["swift", "build"] else None


def sanitized_candidate_code_env(env: dict[str, str]) -> dict[str, str]:
    """Keep credentials out of commands that evaluate an agent-authored tree."""

    return {
        key: value
        for key, value in env.items()
        if key in SAFE_CANDIDATE_ENV_KEYS and value
    }


def _swift_test_filter_selector(command: str) -> str | None:
    parts = safe_swift_test_command_args(command)
    if parts is None or len(parts) < 3:
        return None

    if len(parts) == 4 and parts[2] == "--filter":
        return parts[3]
    if len(parts) == 3 and parts[2].startswith("--filter="):
        return parts[2].split("=", 1)[1]
    return None


def _selector_matches_test_list(selector: str, listed_tests: list[str]) -> bool:
    try:
        pattern = re.compile(selector)
    except re.error:
        return False
    return any(pattern.search(specifier) for specifier in listed_tests)


def _listed_swift_tests(env: dict[str, str]) -> list[str]:
    output = run_optional(
        ["swift", "test", "list"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    )
    return [
        line.strip()
        for line in output.splitlines()
        if line.strip() and "." in line and "/" in line
    ]


def validate_requested_test_commands(
    requested_evidence: list[str],
    env: dict[str, str],
) -> list[str]:
    commands = _extract_test_commands(requested_evidence)
    build_commands = [
        _normalize_evidence_item(item)
        for item in requested_evidence
        if _evidence_item_kind(item) == "build"
    ]
    errors = [
        "requested test evidence "
        f"`{command}` must use `swift test` or `swift test --filter <selector>`; "
        "extra flags and shell operators are not allowed"
        for command in commands
        if safe_swift_test_command_args(command) is None
    ]
    errors.extend(
        "requested build evidence "
        f"`{command}` must use exactly `swift build`; extra flags and shell operators are not allowed"
        for command in build_commands
        if safe_swift_build_command_args(command) is None
    )

    swift_filter_commands = [
        command
        for command in commands
        if _swift_test_filter_selector(command) is not None
    ]
    if not swift_filter_commands:
        return errors

    # Look up through the entrypoint module to allow mock.patch.object patching.
    _mod = sys.modules.get("run_contributor", sys.modules[__name__])
    listed_tests = _mod._listed_swift_tests(sanitized_candidate_code_env(env))
    if not listed_tests:
        log(
            "skipping `swift test list` evidence selector preflight because no Swift Testing "
            "specifiers were returned; the project may need to build first"
        )
        return errors

    for command in swift_filter_commands:
        selector = _swift_test_filter_selector(command)
        if selector is None:
            continue
        if not _selector_matches_test_list(selector, listed_tests):
            errors.append(
                f"requested test evidence `{command}` does not match any `swift test list` specifier; "
                "use a target-qualified selector such as "
                "`swift test --filter 'WorkspaceManagerTests.WorkspaceProviderTests'`"
            )
    return errors


def _format_uploaded_evidence_links(uploaded_urls: list[tuple[str, str]]) -> str:
    return ", ".join(f"[{label}]({url})" for label, url in uploaded_urls)


def _test_output_by_command(test_output: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current_command: str | None = None
    for raw_line in test_output.splitlines():
        if raw_line.startswith("$ "):
            current_command = raw_line[2:].strip()
            sections.setdefault(current_command, [])
            continue
        if current_command is not None:
            sections[current_command].append(raw_line)
    return {
        command: "\n".join(lines)
        for command, lines in sections.items()
    }


def _test_output_has_no_matching_tests(command: str, test_output: str) -> bool:
    if not test_output:
        return False
    command_output = _test_output_by_command(test_output).get(command)
    if command_output is None:
        return SWIFT_TEST_NO_MATCH_TEXT in test_output
    return SWIFT_TEST_NO_MATCH_TEXT in command_output


def _pending_ci_resolution(
    item: str,
    *,
    build_succeeded: bool,
    tests_succeeded: bool,
    smoke_succeeded: bool,
    test_output: str = "",
    screenshot_upload_succeeded: bool = False,
    screenshot_urls: list[tuple[str, str]] | None = None,
    text_upload_required: bool = False,
    text_upload_succeeded: bool = False,
    text_urls: list[tuple[str, str]] | None = None,
) -> tuple[str, str]:
    kind = _evidence_item_kind(item)
    normalized = _normalize_evidence_item(item)
    uploaded_screenshot_urls = screenshot_urls or []
    uploaded_text_urls = text_urls or []

    def text_link(prefix: str) -> str | None:
        match = next(
            ((label, url) for label, url in uploaded_text_urls if label.startswith(prefix)),
            None,
        )
        if match is None:
            return None
        label, url = match
        return f"[{label}]({url})"

    if kind == "build":
        if build_succeeded:
            if text_upload_required:
                link = text_link("build-output")
                if text_upload_succeeded and link:
                    return "complete", f"`swift build` succeeded on self-hosted macOS CI: {link}"
                return "blocked", "self-hosted macOS CI build log upload failed"
            return "complete", "`swift build` succeeded on self-hosted macOS CI"
        return "blocked", "self-hosted macOS CI `swift build` failed; see workflow logs"
    if kind == "test":
        if tests_succeeded:
            if _test_output_has_no_matching_tests(normalized, test_output):
                return "blocked", f"self-hosted macOS CI `{normalized}` matched no tests; see test-output.txt"
            if text_upload_required:
                link = text_link("test-output")
                if text_upload_succeeded and link:
                    return "complete", f"`{normalized}` succeeded on self-hosted macOS CI: {link}"
                return "blocked", "self-hosted macOS CI test log upload failed"
            return "complete", f"`{normalized}` succeeded on self-hosted macOS CI"
        return "blocked", f"self-hosted macOS CI `{normalized}` failed; see test-output.txt"
    if kind == "screenshot":
        if smoke_succeeded:
            if screenshot_upload_succeeded and uploaded_screenshot_urls:
                links = _format_uploaded_evidence_links(uploaded_screenshot_urls)
                return "complete", f"captured on self-hosted macOS CI: {links}"
            if screenshot_upload_succeeded:
                return "blocked", "self-hosted macOS CI captured screenshots but no R2 URLs were recorded; see workflow artifacts"
            return "blocked", "self-hosted macOS CI captured screenshots but R2 upload failed; see workflow artifacts"
        return "blocked", "self-hosted macOS CI screenshot capture failed; see dev-smoke-output.txt"
    return "blocked", "self-hosted macOS CI cannot reconcile this evidence item automatically"


def _render_structured_entries(body: str, updated_entries: list[object]) -> str:
    """Re-render the Evidence Status section and hidden metadata from entries."""
    rendered_entries: list[dict[str, object]] = []
    for entry in updated_entries:
        if not isinstance(entry, dict):
            continue
        try:
            index = int(entry["index"])
        except (KeyError, TypeError, ValueError):
            continue
        item = str(entry.get("item", "")).strip()
        status = str(entry.get("status", "")).strip()
        detail = str(entry.get("detail", "")).strip()
        if index < 1 or not item or status not in {"complete", "blocked", "pending-ci"} or not detail:
            continue
        rendered_entries.append(
            {
                "index": index,
                "item": item,
                "status": status,
                "detail": detail,
            }
        )

    if rendered_entries:
        reconciled = insert_markdown_section(
            _strip_evidence_metadata(body),
            "Evidence Status",
            "\n".join(
                f"- [{entry['status']}] {entry['item']} -- {entry['detail']}"
                for entry in sorted(rendered_entries, key=lambda entry: int(entry["index"]))
            ),
            before_heading="Validation",
        )
    else:
        reconciled = body
    reconciled = _insert_evidence_metadata(
        reconciled,
        {
            "entries": updated_entries,
        },
    )
    if body.endswith("\n"):
        reconciled += "\n"
    return reconciled


def update_evidence_entries(body: str, updates: dict[int, dict[str, object]]) -> str:
    """Apply per-index status/detail updates to structured evidence entries.

    Trusted-lane writers (the CI evidence verifier, review-time completion)
    use this to flip entries without hand-editing markdown. Fail-closed:
    bodies without valid structured metadata, unknown indexes, and invalid
    statuses are left unchanged.
    """
    metadata = _extract_evidence_metadata(body)
    if not isinstance(metadata, dict) or not isinstance(metadata.get("entries"), list):
        return body
    updated_entries: list[object] = []
    changed = False
    for raw_entry in metadata["entries"]:
        if not isinstance(raw_entry, dict):
            updated_entries.append(raw_entry)
            continue
        entry = dict(raw_entry)
        try:
            index = int(entry["index"])
        except (KeyError, TypeError, ValueError):
            updated_entries.append(entry)
            continue
        update = updates.get(index)
        if update is not None:
            status = str(update.get("status", entry.get("status", ""))).strip()
            detail = str(update.get("detail", entry.get("detail", ""))).strip()
            if status in {"complete", "blocked", "pending-ci"} and detail:
                entry["status"] = status
                entry["detail"] = detail
                for key in ("kind", "check_name", "verified_head_sha", "proof_url"):
                    if key in update:
                        entry[key] = update[key]
                changed = True
        updated_entries.append(entry)
    if not changed:
        return body
    return _render_structured_entries(body, updated_entries)


def check_runs_for(
    check_name: str,
    head_sha: str,
    env: dict[str, str],
) -> list[dict[str, object]] | None:
    """Every run of a named check on a commit, or None if the query failed.

    The empty list and None mean different things, and callers act on the
    difference: an empty list says GitHub knows of no check by that name on
    this head — usually a wrong name in the evidence item, which would
    otherwise wait forever — while None says the lookup itself did not
    resolve. Requires GH_REPO or a repo-resolving checkout for `gh api`.
    """
    raw = run_optional(
        [
            "gh", "api",
            "-X", "GET",
            f"repos/{{owner}}/{{repo}}/commits/{head_sha}/check-runs",
            "-f", f"check_name={check_name}",
            "-f", "filter=latest",
        ],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    )
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return None
    runs = payload.get("check_runs") if isinstance(payload, dict) else None
    if not isinstance(runs, list):
        return None
    return [run for run in runs if isinstance(run, dict)]


def latest_completed_check_run(
    check_name: str,
    head_sha: str,
    env: dict[str, str],
) -> dict[str, object] | None:
    """Most recently completed run of a named check on a commit, or None.

    Queries live check-run state so callers never trust conclusions recorded
    in a PR body.
    """
    runs = check_runs_for(check_name, head_sha, env)
    completed = [
        run for run in runs or [] if str(run.get("status", "")) == "completed"
    ]
    if not completed:
        return None
    return max(completed, key=lambda run: str(run.get("completed_at", "")))


def _macos_lane_resolves(line: str, item: str, requested_evidence: list[str] | None) -> bool:
    """Whether the macOS evidence lane may rewrite this status line.

    With the contract in hand the item is not a guess: the reading whose item
    IS a requested item won the split, and that item's own kind says which
    lane completes it. `ci` and `diff` items complete through the evidence
    verifier and the review lane, so the macOS lane leaves them alone; a bare
    index is the structured-update key unless the contract asks for it, the
    same rule `extract_evidence_status_entries` follows.

    Absent an anchored reading the boundary is a guess again, and the guess is
    not acted on where it is load-bearing. A line reading as `ci` or `diff`
    under ANY split is left alone, and so is one carrying more readings than a
    person writes -- the same refusal for the same reason, and also what keeps
    classifying every reading from costing the square of the line. Either way
    the line stays `pending-ci`, which fails the readiness gate and is visible;
    resolving it on the guess would complete it.
    """
    if _is_requested_item(item, requested_evidence):
        return _evidence_item_kind(item) not in LANE_EXEMPT_KINDS
    if is_numeric_evidence_item(item):
        return False
    readings = list(islice(_evidence_status_items(line), EVIDENCE_STATUS_READING_LIMIT + 1))
    return len(readings) <= EVIDENCE_STATUS_READING_LIMIT and not any(
        _evidence_item_kind(reading) in LANE_EXEMPT_KINDS for reading in readings
    )


def reconcile_pending_ci_evidence(
    body: str,
    *,
    requested_evidence: list[str] | None = None,
    build_succeeded: bool,
    tests_succeeded: bool,
    smoke_succeeded: bool,
    test_output: str = "",
    screenshot_upload_succeeded: bool = False,
    screenshot_urls: list[tuple[str, str]] | None = None,
    text_upload_required: bool = False,
    text_upload_succeeded: bool = False,
    text_urls: list[tuple[str, str]] | None = None,
) -> str:
    """Resolve pending-ci evidence lines after the macOS evidence job finishes.

    `ci` and `diff` kind entries are left untouched: they complete through the
    evidence verifier workflow and the review lane, not the macOS lane.

    `requested_evidence` is the contract the authoritative gate reads, and it
    anchors the markdown path the same way: where a reading of a status line
    IS a requested item, that reading is the item and its kind alone decides
    the lane. `_evidence.yml` reads it from the issue the PR closes. Absent it
    the boundary is a guess -- see `_macos_lane_resolves` for what is refused.
    """
    metadata = _extract_evidence_metadata(body)
    if isinstance(metadata, dict) and isinstance(metadata.get("entries"), list):
        updated_entries: list[object] = []
        for raw_entry in metadata["entries"]:
            if not isinstance(raw_entry, dict):
                updated_entries.append(raw_entry)
                continue
            entry = dict(raw_entry)
            item = str(entry.get("item", "")).strip()
            if (
                str(entry.get("status", "")).strip() == "pending-ci"
                and _evidence_item_kind(item) not in LANE_EXEMPT_KINDS
            ):
                status, detail = _pending_ci_resolution(
                    item,
                    build_succeeded=build_succeeded,
                    tests_succeeded=tests_succeeded,
                    smoke_succeeded=smoke_succeeded,
                    test_output=test_output,
                    screenshot_upload_succeeded=screenshot_upload_succeeded,
                    screenshot_urls=screenshot_urls,
                    text_upload_required=text_upload_required,
                    text_upload_succeeded=text_upload_succeeded,
                    text_urls=text_urls,
                )
                entry["status"] = status
                entry["detail"] = detail
            updated_entries.append(entry)
        return _render_structured_entries(body, updated_entries)

    lines = body.splitlines()
    updated: list[str] = []
    in_evidence_status = False

    for line in lines:
        if line.startswith("## "):
            in_evidence_status = line.strip() == "## Evidence Status"
            updated.append(line)
            continue
        if in_evidence_status:
            split = split_evidence_status_line(line, requested_evidence)
            if (
                split
                and split[0] == "pending-ci"
                and _macos_lane_resolves(line, split[1], requested_evidence)
            ):
                item = split[1]
                status, detail = _pending_ci_resolution(
                    item,
                    build_succeeded=build_succeeded,
                    tests_succeeded=tests_succeeded,
                    smoke_succeeded=smoke_succeeded,
                    test_output=test_output,
                    screenshot_upload_succeeded=screenshot_upload_succeeded,
                    screenshot_urls=screenshot_urls,
                    text_upload_required=text_upload_required,
                    text_upload_succeeded=text_upload_succeeded,
                    text_urls=text_urls,
                )
                updated.append(f"- [{status}] {item} -- {detail}")
                continue
        updated.append(line)

    reconciled = "\n".join(updated)
    if body.endswith("\n"):
        reconciled += "\n"
    return reconciled


def summarize_requested_evidence(requested_evidence: list[str]) -> str:
    if not requested_evidence:
        return "Evidence contract: none"
    preview = requested_evidence[:2]
    suffix = " ..." if len(requested_evidence) > 2 else ""
    return "; ".join(preview) + suffix


def format_requested_evidence_numbered(
    requested_evidence: list[str],
    *,
    indent: str,
) -> str:
    if not requested_evidence:
        return f"{indent}Evidence contract: none"
    lines = [f"{indent}Requested evidence by index:"]
    for index, item in enumerate(requested_evidence, start=1):
        lines.append(f"{indent}  [{index}] {item}")
    return "\n".join(lines)


def summarize_evidence_accounting_by_index(accounting: dict[str, object], requested_evidence: list[str]) -> str:
    if not requested_evidence:
        return "Evidence contract: none"

    def indexes(items: list[str]) -> str:
        if not items:
            return "-"
        positions = [
            str(index)
            for index, item in enumerate(requested_evidence, start=1)
            if item in items
        ]
        return ", ".join(positions) if positions else "-"

    summary = (
        "Current PR evidence: "
        f"complete [{indexes(list(accounting['complete_items']))}], "
        f"blocked [{indexes(list(accounting['blocked_items']))}], "
        f"missing [{indexes(list(accounting['missing_items']))}]"
    )
    malformed = accounting.get("invalid_lines", [])
    if accounting.get("source") == "markdown":
        return f"{summary}, malformed {len(malformed)}"
    if accounting.get("source") == "structured-invalid":
        return f"{summary}, metadata invalid"
    return summary
