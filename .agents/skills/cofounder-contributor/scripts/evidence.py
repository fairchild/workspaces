"""Evidence parsing, reconciliation, and delta computation."""

from __future__ import annotations

import bisect
import json
import re
import shlex
import sys
from collections.abc import Iterable, Iterator
from itertools import islice

from markdown_it.token import Token

from _helpers import (
    GITHUB_API_TIMEOUT,
    MARKDOWN,
    MARKDOWN_LINE_ENDING_RE,
    REPO_ROOT,
    contract_read_refusal,
    has_markdown_section,
    code_span,
    inline_text,
    insert_markdown_section,
    is_section_boundary,
    is_section_heading,
    log,
    markdown_section,
    removed_section_texts,
    placement_refusal,
    rejected_section_headings,
    reparsed_without_runaway,
    run_optional,
    section_heading_index,
    section_heading_offset,
    strip_markdown_section,
    unmovable_block,
    unterminated_block,
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
# What GitHub stores for a pull request body. A writer that goes past it does
# not write a longer body, it writes none.
PR_BODY_LIMIT = 65_536
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
# `MARKDOWN_LINE_ENDING_RE` is the three line endings markdown has, and it
# comes from `_helpers` beside the parser that shares it. `str.splitlines`
# also breaks on a vertical tab, a form feed and four other separators, which
# markdown renders as ordinary characters -- and a fence pushed onto its own
# line that way is read as unindented, opening a block that hides every bullet
# below it.
_EVIDENCE_METADATA_RE = re.compile(
    r"^<!-- evidence-status:v(?P<version>[^\n]+)\n(?P<payload>.*?)\n-->[ \t]*(?:\n|$)",
    re.MULTILINE | re.DOTALL,
)
STRUCTURED_EVIDENCE_UPDATE_RE = re.compile(
    r"^(?P<index>\d+)\s*--\s*(?P<detail>.+)$"
)
EVIDENCE_METADATA_VERSION = 1
EVIDENCE_FALLBACK_SENTENCE = "Follow the repo evidence bar for the touched surfaces."
# What a preserved status line gains, so a reader can tell an attestation
# written before this revision from one earned by it.
CARRIED_FORWARD_NOTE = "(carried forward from an earlier revision)"
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
# A `test` or `build` item opening with a backticked command, and whatever
# follows it. The documented form is the command plus what it should do --
# "`swift test --filter FooTests` passes" -- and read whole that is a
# five-word command the allowlist refuses, which aborted the run before the
# author's first commit. The span is the command; the rest is the author
# saying what they expect of it.
LEADING_CODE_SPAN_RE = re.compile(r"^(?P<ticks>`+)(?P<command>[^`]+?)(?P=ticks)")
# Everything a `test` or `build` item is allowed to say after its command:
# what the command should do, and nothing else. See
# `_remainder_is_only_a_verdict` for why this is an allowlist.
COMMAND_REMAINDER_RE = re.compile(
    r"(?i)^[\s,;:.\u2014\u2013-]*"
    r"(?:(?:must|should|has to|have to|will|to)\s+)?"
    r"(?:still\s+|all\s+|both\s+)?"
    r"(?:pass(?:es|ed|ing)?|succeed(?:s|ed|ing)?|is green|are green|green|clean"
    r"|exits? 0|runs? clean)?"
    r"(?:\s+(?:locally|cleanly|first|in ci|on this head|on the pr head"
    r"|on the exact commit(?: under review)?|from the exact commit(?: under review)?"
    # "before and after" is not a verdict: it asks for a baseline run and a
    # second one, and the lane runs the head only, so the item completed with
    # half of what it asked for.
    r"|after the change))*"
    r"[\s.!]*$"
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
    r"(?i)\bmanual(?:ly)?\s+(?:run|ran|test\w*|check\w*|verif\w+|inspect\w+|exercis\w+"
    r"|step\w*|pass|walkthrough|qa|approv\w*|sign[- ]?off)\b"
    r"|\b(?:run|ran|verified|checked|tested|inspected|exercised|driven|confirmed"
    r"|followed|performed|executed|walked|reproduced|observed|watched)"
    r"\s+(?:it\s+)?(?:manually|by hand|by eye|interactively|live|in person)\b"
    r"|\b(?:manual|test|verification|qa|acceptance|release)\s+protocol\b"
    r"|\bby (?:hand|eye)\b|\bjudge(?:d|ment|s)?\b|\bjudgment\b|\beyeball\w*"
    r"|\bsomeone\b|\ba person\b|\ba human\b|\bdogfood\w*"
    r"|\bplay(?:ed|ing)? with\b|\bwalkthrough\b|\bwalk-through\b"
    r"|\binteractively\b|\bhand-run\b"
)
# Something that happens outside this repository's test run, and that somebody
# therefore has to go and do: a smoke against a deployed app, a live endpoint,
# a restart on a real host. The test suite says nothing about any of it.
EXTERNAL_VERIFICATION_RE = re.compile(
    # The environment word alone is not enough: "unit coverage for the
    # production config" and "release notes mention the live-migration flag"
    # are mechanical. It has to be somewhere someone goes and does something.
    r"(?i)\b(?:in|on|against|from)\s+(?:the\s+)?"
    # "logging in production mode" and "the staging config" name a setting,
    # not a place someone goes.
    r"(?:production|prod|staging|canary|live|deployed)\b"
    r"(?!\s+(?:mode|config\w*|settings?|code|path|flag|branch|environment variable))"
    r"|\b(?:a|one|the)?\s*(?:real|live)\s+(?:restart|run|device|host|hardware"
    r"|machine|session|install)\b"
    r"|\bthe installed (?:app|build)\b|\binstalled build\b"
    r"|\btestflight\b|\bnotari[sz]ed\b|\bsigned (?:dmg|app|build|artifact)\b"
    r"|\bon an? (?:iphone|ipad|mac|device|phone)\b"
    r"|\bafter download(?:ing)?\b|\bfrom the download\b"
    r"|\bsmoke\s+(?:test\w*\s+)?(?:against|on|of)\b"
    r"|\b(?:verify|check|confirm)\b[^\n]{0,40}?"
    r"\b(?:endpoint|deployment|deployed build|running service)\b"
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
# A run that failed is not evidence that anything passed. "Ran 12 tests"
# followed by "FAILED (failures=2)" carries a count and a test noun, and read
# without this it completed the item and quoted only the first line.
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
# "no lint errors" and "zero failures" are pass phrasings that contain the
# words a failure is spelled with. Stripped before the failure search, they
# stop the failure pattern from swallowing the result pattern beside it --
# `TEST_RESULT_RE` accepts `no \w+ errors?`, and without this that branch was
# dead the moment a failure guard existed.
NEGATED_FAILURE_RE = re.compile(
    # The words between the negation and the noun may not themselves be a
    # failure noun: "no failures but errors=2" would otherwise be swallowed
    # whole, leaving "=2" and reading a red run as clean.
    r"(?i)\b(?:no|zero|0|without|free of)\s+"
    r"(?:(?!errors?\b|failures?\b|fail(?:s|ed|ing)?\b|warnings?\b|regressions?\b)"
    r"\w+\s+){0,2}"
    r"(?:errors?|failures?|fail(?:s|ed|ing)?|warnings?|regressions?)\b"
)


def _reports_a_failure(text: str) -> bool:
    return bool(TEST_FAILURE_RE.search(NEGATED_FAILURE_RE.sub(" ", text)))


TEST_RESULT_RE = re.compile(
    r"(?i)\bran\s+\d+\s+tests?\b"
    r"|\b(?!0\b)\d+\s+(?:tests?|cases?|files?|examples?|assertions?|specs?|suites?)\s+"
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


# `MARKDOWN` is GitHub Flavored Markdown -- CommonMark plus the tables and
# strikethrough a status line can meet -- and it comes from `_helpers` because
# the written read of a section boundary parses by the same rules. Both reads
# parse the body instead of matching lines, because a line matched by pattern
# is not always a line a reader sees.
BLOCK_NAMES = {
    "code_block": "a code block",
    "fence": "a code block",
    "html_block": "an HTML block",
    "hr": "a horizontal rule",
    "paragraph_open": "a paragraph",
    "table_open": "a table",
    "blockquote_open": "a quote",
    "heading_open": "a sub-heading",
}
def _is_machine_metadata_comment(content: str) -> bool:
    """Whether an HTML block is the factory's own evidence metadata comment and nothing else.

    Recognised by its shape, not by parsing HTML: it opens with
    `<!-- evidence-status:v1`, ends at its only `-->`, and carries no `--!>`,
    which a browser also reads as the end of a comment. It starts in the first
    column, where the factory writes it and where `_EVIDENCE_METADATA_RE` reads
    it, so an indented copy is not the metadata. A block that starts or ends
    anywhere else, or has anything after its end, is HTML like any other.
    """
    stripped = content.rstrip()
    return (
        stripped.startswith(f"<!-- evidence-status:v{EVIDENCE_METADATA_VERSION}")
        and stripped.endswith("-->")
        and stripped.count("-->") == 1
        and "--!>" not in stripped
    )


def _unreadable_inline(children: list[Token] | None) -> str | None:
    """Why a list item's inline tokens cannot be read as one status line, or None.

    The read fails closed rather than rebuilding what GitHub renders. Inline
    HTML can strike out, hide or show what sits beside it; a soft or hard break
    renders as a line break in a PR body, so the item is two lines to a reader;
    and a character reference such as `&#10;` decodes to a newline inside the
    text.
    """
    for token in children or []:
        if token.type == "html_inline":
            return f"an item carries inline HTML ({_truncate(token.content, 40)})"
        if token.type in {"softbreak", "hardbreak"}:
            return "an item runs onto a second line, which a PR body renders as a line break"
        if token.type == "text" and "\n" in token.content:
            return "an item's text decodes to a line break"
    return None


def _rendered_inline(text: str) -> str:
    """Markdown text, such as a requested item or a recorded detail, read as a status line is."""
    tokens = MARKDOWN.parseInline(text)
    return inline_text(tokens[0].children if tokens else None)


def _heading_count_refusal(count: int) -> str:
    """Why a body with no `Evidence Status` heading, or with two, has no section to read."""
    return f"a reader sees {count} `Evidence Status` headings, not one"


# The one refusal that says there is nothing here to read, as against a section
# a reader has and this read will not interpret. Built from the same function
# that produces it, so the two cannot drift apart.
NO_STATUS_HEADING_REFUSAL = _heading_count_refusal(0)


def _rendered_status_lines(body: str) -> tuple[list[str], str | None]:
    """The text of each status line GitHub renders under `## Evidence Status`, or why none can be trusted.

    A status line is a list item, bulleted or numbered, under the one heading
    whose text reads `Evidence Status`, holding a single paragraph on a single
    line; its text comes back flattened. The section runs to the next heading
    of level one or two. The read fails closed, naming the reason, on anything
    it would otherwise have to interpret: any block under the heading that is
    not a list -- an HTML block even when it holds only a comment, a code
    block, a rule, a paragraph, a table, a quote, a sub-heading -- or a nested
    block inside an item; inline HTML or a line break inside an item
    (`_unreadable_inline`); inline HTML in the heading itself; and any HTML
    before the heading other than the factory's own metadata comment, which
    can fold, strike or hide the section. HTML is never interpreted: telling
    which elements are still open is a second renderer, and it disagreed with
    GitHub.
    """
    tokens = MARKDOWN.parse(body)
    headings = [
        index
        for index, token in enumerate(tokens)
        if token.type == "heading_open"
        and " ".join(inline_text(tokens[index + 1].children).split()).casefold() == "evidence status"
    ]
    if len(headings) != 1:
        # Naming the rejected one is what turns "delete one" from a coin flip
        # into an instruction: the extra heading is the machine's repair, and
        # the author's is the one carrying the tag (#1730).
        rejected = rejected_section_headings(tokens, EVIDENCE_STATUS_HEADING)
        named = ""
        if rejected and len(headings) > 1:
            # Every tagged heading, not the first: with both of them tagged,
            # naming one left the other -- still tagged, still not read -- and
            # the author repaired, re-ran and met this refusal again.
            #
            # And what it asks for is the STATE that clears this refusal, not
            # the result of removing something. Two goes at predicting that
            # result were wrong in two different ways: subtracting rejections
            # from headings counted an `# Evidence Status` as though removing
            # a tag would leave it readable, and counting readable h2s instead
            # ignored that this refusal counts every heading whose text reads
            # as this one, at any level and any depth, so a body with one good
            # h2 and one h1 still refuses. A predicate that decides the repair
            # and a predicate that judges it have to be the same one, and the
            # honest way to say that is to describe the body to aim for
            # (#1730, round 2; the second miss found by codex, gpt-5.6-sol,
            # xhigh).
            places = [
                f"line {span[0] + 1}" if (span := tokens[index].map) else "an unknown line"
                for index, _ in rejected
            ]
            phrases = [
                f"the one on {place} carries inline HTML ({code_span(tag)})"
                for place, (_, tag) in zip(places, rejected)
            ]
            carries = phrases[0] if len(phrases) == 1 else ", ".join(phrases[:-1]) + f" and {phrases[-1]}"
            unread = "it is not read" if len(rejected) == 1 else "none of them is read"
            named = (
                f"; {carries}, and {unread} as the section. Leave exactly one heading whose "
                "text reads as `Evidence Status` -- top level, an h2, and carrying no tags"
            )
        return [], f"{_heading_count_refusal(len(headings))}{named}"
    start = headings[0]
    if tokens[start].tag != "h2":
        return [], f"the `Evidence Status` heading is an {tokens[start].tag}, not an h2"
    if any(child.type == "html_inline" for child in tokens[start + 1].children or []):
        return [], "the `Evidence Status` heading carries inline HTML, which can strike or hide the section"
    for token in tokens[:start]:
        if (token.type == "html_block" and not _is_machine_metadata_comment(token.content)) or any(
            child.type == "html_inline" for child in token.children or []
        ):
            return [], "HTML before the heading can fold or hide the section, so the read does not interpret it"
    lines: list[str] = []
    index = start + 3
    while index < len(tokens):
        token = tokens[index]
        if token.type == "heading_open" and token.tag in {"h1", "h2"}:
            break
        if token.type not in {"bullet_list_open", "ordered_list_open"}:
            name = BLOCK_NAMES.get(token.type, f"a {token.type}")
            return [], f"{name} sits under the heading, and only list items are read as status lines"
        close, level = token.type.replace("_open", "_close"), token.level
        index += 1
        while not (tokens[index].type == close and tokens[index].level == level):
            item = [tokens[index + offset].type for offset in range(5) if index + offset < len(tokens)]
            if item != ["list_item_open", "paragraph_open", "inline", "paragraph_close", "list_item_close"]:
                if item[1:2] == ["html_block"]:
                    return [], "an item holds an HTML block, which the read does not interpret"
                return [], "a list item under the heading holds something besides one line of text"
            children = tokens[index + 2].children
            refusal = _unreadable_inline(children)
            if refusal:
                return [], refusal
            lines.append(inline_text(children).strip())
            index += 5
        index += 1
    return lines, None


def _text_after_html_comment(content: str) -> list[str]:
    """What a reader sees of an HTML block that is a closed comment with text beside it.

    A comment renders as nothing, but an `html_block` is a run of raw HTML that
    runs to a blank line and carries whatever shares its lines. GitHub hides the
    comment and prints the rest, so printing the rest is the only reading that
    agrees with the page. It comes back as written: markdown is not processed
    inside a raw HTML block, so a code span there is backticks a reader sees.

    Anything else comes back empty -- an unclosed comment, a `<div>`, an element
    wrapping its text. Telling which elements are still open is a second
    renderer, and the file already records that the one we had disagreed with
    GitHub (`_rendered_status_lines`).
    """
    stripped = content.lstrip()
    if not stripped.startswith("<!--"):
        return []
    end = stripped.find("-->")
    if end < 0:
        return []
    return [line.strip() for line in stripped[end + 3 :].splitlines() if line.strip()]


def _rendered_section_span(
    tokens: list[Token], heading: str, lines: list[str] | None = None
) -> tuple[int, int, int | None] | None:
    """Where the section under `## <heading>` starts and stops, in tokens and in source lines.

    The heading is the one `section_heading_index` finds, which is the call
    the written read makes: an h2 at the top of the body whose text a reader
    sees as this heading, not one nested inside a list, and the first such
    heading wins. `is_section_heading` is that level and `is_section_boundary`
    is where the section stops, which are two questions rather than one -- an
    h1 ends a section without being a section this addresses (#1734). Written
    twice, the two agreed about the END and could still disagree about where
    the section STARTED -- a fenced `## Evidence Status` above the real one
    was the written read's section and not this one's (#1730).

    The section ends where `is_section_boundary` says it does, which is the
    same call the written read makes on the same tokens -- so the two views
    cannot look at different spans. Ending earlier than the written read does
    would drop a Before or an After that read still sees.

    The third element is a source line to stop at inside the last token, which
    only an unclosed fence produces: it holds every heading below it, so the
    boundary is a line rather than a token and `reparsed_without_runaway` --
    the same call the written read and the writer make -- finds it. `lines`
    is the body split on its line endings; without it the exception is not
    applied, which is the reading a caller wanting the whole token span wants.
    """
    index = section_heading_index(tokens, heading)
    if index is None:
        return None
    token = tokens[index]
    start = index + 3
    stop = next(
        (offset for offset in range(start, len(tokens)) if is_section_boundary(tokens[offset])),
        len(tokens),
    )
    swallowed = None
    if lines is not None and token.map:
        repaired = reparsed_without_runaway(tokens, lines)
        if repaired is not None:
            swallowed = next(
                (
                    other.map[0]
                    for other in repaired
                    if other.map and other.map[0] >= token.map[1] and is_section_boundary(other)
                ),
                None,
            )
    return start, stop, swallowed


def _rendered_lines(body: str, heading: str | None = None) -> list[str]:
    """The body as the lines a reader sees, or only the section under `heading`.

    The statement of what ran and the Performance measurements are read from
    here, so the factory and the reader are looking at the same text. An HTML
    block or an inline tag renders nothing and contributes nothing; a code
    block renders and contributes its content, because `pr-evidence.sh` writes
    `perf-compare.py`'s comparison lines inside a fence and those lines are the
    numbers.

    Everything the readers read structurally survives. A heading keeps its
    hashes, so a statement still ends at the next heading; a list item keeps
    its marker, so a comparison line still starts with a bullet; a line break
    inside a paragraph stays a line break, which is what a PR body renders one
    as. Blank lines come from the source map rather than from a rule about
    what usually separates blocks, so two bullets written one under the next
    stay one under the next: the window that binds a result to the run above
    it spans the same statement it spanned when this read the body raw.
    """
    tokens = MARKDOWN.parse(_lf(body))
    stop_line: int | None = None
    if heading is None:
        start, stop = 0, len(tokens)
    else:
        span = _rendered_section_span(tokens, heading, MARKDOWN_LINE_ENDING_RE.split(body))
        if span is None:
            return []
        start, stop, stop_line = span

    lines: list[str] = []
    marker: str | None = None
    counters: list[int] = []
    row: list[str] | None = None
    source_end: int | None = None

    def emit(token: Token, texts: list[str]) -> None:
        nonlocal marker, source_end
        if token.map:
            if source_end is not None and token.map[0] > source_end:
                lines.append("")
            source_end = token.map[1]
        prefix, marker = marker or "", None
        for offset, text in enumerate(texts):
            lines.append(f"{prefix if offset == 0 else ' ' * len(prefix)}{text}".rstrip())

    index = start
    while index < stop:
        token = tokens[index]
        kind = token.type
        if kind == "ordered_list_open":
            counters.append(int(token.attrGet("start") or 1) - 1)
        elif kind == "bullet_list_open":
            counters.append(0)
        elif kind in {"bullet_list_close", "ordered_list_close"}:
            if counters:
                counters.pop()
        elif kind == "list_item_open":
            if counters:
                counters[-1] += 1
            marker = f"{counters[-1]}. " if token.markup not in {"-", "*", "+"} and counters else "- "
        elif kind == "list_item_close":
            marker = None
        elif kind == "heading_open":
            # Every heading comes back with hashes, including one the author
            # underlined rather than wrote with them, and its lines come back
            # as the one line a heading is.
            #
            # Emitting an underlined heading as the author's own plain lines
            # was tried and reverted (#1723, round 2). It reads as more
            # faithful and it loosens two gates: splitting the lines pushed a
            # NOT_RUN disclaimer out of the window that binds a count to the
            # run above it, and a `Before:` line under an underline became a
            # measurement while the heading it formed still ended the section.
            # Hashes on a heading nobody hashed are the smaller wrong: no
            # reader is shown them, and a statement still ends there.
            text = inline_text(tokens[index + 1].children)
            emit(token, [f"{'#' * int(token.tag[1:])} {text}".rstrip()])
            index += 3
            continue
        elif kind == "paragraph_open":
            emit(token, inline_text(tokens[index + 1].children, break_text="\n").split("\n"))
            index += 3
            continue
        elif kind in {"fence", "code_block"}:
            code = token.content.splitlines() or [""]
            if stop_line is not None and token.map:
                # A fence with no closing line runs to the end of the body, so
                # the section stops partway through this one token.
                first = token.map[0] + (1 if kind == "fence" else 0)
                code = code[: max(stop_line - first, 0)]
            emit(token, code)
        elif kind == "html_block":
            # The block renders nothing, but text sharing its lines after a
            # closed comment does. Either way the lines it occupied are not a
            # gap between the blocks around it.
            beside = _text_after_html_comment(token.content)
            if beside:
                emit(token, beside)
            elif token.map:
                source_end = token.map[1]
        elif kind == "tr_open":
            row = []
        elif kind == "tr_close":
            emit(token, [" | ".join(row or [])])
            row = None
        elif kind == "inline" and row is not None:
            row.append(inline_text(token.children).strip())
        index += 1
    return lines


def _requested_evidence_items(section: str) -> list[str]:
    """The items a `## Requested Evidence` section lists, from the section's text.

    Taken out of the contract reader so the refusal can ask what the two
    readings of the section actually list, rather than whether a heading of a
    given kind sits between them.
    """
    fallback_sentence = EVIDENCE_FALLBACK_SENTENCE.casefold()
    return [
        item
        for item in _wrapped_bullets(section)
        if item.lower() != "none" and item.casefold() != fallback_sentence
    ]


def requested_evidence_contract(body: str) -> tuple[list[str], str | None]:
    """What this issue asks the pull request to prove, or why it cannot be read.

    The items and the reason come back together, and there is no way to ask
    for one without the other, because a caller that read a truncated contract
    as the whole of it would stop demanding the items below the cut -- an
    author could drop an obligation by writing a heading in the middle of the
    section, with nothing on the page or in the run saying so
    (`contract_read_refusal`). Every reader of this contract refuses instead:
    admission does not admit, the review gate does not approve, delivery does
    not deliver.
    """
    refusal = contract_read_refusal(body, "Requested Evidence", _requested_evidence_items)
    if refusal is not None:
        return [], refusal
    return _requested_evidence_items(markdown_section(body, "Requested Evidence")), None


def _lf(body: str) -> str:
    """The body with one kind of line ending, which is the only kind `_EVIDENCE_METADATA_RE` matches.

    GitHub stores a PR body with whatever endings the client sent, and the
    metadata pattern is anchored on `\n`. Every function that reads or
    rewrites the metadata normalises through here, so two of them cannot
    disagree about which blocks a body carries: a reader that sees a CRLF
    block beside a writer that cannot strip it leaves two blocks behind, and
    which one is authoritative then decides whether a named check is
    re-verified.
    """
    return MARKDOWN_LINE_ENDING_RE.sub("\n", body)


def _strip_evidence_metadata(body: str) -> str:
    stripped = _EVIDENCE_METADATA_RE.sub("", _lf(body)).strip()
    return re.sub(r"\n{3,}", "\n\n", stripped)


def _latest_evidence_metadata_match(body: str) -> re.Match[str] | None:
    matches = list(_EVIDENCE_METADATA_RE.finditer(_lf(body)))
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
    except (ValueError, RecursionError):
        # Not only JSONDecodeError: past 4300 digits `json.loads` refuses to
        # build the integer and raises the plain ValueError, and a deeply
        # nested payload exhausts the stack. The body this reads is
        # PR-editable, and either one escaped and took the lane with it.
        return None
    if not isinstance(payload, dict):
        return None
    return payload


def _insert_evidence_metadata(body: str, payload: dict[str, object]) -> str:
    metadata = (
        f"<!-- evidence-status:v{EVIDENCE_METADATA_VERSION}\n"
        # The payload is cleaned rather than escaped. A JSON-escaped lone
        # surrogate re-emits as invalid UTF-8 and every writer of this body
        # raises UnicodeEncodeError on it -- but escaping everything to ASCII
        # to avoid that turns 6,000 emoji into 78,000 characters, past what
        # GitHub will store. Dropping what cannot be encoded costs one
        # character and leaves the rest as it was written.
        f"{json.dumps(_encodable_payload(payload), indent=2, ensure_ascii=False)}\n"
        f"-->"
    )
    cleaned = _strip_evidence_metadata(body).strip()
    # Above the heading the page shows, not above the first line that looks
    # like one: a body documenting the section in a fenced example took the
    # comment inside the fence, where it is text a reader sees and no metadata
    # any run can find (#1730). `section_heading_offset` is the same reader
    # the writer and the gate use.
    at = section_heading_offset(cleaned, EVIDENCE_STATUS_HEADING)
    if at is not None:
        return f"{cleaned[:at]}{metadata}\n\n{cleaned[at:]}"
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
    except (ValueError, RecursionError) as exc:
        # See `_extract_evidence_metadata`. `msg` is a `JSONDecodeError`
        # attribute, so the other two classes need their own text.
        detail = getattr(exc, "msg", None) or str(exc) or type(exc).__name__
        return {
            "section_present": has_markdown_section(body, "Evidence Status"),
            "entries": {},
            "invalid_lines": [f"metadata payload is not valid JSON: {detail}"],
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
    kinds: dict[str, str] = {}
    duplicate_items: list[str] = []
    invalid_lines: list[str] = []
    for position, raw_entry in enumerate(raw_entries, start=1):
        if not isinstance(raw_entry, dict):
            invalid_lines.append(f"entry {position} is not an object")
            continue
        try:
            index = int(raw_entry["index"])
        except (KeyError, TypeError, ValueError, OverflowError):
        # OverflowError too: `1e9999` in the PR-editable metadata parses as
        # infinity, and `int()` of that raises a class the other two do not
        # cover.
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
        if isinstance(raw_entry.get("kind"), str):
            kinds[item] = raw_entry["kind"].strip()

    return {
        "section_present": has_markdown_section(body, "Evidence Status"),
        "entries": {} if invalid_lines else entries,
        "kinds": {} if invalid_lines else kinds,
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


def _rendered_markdown_entries(
    body: str,
    requested_evidence: list[str],
) -> tuple[dict[str, object], str | None]:
    """Evidence Status entries from a body with no evidence metadata, read as GitHub renders them.

    Also returns why the section cannot be read, when a section is there. The
    lines come from `_rendered_status_lines`, so every refusal the owner read
    has applies without metadata too: HTML before or in the heading, an HTML
    block, inline HTML, a line break or a decoded newline in an item, and any
    block that is not a list. An unreadable section yields no entries, so
    nothing in it completes. The line grammar and the entry shape are the ones
    `extract_evidence_status_entries` produces.
    """
    section_present = has_markdown_section(body, "Evidence Status")
    entries: dict[str, dict[str, str]] = {}
    invalid_lines: list[str] = []
    duplicate_items: list[str] = []
    lines, unreadable = _rendered_status_lines(body)
    if unreadable is None:
        rendered_items = [_rendered_inline(item) for item in requested_evidence]
        for text in lines:
            line = f"- {text}"
            split = split_evidence_status_line(line, rendered_items)
            if not split or (is_numeric_evidence_item(split[1]) and not _is_requested_item(split[1], rendered_items)):
                invalid_lines.append(line)
                continue
            status, item, detail = split
            if item in entries:
                duplicate_items.append(item)
                continue
            entries[item] = {"status": status, "detail": detail}
    parsed = {
        "section_present": section_present,
        "entries": entries,
        "invalid_lines": invalid_lines,
        "duplicate_items": duplicate_items,
        "source": "markdown",
    }
    # Reported when a reader has a heading to refuse, which is a different
    # question from `section_present`: a heading carrying inline HTML is on the
    # page and is not this section (`section_heading_index`), and the reason it
    # cannot be read is exactly what its author needs to see. Only a body with
    # no such heading at all is silent, and that is the one refusal this read
    # gives for having nothing to read.
    return parsed, None if unreadable == NO_STATUS_HEADING_REFUSAL else unreadable


# What completes each kind when there is no metadata, for the item a hand-written
# `[complete]` line cannot complete by itself.
HAND_COMPLETION_REFUSALS = {
    "ci": "its named check completes it once green on the PR head; a hand-written line does not",
    "diff": "the approving review completes it; a hand-written line does not",
    "test": "the evidence lane completes it by running the command; a hand-written line does not",
    "build": "the evidence lane completes it by running the build; a hand-written line does not",
    "screenshot": "the evidence lane or an inspected screenshot completes it; a hand-written line does not",
    "test-attested": "state the command and the line it printed in the PR body; the status line alone does not complete it",
    "perf": "fill the Performance section with before and after measurements; the status line alone does not complete it",
}
# What to add when the measurements are there and the page does not show them
# in the section. Nothing is wrong with the numbers, so a refusal that only
# says the section is unfilled sends the author to the wrong place (#1723).
PERF_UNDERLINED_MEASUREMENT_NOTE = (
    "; the line above the rule or underline below it is read as a heading, "
    "because a run of dashes or equals signs directly under a line of text "
    "underlines it -- put a blank line between the last measurement and that "
    "line"
)
# How hard each kind is to complete by hand: an `other` item completes from its
# own line, a `test-attested` or a `perf` item from a proof form elsewhere in
# the body, and every other kind only from a lane, a check or a review.
HAND_COMPLETION_STRICTNESS = {"other": 0, "test-attested": 1, "perf": 1}
# The kinds a form in the body completes, as against a lane, a check or a review.
PROOF_FORM_KINDS = ("test-attested", "perf")
SPLIT_KIND_NOTE = "; the item's wording classifies two ways, so the stricter kind decides"


def _hand_completion_kind(item: str) -> tuple[str, bool]:
    """The kind that decides whether a hand-written line completes this item, and whether its wording classifies two ways.

    Two texts are read for one item. The contributor records the kind from the
    item as the issue writes it, and a status line is matched against the item
    as it renders, which drops inline HTML and emphasis. `<span
    title="screenshots"></span>The new sidebar renders` is a screenshot to the
    first reading and an owner's item to the second; a bold `swift test` item
    is the owner's to the first and a lane's to the second.

    Neither reading is the true one, so where they disagree the stricter one
    decides: a kind only a lane, a check or a review completes over one a
    statement or the Performance section completes, and either over `other`.
    Two kinds of equal strictness are both proof-bearing, and the recorded
    reading is kept. The caller says so in its refusal, since the fix is to
    write the item one way.
    """
    raw = _evidence_item_kind(item)
    rendered = _evidence_item_kind(_rendered_inline(item))
    if raw == rendered:
        return raw, False
    return max(raw, rendered, key=lambda kind: HAND_COMPLETION_STRICTNESS.get(kind, 2)), True


def _proof_form_completion(body: str, item: str, kind: str) -> str | None:
    """The proof in the body that completes an item of this kind, or None.

    A `test-attested` item completes on the statement of what ran and a `perf`
    item on the Performance section's measurements, the forms the contributor
    itself accepts. Both read the item as it renders, the text a status line is
    matched against. Every other kind has a lane, a check or a review, and
    nothing written in the body stands in for those.

    Both reads of the section come here, so a body that completes an item
    without its metadata completes it with the metadata too.
    """
    rendered = _rendered_inline(item)
    if kind == "test-attested":
        return _attested_test_statement(body, rendered)
    if kind == "perf":
        return _perf_numbers(body, rendered)
    return None


def _hand_completion_refusal(body: str, item: str, line_item: str) -> str | None:
    """Why a hand-written `[complete]` does not complete this item, or None when it does.

    With no metadata there is no recorded kind, so the item is classified the
    way the contributor classifies it when it records one and as the line was
    matched against it, with the stricter reading deciding where the two
    disagree (`_hand_completion_kind`): emphasis around a command does not make
    a lane item the owner's, and inline HTML the render drops does not either.
    Only an owner's
    `other` item completes from its line, and only a line that names it as it
    is written, the key the owner read uses: a loosely restated line can be a
    different item to a reader. A `test-attested` item completes on the
    statement of what ran and a `perf` item on its measurements, the forms the
    contributor itself accepts; every other kind has a lane, a check or a
    review that completes it, and a hand-written line is none of those.
    """
    rendered = _rendered_inline(item)
    kind, split = _hand_completion_kind(item)
    if kind == "other":
        if _normalize_evidence_key(line_item) == _normalize_evidence_key(rendered):
            return None
        return "the line does not name this item as it is written, so a hand-written completion is not read"
    if _proof_form_completion(body, item, kind):
        return None
    refusal = HAND_COMPLETION_REFUSALS.get(kind, "a hand-written line does not complete this kind of item")
    if kind == "perf" and _perf_underlined_measurement(body):
        refusal += PERF_UNDERLINED_MEASUREMENT_NOTE
    return refusal + SPLIT_KIND_NOTE if split else refusal


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


def evaluate_evidence_accounting(body: str, requested_evidence: list[str], *, review_ci: list[dict] | None = None) -> dict[str, object]:
    # Every read below takes `\n` line endings. The metadata pattern matches no
    # other, and a CRLF or CR metadata comment it misses would send the body to
    # the hand-written read, where a lane item the metadata records as pending
    # completes from its visible line.
    body = MARKDOWN_LINE_ENDING_RE.sub("\n", body)
    if not _explicit_evidence_contract(requested_evidence):
        return {
            "section_present": has_markdown_section(body, "Evidence Status"),
            "entries": {},
            "invalid_lines": [],
            "duplicate_items": [],
            "source": "none",
            "matched": {},
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
    # (source="structured-invalid"). Only with no hidden metadata at all does the read fall
    # back to the visible section, and then it reads it as GitHub renders it.
    parsed = _structured_evidence_entries(body, requested_evidence)
    fallback_unreadable: str | None = None
    if parsed is None:
        parsed, fallback_unreadable = _rendered_markdown_entries(body, requested_evidence)
    entries = parsed["entries"]
    # For an owner's item the visible line is the record, as soon as it is
    # written. No lane completes an `other` item: the machine writes it
    # blocked and asks the owner to rewrite the line. Anyone with write access
    # to the body can write that line, and they are also the only way the
    # item ever completes -- in the line or in the metadata beside it -- so
    # reading it grants nothing that was not already theirs. Waiting for a
    # factory turn to copy it into the metadata strands the PR instead, since
    # the approval that turn waits on is refused by this accounting.
    #
    # Which items are the owner's is the kind the contributor wrote into the
    # metadata when it rendered them, never a fresh reading of the wording:
    # that reading is a heuristic, and a different answer at review time would
    # hand a lane's item to a hand edit. With no kind recorded, nothing is.
    #
    # Every other kind reads as the metadata says. There, the only signal a
    # line was hand-edited is that it differs from the metadata, which any PR
    # author or bot can produce, and reading it would clear an item a lane
    # refused or nothing ran. Authority has to come from who wrote the edit,
    # and nothing in a body string says that; `render_execution_summary_body`
    # carries such a line forward on the next factory turn.
    #
    # A section that cannot be read as anyone's -- two headings a reader sees,
    # a line that is not an entry, two lines for one item -- does not agree
    # with the metadata by default. An owner item there stays unfinished,
    # because the unreadable line may be the owner's `[blocked]`.
    #
    # The recorded kind is read from the item as the issue writes it, and this
    # section is read as it renders. An item whose two readings disagree is
    # taken at its stricter one, so a lane item recorded `other` is not the
    # owner's to complete from a line.
    kinds = parsed.get("kinds") or {}
    owner_items = [item for item in requested_evidence if kinds.get(item) == "other" and _hand_completion_kind(item)[0] == "other"]
    written, unreadable = _read_owner_section(body, requested_evidence)
    for entry in written.values():
        item = str(entry["item"])
        if item in owner_items:
            entries[item] = {"status": str(entry["status"]), "detail": str(entry["detail"])}
    if unreadable:
        for item in owner_items:
            if entries.get(item, {}).get("status") == "complete":
                entries[item] = {
                    "status": "blocked",
                    "detail": f"the Evidence Status section cannot be read as the owner's: {unreadable}",
                }

    # An item the metadata records as the owner's whose wording decides a kind a
    # proof form completes has no other route left: its line is not read as the
    # owner's, and no lane owns a kind the contributor never recorded. The
    # body's own statement or Performance numbers complete it, through the same
    # call the hand-written read makes. A completion already recorded stands, a
    # lane or a factory turn having written it.
    for item in requested_evidence:
        if kinds.get(item) != "other" or item in owner_items:
            continue
        decided, split = _hand_completion_kind(item)
        if decided not in PROOF_FORM_KINDS or entries.get(item, {}).get("status") == "complete":
            continue
        proof = _proof_form_completion(body, item, decided)
        if proof:
            entries[item] = {"status": "complete", "detail": proof}
        else:
            refusal = HAND_COMPLETION_REFUSALS[decided]
            entries[item] = {"status": "blocked", "detail": refusal + SPLIT_KIND_NOTE if split else refusal}

    matched: dict[str, str]
    contested_items: list[str] = []
    if parsed["source"] == "structured":
        matched = {
            item: item
            for item in requested_evidence
            if item in entries
        }
    else:
        # The lines were read as rendered text, so each item is matched as
        # rendered too: `**item**` and `item` share a key. Two items that render
        # alike are one requirement to the matcher; the one written without
        # markup takes the line, then the canonical order, never contract order.
        rendered: dict[str, str] = {}
        for item in sorted(requested_evidence, key=lambda item: (_rendered_inline(item) != item, _normalize_evidence_key(item), item)):
            rendered.setdefault(_rendered_inline(item), item)
        by_rendered, contested = _match_evidence_entries(list(rendered), entries)
        matched = {rendered[text]: key for text, key in by_rendered.items()}
        contested_items = [rendered[text] for text in contested]
        # Every line in a body with no metadata is hand-written, so the kind rule
        # decides what a `[complete]` there completes (`_hand_completion_refusal`).
        # Matching still assigns each line to one item; this only decides whether
        # the line completes it.
        for item, key in matched.items():
            if entries[key]["status"] != "complete":
                continue
            refusal = _hand_completion_refusal(body, item, key)
            if refusal:
                status = "blocked" if _hand_completion_kind(item)[0] == "other" else "pending-ci"
                entries[key] = {"status": status, "detail": refusal}

    # This overlay exists only in review. Authoring validation still requires
    # authored accounting; current GitHub check facts can satisfy a named CI item
    # without inventing a PR-body citation or renumbering the original contract.
    live_satisfied: set[str] = set()
    for fact in review_ci or []:
        index = fact.get("index")
        if (type(index) is not int or not 1 <= index <= len(requested_evidence)
                or fact.get("item") != requested_evidence[index - 1]
                or fact.get("status") != "satisfied"
                or fact.get("automatic_completion") is not True
                or _review_ci_check_name(requested_evidence[index - 1]) is None):
            continue
        item = requested_evidence[index - 1]
        key = matched.get(item, item)
        entries[key] = {"status": "complete", "detail":
            f"Live named check {fact['check_name']} succeeded on {fact['head_sha']} (run {fact['run_id']}; {fact['url']})."}
        matched[item] = key
        live_satisfied.add(item)
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
    unproven_items = [
        item
        for item in complete_items
        if _detail_proves_nothing(
            item,
            str(entries[matched[item]].get("detail", "")),
            owner=item in owner_items or _evidence_item_kind(item) == "other",
        )
    ]
    return {
        **parsed,
        # Which entry proves each requested item. The lists below say what each
        # item's verdict is; this says where it came from, which is what a
        # writer needs to record an item as the body already reads it.
        "matched": matched,
        "unproven_items": unproven_items,
        "owner_section_unreadable": unreadable if owner_items else fallback_unreadable,
        "live_ci_satisfied": sorted(live_satisfied),
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


# What a completed entry has to say. The accounting layer read the status word
# and the index and never the words after `--`, so `- [complete] <item> -- done`
# and an image link closed a test item just as well as a result line did. It
# was strict about form and silent about proof, which is the inversion this
# closes.
DETAIL_WORD_RE = re.compile(r"\w+")
# What a runner prints on its own line. Everything else that fits in one word
# is a claim rather than a result.
ONE_WORD_RESULTS = frozenset({"pass", "passed", "passing", "ok", "green", "success"})
# Words that report a status rather than what was seen. An owner's item has no
# runner to print a result, so a detail made only of these says the owner
# looked without saying what they found.
STATUS_WORDS = ONE_WORD_RESULTS | frozenset(
    {"okay", "done", "complete", "completed", "yes", "verified", "checked", "confirmed", "lgtm", "fine", "good"}
)
# Every way a picture reaches a markdown body, matched without a repeated
# group around any of them -- the obvious spelling nests a quantifier inside a
# quantifier, and the detail is PR-controlled text, so a crafted one
# backtracked exponentially. Substituting each image out and asking what words
# are left is linear and says the same thing.
DETAIL_IMAGE_RE = re.compile(
    # Every part is bounded. Unbounded, a detail of `![` repeated starts a
    # scan to the end of the string at each position and the whole check goes
    # quadratic -- 7 seconds on 16,000 characters, and the hidden metadata is
    # not subject to the markdown line limit.
    r"!\[[^\]\n]{0,300}\]\([^)\n]{0,600}\)"
    r"|!\[[^\]\n]{0,300}\](?:\[[^\]\n]{0,300}\])?"
    r"|<img\b[^>\n]{0,600}>"
    r"|<?https?://[^\s)\]>]{0,600}\.(?:png|jpe?g|gif|webp|svg|webm|mp4)"
    r"(?:[?#][^\s)\]>]{0,300})?>?",
    re.IGNORECASE,
)


def _detail_proves_nothing(item: str, detail: str, *, owner: bool = False) -> bool:
    """Whether a `[complete]` entry's detail says nothing that could be checked.

    Four shapes fail: nothing, one word, an image standing alone on an item
    that is not about looking at something, and -- on an owner's item --
    nothing but status words. What the detail must not be is the whole rule --
    saying what it must contain would mean re-stating the command the item
    already names, and "all passed" against `swift test` is a perfectly good
    answer. `PASS` is what a runner prints, and on an owner's item there is no
    runner, so it is a status there and not a result.
    """
    text = detail.strip()
    words = DETAIL_WORD_RE.findall(text)
    if not words:
        return True
    if owner and all(
        word.casefold() in STATUS_WORDS
        for word in DETAIL_WORD_RE.findall(text.replace(CARRIED_FORWARD_NOTE, " "))
    ):
        return True
    # "One word" is not a count in every script. A single ASCII word is a
    # non-answer -- "done", "proof", "complete" -- unless it is what a runner
    # actually prints. A single run in a script that does not space its words
    # is a sentence.
    if len(words) == 1 and words[0].isascii():
        return words[0].casefold() not in ONE_WORD_RESULTS
    if _evidence_item_kind(item) == "screenshot":
        return False
    # An image is evidence of what a person can see. On an item about looking
    # at something it is the proof; anywhere else it is a picture of text.
    if not DETAIL_IMAGE_RE.search(text):
        return False
    return not DETAIL_WORD_RE.search(DETAIL_IMAGE_RE.sub(" ", text))


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


def validate_evidence_accounting(body: str, requested_evidence: list[str], *, review_ci: list[dict] | None = None) -> tuple[dict[str, object], list[str]]:
    if not requested_evidence:
        return evaluate_evidence_accounting(body, []), []
    accounting = evaluate_evidence_accounting(body, requested_evidence, review_ci=review_ci)
    errors: list[str] = []
    body_contract = set(requested_evidence) - set(accounting.get("live_ci_satisfied", []))
    if not accounting["section_present"] and body_contract:
        errors.append("missing required '## Evidence Status' section")
    if accounting["source"] == "markdown" and accounting.get("owner_section_unreadable"):
        errors.append(f"the Evidence Status section cannot be read: {accounting['owner_section_unreadable']}")
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
    unproven_items = accounting.get("unproven_items") or []
    if unproven_items:
        preview = _format_missing_preview(list(unproven_items), requested_evidence)
        errors.append(
            "these entries are marked complete but their detail proves nothing; "
            "say what you ran and what it printed, and note that an image of text "
            f"is not evidence: {preview}"
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


def _read_owner_section(
    published_body: str,
    requested_evidence: list[str],
) -> tuple[dict[int, dict[str, object]], str | None]:
    """Entries in the published section that no longer say what the machine wrote.

    Also returns why the section cannot be read as anyone's, or None when it
    reads cleanly. A section that fails to read is not a section that agrees
    with the metadata, and the caller has to be able to tell the two apart.

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
    body carrying no metadata has nothing to read.
    """
    if not _explicit_evidence_contract(requested_evidence) or not published_body.strip():
        return {}, None
    metadata = _structured_evidence_entries(published_body, requested_evidence)
    if not isinstance(metadata, dict) or metadata.get("source") != "structured":
        return {}, None
    machine = metadata.get("entries")
    if not isinstance(machine, dict) or not machine:
        return {}, None
    # Only what GitHub renders as a status line is read, parsed as CommonMark
    # rather than matched line by line. Drift is a person's edit only where the
    # section being read is the one the machine wrote, and a second heading --
    # a section the model wrote under a heading the renderer's strip missed --
    # can differ from the metadata with nobody editing anything.
    lines, unreadable = _rendered_status_lines(published_body)
    if unreadable:
        return {}, unreadable
    rendered_items = [_rendered_inline(item) for item in requested_evidence]
    # One entry per list item, straight from its tokens. Joining the texts back
    # into markdown and reading that again would let text the parser kept
    # inside one item start a line of its own.
    written: dict[str, dict[str, str]] = {}
    repeated: list[str] = []
    for text in lines:
        split = split_evidence_status_line(f"- {text}", rendered_items)
        if not split or (is_numeric_evidence_item(split[1]) and not _is_requested_item(split[1], rendered_items)):
            return {}, f"a list item in it is not an entry: {_truncate(text)}"
        status, item, detail = split
        if item in written:
            repeated.append(item)
            continue
        written[item] = {"status": status, "detail": detail}
    # A requested item goes through the same inline parse as the line, so
    # `**item**` and `item` share a key; the line's own text is not parsed a
    # second time, so `** item **` keeps the asterisks a reader sees.
    positions = {
        _normalize_evidence_key(item): position
        for position, item in enumerate(rendered_items, start=1)
    }
    # Two lines for one item are two answers, and taking whichever comes first
    # decides the item by where a bullet sits. Lines whose text differs only
    # in what the key normalizes away are two lines for one item too.
    answered: set[int] = set()
    for item in written:
        position = positions.get(_normalize_evidence_key(item))
        if position in answered:
            repeated.append(item)
        if position is not None:
            answered.add(position)
    if repeated:
        return {}, f"it has more than one line for: {_truncate(str(repeated[0]))}"
    # A status line the read cannot attribute to an item is still a `[blocked]`
    # or a `[complete]` a reader sees, and ignoring it lets the metadata decide
    # an item the owner may have answered.
    unmatched = [item for item in written if _normalize_evidence_key(item) not in positions]
    if unmatched:
        return {}, f"a line in it names no requested item: {_truncate(str(unmatched[0]))}"
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
        recorded_detail = str(recorded.get("detail", "")).strip()
        # The visible detail has been through the parser and the recorded one
        # has not, so they are compared read the same way: a machine line with
        # a `**` or a link in it is not a person's edit.
        same_words = re.sub(r"\s+", " ", _rendered_inline(recorded_detail)).strip() == re.sub(
            r"\s+", " ", str(entry.get("detail", ""))
        ).strip()
        if recorded.get("status") == entry.get("status") and same_words:
            continue
        preserved[position] = {
            "index": position,
            "item": requested,
            "status": entry["status"],
            # A status changed by hand keeps the words the machine recorded,
            # emphasis and links included; words rewritten by hand are the
            # person's, as parsed.
            "detail": recorded_detail if same_words else str(entry["detail"]).strip(),
        }
    return preserved, None


def _owner_written_entries(
    published_body: str,
    requested_evidence: list[str],
    *,
    mark_carried: bool = False,
) -> dict[int, dict[str, object]]:
    """What `_read_owner_section` found, or nothing when the section cannot be read."""
    written, _ = _read_owner_section(published_body, requested_evidence)
    if not mark_carried:
        return written
    for entry in written.values():
        detail = str(entry["detail"])
        if CARRIED_FORWARD_NOTE not in detail:
            # Written before this turn, and this turn may change the code
            # under it. Saying so is the difference between an attestation a
            # reader can weigh and a green that looks freshly earned. A read
            # of the body as it stands is not a new turn, so it does not mark.
            entry["detail"] = f"{detail} {CARRIED_FORWARD_NOTE}"
    return written


# The section's grammar, stated once and enforced by one writer: under the
# heading a bullet opening with a status token is the machine's, and every
# other block is a note. A note has a section of its own directly below,
# because the readers refuse any block under the heading that is not a list
# (#1701, #1709) -- so keeping a reviewer's note where it was written and
# keeping the section readable are the same choice, and only one of them can
# be had. Raw HTML and a block with no end are the two exceptions, and both
# for the same reason: what is carried is what the body states the end of.
EVIDENCE_STATUS_HEADING = "Evidence Status"
EVIDENCE_NOTES_HEADING = "Evidence Notes"


def _is_status_list_item(tokens: list[Token], index: int) -> bool:
    """Whether the list item opening at `index` belongs to the machine rather than the author.

    A bullet whose text opens with a status token -- `[complete]`, `[blocked]`
    or `[pending-ci]` -- is the machine's vocabulary, and the rewrite replaces
    it from the entries in hand. Well-formed or not: an item missing its
    `--` boundary, or wrapping a nested block, is a malformed status line
    rather than a note, and carrying it would put a status a reader can see
    outside the one section every reader of a status reads.

    Read as the page reads it, so a numbered item, a bulleted one and a
    `**[complete]**` are one shape. Everything else under the heading -- a
    `- [x]` box, a bullet naming no status -- is the author's and moves.
    """
    shape = [tokens[index + offset].type for offset in range(1, 3) if index + offset < len(tokens)]
    if shape != ["paragraph_open", "inline"]:
        # The item opens with something that is not its own line of text -- a
        # table, a quote, a nested list. Reading the first inline inside one of
        # those took a table's header row for the item's text and deleted the
        # table with it.
        return False
    text = inline_text(tokens[index + 2].children).strip()
    return EVIDENCE_STATUS_PREFIX_RE.match(f"- {text}") is not None


def _without_edge_blank_lines(text: str) -> str:
    """The text with its leading and trailing blank LINES gone and nothing else touched.

    `strip()` would take the indentation off the first line and the trailing
    spaces off the last, and both are content: the first is what makes a block
    code rather than prose, and the second is a line break on the page.
    """
    lines = MARKDOWN_LINE_ENDING_RE.split(text)
    start, stop = 0, len(lines)
    while start < stop and not lines[start].strip():
        start += 1
    while stop > start and not lines[stop - 1].strip():
        stop -= 1
    return "\n".join(lines[start:stop])


def _list_item_spans(
    tokens: list[Token], start: int, machine: list[tuple[int, int]], notes: list[tuple[int, int]]
) -> int:
    """Sort the items of the list opening at `start` into the machine's and the author's; return the index past it.

    An item is taken as the lines it was written on, nested blocks included,
    so a bullet carrying an indented excerpt moves whole.
    """
    close, level = tokens[start].type.replace("_open", "_close"), tokens[start].level
    index = start + 1
    while index < len(tokens) and not (tokens[index].type == close and tokens[index].level == level):
        token = tokens[index]
        if token.type != "list_item_open" or token.level != level + 1:
            index += 1
            continue
        if token.map is not None:
            if _is_status_list_item(tokens, index):
                # The line the status is written on is the machine's; the rest
                # of the item is one block of the author's, not a run of loose
                # lines. A pasted log indented under a status bullet belongs to
                # the bullet only because the parser folds it there, and left
                # to the per-line sweep its fence markers came off and its
                # lines came out as separate paragraphs -- text altered rather
                # than carried, which is worse than text deleted.
                first = tokens[index + 1].map or token.map
                machine.append((first[0], first[1]))
                if first[1] < token.map[1]:
                    notes.append((first[1], token.map[1]))
            else:
                notes.append((token.map[0], token.map[1]))
        depth, index = 0, index + 1
        while index < len(tokens):
            kind = tokens[index].type
            if kind == "list_item_open":
                depth += 1
            elif kind == "list_item_close":
                if depth == 0:
                    index += 1
                    break
                depth -= 1
            index += 1
    return index + 1


def _section_notes(section: str) -> list[str]:
    """The blocks of one Evidence Status section that are not status lines, as written.

    Parsed as CommonMark rather than matched line by line, for the reason
    every read of this section is: a line matched by pattern is not always a
    line a reader sees. Each block comes back as the source lines it spans, so
    a fenced excerpt keeps its fence and a table keeps its delimiter row.

    What moves is decided by subtraction, not by collection: the lines the
    write is about to put back, plus the two kinds it will not carry, are
    marked, and every other line of the section is a note. Collecting from the
    tokens instead would drop whatever the parser emits no token for, and a
    link reference definition is exactly that.

    A block the parser cannot end is not carried (`unmovable_block`): it is
    left where the rewrite finds it and deleted there, as at the merge base,
    and the run's output says so and names the line. Refusing the write
    instead would strand a body the runaway repair already rewrites (#1723
    round 3), and carrying the opener alone would fold every section below it
    into a block nobody opened there.

    Every span is carried byte for byte -- the source lines, with their
    indentation, their fence markers and their trailing spaces. A mover that
    reformats is not a mover: altered text looks like the author's words with
    the meaning changed, which is worse than a deletion anyone can see.
    """
    # Trimmed to the last line the author wrote something on, and parsed as
    # that. A section's slice runs to the boundary, so it carries the blank
    # lines before it -- and a fence with no closing line that ends on one of
    # those reads as a fence that closes, because the count of lines it spans
    # leaves room for a closer nobody wrote.
    lines = MARKDOWN_LINE_ENDING_RE.split(section)
    line_count = next(
        (index + 1 for index in range(len(lines) - 1, -1, -1) if lines[index].strip()), 0
    )
    lines = lines[:line_count]
    tokens = MARKDOWN.parse("\n".join(lines))
    machine: list[tuple[int, int]] = []
    spans: list[tuple[int, int]] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token.level != 0 or token.nesting < 0 or token.map is None:
            index += 1
            continue
        if token.type in {"bullet_list_open", "ordered_list_open"}:
            index = _list_item_spans(tokens, index, machine, spans)
            continue
        spans.append((token.map[0], token.map[1]))
        index += 1
    # A status line soft-wrapped over several source lines is one line on the
    # page and one sentence of the author's; the rewrite replaces it from the
    # entries in hand, so the continuation goes with it. Carrying half a
    # sentence into a section of its own would be alteration, not carriage --
    # but the loss is still a loss, and it is said.
    for start, stop in machine:
        if stop - start > 1:
            log(
                f"not carried to `## {EVIDENCE_NOTES_HEADING}`: {stop - start - 1} line(s) "
                f"continuing the status line at line {start + 1} of the "
                f"`{EVIDENCE_STATUS_HEADING}` section"
            )
    covered = {line for start, stop in machine for line in range(start, stop)}.union(
        line for start, stop in spans for line in range(start, stop)
    )
    spans.extend(
        (line, line + 1)
        for line in range(line_count)
        if line not in covered and lines[line].strip()
    )
    carried: list[str] = []
    for start, stop in sorted(spans):
        while start < stop and not lines[start].strip():
            start += 1
        while stop > start and not lines[stop - 1].strip():
            stop -= 1
        if start >= stop:
            continue
        # Sliced, never trimmed: `strip()` on a block takes the indentation off
        # its first line, which is the difference between a code block and
        # whatever its text would otherwise be read as, and the trailing spaces
        # off its last, which are a line break on the page.
        block = "\n".join(lines[start:stop])
        if (reason := unmovable_block(block)) is not None:
            # Said, because a loss nobody can see is the failure this file
            # keeps paying for. The line is the one inside this section, which
            # is the only frame this function has.
            log(
                f"not carried to `## {EVIDENCE_NOTES_HEADING}`: {reason} at line {start + 1} "
                f"of the `{EVIDENCE_STATUS_HEADING}` section"
            )
            continue
        carried.append(block)
    return carried


def _placement_a_reader_cannot_see(written: str) -> str | None:
    """Why the page would not show the `## Evidence Status` this write just placed, or None.

    The placement walks to the first `## Validation` the page shows as a
    heading and falls back to the end of the body when it shows none. Below a
    raw HTML block that never closes the page shows nothing as itself, so that
    fallback writes the section inside a block a reader reads as markup: the
    status is in the source, absent from the page, and the metadata comment
    still carries it to every gate -- an approval over evidence nobody can see.

    Until a section ended at an h1 the cut refused such a body outright, and
    that refusal is about the cut (`_write_refusal`): a section with no
    boundary after it, reached through a block that never closed. The cut is
    safe now, because the section ends above the block. This asks the same
    question of the insertion (#1734).

    Asked of the result rather than of the shapes that produce it: a write
    whose section the page does not show is wrong however it got there, and a
    postcondition cannot be argued out of by the next boundary rule.

    One question, asked once. `placement_refusal` is this question for every
    writer, and since a section's presence is decided by the same parse the
    rendered read makes (#1730) the two cannot answer differently; this
    returns the reason where the caller reports it, and the writer's own call
    logs it.
    """
    return placement_refusal(written, written, EVIDENCE_STATUS_HEADING)


def write_evidence_status_section(
    body: str, status_lines: Iterable[str]
) -> tuple[str, str | None]:
    """The one write of `## Evidence Status`, or the body unchanged and why it stands.

    Both writers of the section come through here -- the structured re-render
    a lane run makes and the factory turn's own render -- because a pair that
    has to agree about what a body carries is one function or it is a bug
    waiting (#1729). What they agree on: the status list is rewritten from the
    entries in hand, and every other block that was under the heading moves,
    in the order it was written, to a top-level `## Evidence Notes` directly
    below -- anchored to the status section rather than to whatever heading
    follows it, so the two stay together wherever the status itself sits. A
    body that carried no such block has no such section, a body that has one
    keeps it directly below the status, and a second write over the first
    moves nothing, since by then the notes are no longer under the heading.

    A section the body already has is rewritten where its author put it, so a
    write moves the status list's contents and nothing else.

    The text carried forward is read from the same call that cuts it, so the
    write cannot take out a span the read did not see. It stands the body down
    and writes nothing where the section's end is a guess: a block that never
    closed hides it, or only a repaired parse can see it. A `## <heading>`
    line the page shows as code was a third such shape, and was the cost of
    matching the heading by pattern -- the section starts at a heading token
    now, so there is no section under a fenced one to write to (#1730).

    The body is taken as the author wrote it. It used to be newline-terminated
    first, because the cut's pattern ended on one and a heading on the last
    line was a section to every reader and none to the cut; the parser reads
    that heading, so the terminator is no longer part of the question.
    """
    source = body
    sections, refusal = removed_section_texts(body, EVIDENCE_STATUS_HEADING)
    if refusal is not None:
        return source, refusal
    notes = [block for section in sections for block in _section_notes(section)]
    # The notes section comes out before the status section goes in, so that
    # neither is standing when the other is placed and both land by the same
    # rule. Placing the status around a notes section still in the body put
    # the two in one order on the first write and the other on the second.
    kept, notes_refusal = removed_section_texts(body, EVIDENCE_NOTES_HEADING)
    if notes_refusal is not None:
        return source, notes_refusal
    # Appended to what that section already held rather than replacing it.
    blocks = [kept_text for text in kept if (kept_text := _without_edge_blank_lines(text))] + notes

    def placed(candidate: str) -> tuple[str, str | None]:
        """The rewritten body, or the source standing whole and why."""
        unseen = _placement_a_reader_cannot_see(candidate)
        return (source, unseen) if unseen else (candidate, None)

    # The note about a heading this reader declined is NOT said here. It was,
    # and it had to be said before the write to see the author's heading alone
    # -- which meant it announced "a plain heading was written below it" on
    # bodies the write then refused and returned untouched, one line above the
    # refusal, in the same log. It also made the note the writer's, and the
    # writer runs more than once in a turn. It belongs to whatever reports the
    # turn, composed from the body the write returned (#1730, round 2).
    written = insert_markdown_section(
        strip_markdown_section(body, EVIDENCE_NOTES_HEADING) if kept else body,
        EVIDENCE_STATUS_HEADING,
        "\n".join(status_lines),
        before_heading="Validation",
    )
    if not blocks:
        # Nothing to hold, and no heading left behind: an empty one is a
        # section this writer would place next run and a reader would find
        # above the status now.
        return placed(written)
    with_notes = insert_markdown_section(
        written, EVIDENCE_NOTES_HEADING, "\n\n".join(blocks), after_heading=EVIDENCE_STATUS_HEADING
    )
    if len(with_notes) > PR_BODY_LIMIT >= len(written):
        # A body GitHub will not store is not a body, and dropping the notes is
        # what makes this one storable: without them the status the lane just
        # resolved still gets written. Where the status alone is already past
        # the limit, dropping them buys nothing and the text is kept -- the
        # edit fails either way, as it does at the merge base.
        log(
            f"`## {EVIDENCE_NOTES_HEADING}` not written: carrying "
            f"{len(blocks)} block(s) would take the body to {len(with_notes)} characters, "
            f"past the {PR_BODY_LIMIT} GitHub stores"
        )
        return placed(written)
    return placed(with_notes)


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
    evidence_map.update(
        _owner_written_entries(published_body, requested_evidence, mark_carried=True)
    )
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

    stripped_body = _strip_evidence_metadata(summary_body)
    # Untrimmed, because that is the text the writer cuts and the text the
    # reason answers about; trimming here and not there is what once let the
    # guard name a refusal while the write went ahead.
    rendered, write_refusal = write_evidence_status_section(stripped_body, evidence_lines)
    if write_refusal is not None:
        # The body stands rather than losing the sections below the fence, and
        # the author is told which line to close.
        errors.append(f"PR body Evidence Status section was not rewritten: {write_refusal}")
        return summary_body, errors
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

    The kind is the decided one (`_hand_completion_kind`), so an item that
    reads as a screenshot request only once rendered still counts as one. A
    strictness tie keeps the written reading, so this can gain a screenshot
    and never lose one.
    """
    return (
        _hand_completion_kind(item)[0] == "screenshot"
        or VISUAL_EVIDENCE_RE.search(item) is not None
        or OWNER_ATTESTED_RE.search(item) is not None
        or MANUAL_JUDGEMENT_RE.search(item) is not None
        or EXTERNAL_VERIFICATION_RE.search(item) is not None
    )


def _image_read_satisfies_item(item: str) -> bool:
    """Image inspection never substitutes for a requested human/external act."""
    return _evidence_item_kind(item) == "screenshot" and not any(
        pattern.search(item)
        for pattern in (OWNER_ATTESTED_RE, MANUAL_JUDGEMENT_RE, EXTERNAL_VERIFICATION_RE)
    )


def review_evidence_gate_error(verdict: str, accounting: dict[str, object], errors: list[str], *, images_inspected: bool = False) -> str | None:
    if verdict == "request_changes":
        return None
    if errors:
        return "; ".join(errors)
    blocked_items = [item for item in accounting["blocked_items"]
                     if not (images_inspected and _image_read_satisfies_item(str(item)))]
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
        and not (images_inspected and _image_read_satisfies_item(str(item)))
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


def _evidence_command_split(item: str) -> tuple[str, str]:
    """The command a `test` or `build` item names, and the text after it.

    Only a span that *opens* the item counts. An item mentioning a command
    mid-sentence is not a request to run it, and reading one out of the middle
    would run something nobody asked for. Without an opening span there is no
    boundary to cut on, so the item is read whole with an empty remainder,
    exactly as before -- and what is inside the span still faces the same
    allowlist.
    """
    text = item.strip()
    match = LEADING_CODE_SPAN_RE.match(text)
    if match is None:
        return _normalize_evidence_item(item), ""
    return match.group("command").strip(), text[match.end():]


def _evidence_command_text(item: str) -> str:
    return _evidence_command_split(item)[0]


def _remainder_is_only_a_verdict(remainder: str) -> bool:
    """Whether the text after the command only says what the command should do.

    An allowlist, not a blacklist. A list of demands to refuse is only as good
    as the demands someone thought of: "and `swift test --filter Bar` passes"
    is a second command, "approved by the owner" puts the verb before the
    noun, and neither reads as a demand to a pattern written for "(owner-
    attested)". A list of verdicts to accept fails the other way -- an item
    the grammar does not recognise stays `other`, blocked, in front of a
    person, exactly where it was before any of this.
    """
    return COMMAND_REMAINDER_RE.match(remainder) is not None


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
    if normalized.startswith(("swift test", "swift build")):
        if not _remainder_is_only_a_verdict(_evidence_command_split(item)[1]):
            return "other"
        return "test" if normalized.startswith("swift test") else "build"
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
        _evidence_command_text(item)
        for item in requested_evidence
        if _evidence_item_kind(item) == "test"
    ]


# How far past a runner mention the result line may sit. A command and its
# summary land within a couple of lines of each other in every shape people
# write -- a fenced block, a bullet, a sentence.
ATTESTED_TEST_WINDOW_LINES = 4
ATTESTED_TEST_QUOTE_LIMIT = 180
# A line that says the run did not happen. Without this, "`pnpm test` was not
# run" beside another runner's passing count reads as a pass.
NOT_RUN_RE = re.compile(
    r"(?i)\b(?:not|never|couldn't|could not|cannot|can't|unable to|failed to|"
    r"didn't|did not|skipped?|skipping|pending|todo|to do)\b"
    # A plan is not a report. "We will run `pnpm test` after review" names a
    # command and, a line down, a count of the tests the change adds.
    r"|\b(?:will|shall|going to|plan to|intend to|should)\s+(?:be\s+)?run\b"
    r"|\bonce\s+(?:ci|the\s+\w+)\s+(?:runs|finishes|completes)\b"
    r"|\bafter\s+(?:review|merge|approval)\b"
)
# The Performance section's own fields, as `.github/pull_request_template.md`
# writes them and `pr-perf-evidence.yml` enforces them.
PERF_FIELD_RE = re.compile(
    r"(?i)^\s*[-*]?\s*(?P<label>before|after|delta)\b[^:\n]{0,24}:\s*(?P<value>.+)$"
)
# One metric, both sides and the delta, as `perf-compare.py` prints it and
# `pr-evidence.sh` copies it into the body.
PERF_COMPARISON_RE = re.compile(
    r"^[-*]\s*(?P<metric>[^:\n]{1,80}):\s*(?P<before>[^\n]{1,80}?)\s*->\s*"
    r"(?P<after>[^\n;]{1,80}?)\s*;\s*(?P<delta>[^\n;]{1,80})"
)
# A measurement, not a number. "Before Summary: issue #123" carries a digit
# and measures nothing; a unit is what makes the two sides comparable.
PERF_MEASUREMENT_RE = re.compile(
    r"(?i)[-+]?\d+(?:[.,]\d+)?\s*"
    r"(?:ms|µs|us|ns|s\b|secs?\b|seconds?\b|min\b|minutes?\b|%|percent"
    r"|[kmg]b\b|bytes?\b|fps\b|hz\b|ops\b|req\b|x\b|cores?\b|threads?\b)"
)


def _item_evidence_tokens(item: str) -> tuple[list[str], list[str]]:
    """What a body statement must name to be about *this* item.

    Two lists, because they bind with different strength. A path is specific:
    an item naming `test_foo.py` is not answered by a run of `test_bar.py`,
    even though both are pytest. A runner is weak: it only says the statement
    is about the same tool. So where the item names paths, a path must match;
    otherwise the runner does.
    """
    text = item.strip()
    runners = [
        match.group(0).casefold() for match in TEST_RUNNER_MENTION_RE.finditer(text)
    ]
    paths: list[str] = []
    for span in re.finditer(r"`([^`\n]{1,300})`", text):
        candidate = span.group(1).strip().strip("*")
        if not candidate or TEST_RUNNER_MENTION_RE.search(candidate):
            continue
        # The whole span and its last segment both count, and a bare directory
        # counts too: `web-next` is what tells a `pnpm test` there apart from
        # a `pnpm test` in `web`, and dropping it made them the same claim.
        paths.append(candidate.casefold())
    # A span that looks like a path outranks one that does not. An item naming
    # both `scripts/tests/test_foo.py` and `macos-26` is about the first; the
    # second is a label, and offering it as an alternative let an unrelated
    # run complete the item by mentioning the runner it ran on.
    shaped = [
        path for path in paths if "/" in path or re.search(r"\.[a-z0-9]{1,5}$", path)
    ]
    if shaped:
        paths = shaped
    # A basename on its own is a weaker claim than the path that contains it:
    # `pytest test_foo.py` in some other directory is not a run of
    # `scripts/tests/test_foo.py`. So the tail is offered only where the item
    # named no directory at all.
    if not any("/" in path for path in paths):
        paths.extend(path.rsplit("/", 1)[-1].casefold() for path in list(paths))
    return [runner for runner in runners if runner], sorted({path for path in paths if path})


def _line_names(line: str, tokens: list[str]) -> bool:
    """Whether the line names one of these tokens, as a token.

    Substring matching made `web-next` answer an item about `web`, and
    `not_test_foo.py` answer one about `test_foo.py`. A token ends at a word
    or path character, and may be preceded by a path separator -- `./`, `/`
    and `cd ./web-next` all name the thing that follows them.
    """
    lowered = line.casefold()
    return any(
        re.search(rf"(?<![\w.-]){re.escape(token)}(?![\w.-])", lowered)
        for token in tokens
    )


def _attested_statement_in(lines: list[str], required: list[str]) -> str | None:
    """The statement these lines carry, whichever view of the body they came from."""
    for index, line in enumerate(lines):
        if not TEST_RUNNER_MENTION_RE.search(line):
            continue
        if required and not _line_names(line, required):
            continue
        # The result belongs to the run named on this line. A heading ends the
        # statement, and so does another runner: "`pnpm test` was not run"
        # followed by "`pytest` -> 214 tests passed" is two statements, and
        # reading them as one completes the wrong item.
        window = [line]
        for follower in lines[index + 1 : index + ATTESTED_TEST_WINDOW_LINES]:
            if follower.lstrip().startswith("#") or TEST_RUNNER_MENTION_RE.search(follower):
                break
            window.append(follower)
        joined = " ".join(window)
        # The guard reads the whole statement, not only its first line: a "was
        # not run" under the command and a count under that is one statement,
        # and reading the line alone called it a passing run.
        if NOT_RUN_RE.search(joined):
            continue
        if not TEST_RESULT_RE.search(joined) or _reports_a_failure(joined):
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


def _attested_test_statement(body: str, item: str = "") -> str | None:
    """A statement in the PR body naming a test run and what it printed.

    Both halves are required. A command with no result is a plan; a result
    with no command is a claim nobody else can re-run. Together they are
    Michael's fallback bar -- "just stating the tests that ran and covered the
    feature" -- and they are checkable, which is why this can complete an item
    the factory has no toolchain to run.

    Two views of the body are consulted and both have to accept: the lines as
    written, and the lines as GitHub renders them (`_rendered_lines`). The
    rendered view is the point -- a command and a count written only inside an
    HTML comment render as nothing and state nothing -- but it is not a
    superset of the written one. A block renders in fewer lines than it
    occupies, and the scan below measures its window in lines, so on the
    rendered view alone it reaches across a gap, a fence or a comment and binds
    a result the statement does not own. Requiring both makes this reader only
    ever stricter than the one that read the raw body, whatever the next such
    shape turns out to be, instead of asking anyone to enumerate them.

    The quotation comes from the rendered view, because it is quoted into a
    status line a person reads and that person is reading the page.
    """
    if not body.strip():
        return None
    runners, paths = _item_evidence_tokens(item) if item else ([], [])
    required = paths or runners
    rendered = _attested_statement_in(_rendered_lines(body), required)
    if rendered is None:
        return None
    if _attested_statement_in(MARKDOWN_LINE_ENDING_RE.split(body), required) is None:
        return None
    return rendered


# How a measurement is summarised, as opposed to what it measured.
PERF_SUMMARY_TOKENS = frozenset({"p50", "p95", "p99", "delta"})
# What each metric is measured in. A launch latency reported in megabytes is
# not a launch latency, and matching on a shared unit alone let "launch memory
# 10 MB" answer an item about launch latency.
PERF_METRIC_UNITS = {
    "latency": {"ms", "s", "sec", "secs", "second", "seconds", "us", "\u00b5s", "ns", "min", "minutes"},
    "duration": {"ms", "s", "sec", "secs", "second", "seconds", "us", "\u00b5s", "ns", "min", "minutes"},
    "startup": {"ms", "s", "sec", "secs", "second", "seconds"},
    "launch": {"ms", "s", "sec", "secs", "second", "seconds"},
    "cold start": {"ms", "s", "sec", "secs", "second", "seconds"},
    "render": {"ms", "s", "fps", "hz"},
    "frame": {"ms", "fps", "hz"},
    "load": {"ms", "s", "sec", "secs", "second", "seconds"},
    "memory": {"mb", "kb", "gb", "bytes", "byte"},
    "footprint": {"mb", "kb", "gb", "bytes", "byte"},
    "allocation": {"mb", "kb", "gb", "bytes", "byte"},
    "size": {"mb", "kb", "gb", "bytes", "byte"},
    "cpu": {"%", "percent", "cores", "core"},
    "throughput": {"ops", "req", "hz"},
    "fps": {"fps", "hz"},
}
PERF_METRIC_RE = re.compile(
    r"(?i)\b(?:p50|p95|p99|latency|duration|throughput|cpu|memory|footprint"
    r"|allocation|fps|startup|launch|cold start|frame|render|load|size)\b"
)


def _measurement_units(value: str, metrics: set[str] | None) -> set[str]:
    """The units measured beside the metric this item asked about.

    Scoped to the clause naming the metric where there is one, because a value
    listing several measurements otherwise matches on whichever unit happens
    to be shared.
    """
    text = value
    if metrics:
        clauses = [
            clause
            for clause in re.split(r"[;,]", value)
            if any(metric in clause.casefold() for metric in metrics)
        ]
        if clauses:
            text = " ".join(clauses)
    return {
        match.group(0).casefold().lstrip("-+0123456789., ")
        for match in PERF_MEASUREMENT_RE.finditer(text)
    }


def _perf_numbers_in(lines: list[str], wanted: set[str], scenarios: set[str]) -> str | None:
    """The comparison these lines carry, whichever view of the section they came from."""
    if not any(line.strip() for line in lines):
        return None
    lowered = "\n".join(lines).casefold()
    if scenarios and not any(token in lowered for token in scenarios):
        return None

    candidates: list[dict[str, str]] = []
    fields: dict[str, str] = {}
    for line in lines:
        # A comparison line carries both sides at once. `pr-evidence.sh`
        # promotes one metric into the Before/After fields and lists the rest
        # here, so an item about any other metric would never find its numbers
        # without reading these.
        comparison = PERF_COMPARISON_RE.match(line.strip())
        if comparison is not None:
            name = comparison.group("metric").strip()
            delta = comparison.group("delta").strip()
            # The two sides are printed bare and the unit sits on the delta,
            # so read it across rather than call a comparison unmeasured.
            unit_match = PERF_MEASUREMENT_RE.search(delta)
            unit = (
                unit_match.group(0).lstrip("-+0123456789., ") if unit_match else ""
            )
            candidates.append(
                {
                    "before": f"{name} {comparison.group('before').strip()} {unit}".strip(),
                    "after": f"{name} {comparison.group('after').strip()} {unit}".strip(),
                    "delta": delta,
                }
            )
            continue
        match = PERF_FIELD_RE.match(line)
        if match is None:
            continue
        value = match.group("value").strip()
        if not PERF_MEASUREMENT_RE.search(value):
            continue
        fields.setdefault(match.group("label").casefold(), value)
    if fields:
        candidates.insert(0, fields)
    for found in candidates:
        answer = _perf_comparison(found, wanted, scenarios, lowered)
        if answer is not None:
            return answer
    return None


def _perf_underlined_measurement(body: str) -> bool:
    """Whether a measurement in the Performance section ran into the rule below it.

    A run of dashes written directly under a line of text underlines that line
    into a heading, so the page shows a measurement styled as a heading and the
    read sees a heading rather than a `Before:` line. The numbers are there and
    correct, which is what makes the plain refusal misleading: it asks for
    measurements the author already wrote (#1723).

    The underlined heading is the section's own boundary, so it is the token at
    the end of the span rather than one inside it: the rule the author wrote to
    close the section off took the line above it along.

    Only the shape is reported, not a repair. Reading the heading back as the
    lines it was written as is the repair, it was tried, and it loosened two
    other readers -- see `_rendered_lines`.
    """
    tokens = MARKDOWN.parse(_lf(body))
    span = _rendered_section_span(tokens, "Performance")
    if span is None:
        return False
    return any(
        tokens[index].type == "heading_open"
        and not tokens[index].markup.startswith("#")
        and PERF_FIELD_RE.match(inline_text(tokens[index + 1].children).strip())
        for index in range(span[0], min(span[1] + 1, len(tokens) - 1))
    )


def _perf_numbers(body: str, item: str = "") -> str | None:
    """The before and after the PR body's Performance section carries.

    Both, or nothing: one side of a comparison measures nothing. Delta rides
    along when it is there, since it is the line a reader actually reads.

    The section also has to be about the item. A launch-latency contract is
    not answered by a section that measured setup, and one Performance
    section is not four different measurements -- so the metric or the
    scenario the item names has to appear in it.

    Two views of the section are consulted and both have to accept, for the
    reason `_attested_test_statement` gives: the rendered view is what a reader
    sees, and it is not a superset of the written one. `PERF_FIELD_RE` and
    `PERF_COMPARISON_RE` were shaped against written lines, so on the rendered
    view alone a bold label, a table cell, a `+` bullet or a quoted block from
    another PR becomes a measurement this body never made. The quotation comes
    from the rendered view, because it is quoted into a status line a person
    reads.
    """
    # What is measured has to match, not merely how it is summarised. `p50
    # setup` shares only "p50" with `p50 launch latency`, and reading that as
    # enough made them the same measurement. Requiring every token instead
    # would refuse `p50 launch 1.31s` for want of the word "latency", so the
    # rule is: something other than the percentile has to line up.
    wanted = {match.group(0).casefold() for match in PERF_METRIC_RE.finditer(item)}
    scenarios = {
        span.group(1).strip().casefold()
        for span in re.finditer(r"`([^`\n]{1,200})`", item)
        if span.group(1).strip()
    }
    rendered = _perf_numbers_in(_rendered_lines(body, "Performance"), wanted, scenarios)
    if rendered is None:
        return None
    written = MARKDOWN_LINE_ENDING_RE.split(markdown_section(body, "Performance"))
    if _perf_numbers_in(written, wanted, scenarios) is None:
        return None
    return rendered


def _perf_comparison(
    found: dict[str, str],
    wanted: set[str],
    scenarios: set[str],
    lowered: str,
) -> str | None:
    if "before" not in found or "after" not in found:
        return None
    # The metric has to be named in the values themselves, not anywhere in the
    # section: a heading mentioning "launch latency" over a Before that
    # measured setup is not an answer. And the two sides have to share a unit,
    # measured on the part of each value that names the metric -- otherwise
    # "Before: launch 1s, memory 4GB" and "After: deploy 20ms, memory 3GB"
    # agree on GB and measure nothing in common.
    shared: set[str] = set()
    if wanted:
        named = {
            label: {
                token
                for token in wanted
                # `_` and `-` separate words in a metric name, so
                # `p50_launch_ms` names launch. A `\w` boundary would not see
                # it, and that is the shape the producer writes.
                if re.search(rf"(?<![a-z0-9]){re.escape(token)}(?![a-z0-9])", found[label].casefold())
            }
            for label in ("before", "after")
        }
        shared = named["before"] & named["after"] - PERF_SUMMARY_TOKENS
        if not shared:
            return None
    units = {
        label: _measurement_units(found[label], shared or None)
        for label in ("before", "after")
    }
    common = units["before"] & units["after"]
    if not common:
        return None
    # And the unit has to be one the metric is measured in. A launch latency
    # reported in megabytes measured something else that happened to share a
    # unit with the other side.
    expected = set().union(*(PERF_METRIC_UNITS.get(token, set()) for token in shared)) if shared else set()
    if expected and not common & expected:
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
        normalized = _evidence_command_text(item)
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
                # Named as an attestation, not as a run the factory watched.
                # The reviewer reads this line and the diff together, and the
                # difference between "the lane ran it" and "the author says
                # they ran it" is exactly what they are weighing.
                evidence_complete.append(
                    f"{index} -- attested by the PR author, not run by the factory: {attested}"
                )
            else:
                evidence_pending_ci.append(
                    f"{index} -- the hosted lane has no toolchain for this runner; state the "
                    "command and the line it printed in this PR body, and the next factory "
                    "turn completes this entry (or edit the line yourself)"
                )
        elif kind == "perf":
            numbers = _perf_numbers(body, item)
            if numbers:
                evidence_complete.append(
                    f"{index} -- attested by the PR author in this body's Performance "
                    f"section, not measured by the factory: {numbers}"
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
    try:
        output = run_optional(
            ["swift", "test", "list"],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
            default="",
        )
    except FileNotFoundError:
        # The agent lanes run `ubuntu-latest`, which has no Swift toolchain, so
        # this preflight cannot apply there. Caught here rather than in
        # `run_optional`: that helper has 26 call sites, and one of them reads
        # `git status --porcelain` where an empty answer means "clean" -- a
        # swallowed error there would let a revision finish without committing
        # the edits it made.
        log(
            "skipping `swift test list` evidence selector preflight because no swift "
            "executable is available on this runner"
        )
        return []
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
        _evidence_command_text(item)
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


def _lane_command_key(item: str) -> str:
    """The command as `_evidence.yml` writes it above the run's output."""
    command = _evidence_command_text(item)
    argv = safe_swift_test_command_args(command) or safe_swift_build_command_args(command)
    return shlex.join(argv) if argv is not None else command


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
    # The lane logs `$ <command>` above each run's output and this looks that
    # key up, so it has to be the command the lane ran, spelled the way the
    # lane spelled it -- `shlex.join` of the parsed argv, not the author's
    # quoting.
    normalized = _lane_command_key(item)
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


# A real payload is a dict, an entries list, an entry dict, and scalars --
# four levels. Anything past this is not evidence state, and `json.dumps`
# with an indent recurses on the way out, so a body deep enough to parse and
# too deep to write would be built and then refused by the writer.
PAYLOAD_MAX_DEPTH = 8
PAYLOAD_TOO_DEEP = "<nested past what evidence metadata carries>"


def _encodable_payload(value: object) -> object:
    """The same payload with every string cleaned of what cannot be encoded.

    Iterative, not recursive: the payload comes from a PR-editable body, and
    a thousand nested arrays parse fine and then exhaust the stack on the way
    back out. `json.dumps` survives that depth; this used not to.
    """
    root: dict[str, object] = {"v": value}
    stack: list[tuple[object, object, object, int]] = [(root, "v", value, 0)]
    while stack:
        holder, key, current, depth = stack.pop()
        if depth > PAYLOAD_MAX_DEPTH:
            holder[key] = PAYLOAD_TOO_DEEP  # type: ignore[index]
            continue
        if isinstance(current, str):
            holder[key] = _encodable(current)  # type: ignore[index]
        elif isinstance(current, dict):
            cleaned: dict[object, object] = {}
            for inner_key, inner in current.items():
                clean_key = _encodable(inner_key) if isinstance(inner_key, str) else inner_key
                cleaned[clean_key] = inner
                stack.append((cleaned, clean_key, inner, depth + 1))
            holder[key] = cleaned  # type: ignore[index]
        elif isinstance(current, list):
            copied = list(current)
            holder[key] = copied  # type: ignore[index]
            for position, inner in enumerate(copied):
                stack.append((copied, position, inner, depth + 1))
    return root["v"]


def _encodable(text: str) -> str:
    """Text that survives being written back to GitHub.

    A JSON-escaped lone surrogate parses fine and then cannot be encoded as
    UTF-8, so the body this text lands in raises `UnicodeEncodeError` in every
    writer of it. Dropping it here keeps the rest of the line.
    """
    return text.encode("utf-8", "replace").decode("utf-8")


def _render_structured_entries(body: str, updated_entries: list[object]) -> str:
    """Re-render the Evidence Status section and hidden metadata from entries."""
    rendered_entries: list[dict[str, object]] = []
    for entry in updated_entries:
        if not isinstance(entry, dict):
            continue
        try:
            index = int(entry["index"])
        except (KeyError, TypeError, ValueError, OverflowError):
            continue
        item = _encodable(str(entry.get("item", "")).strip())
        status = str(entry.get("status", "")).strip()
        detail = _encodable(str(entry.get("detail", "")).strip())
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
        reconciled, refusal = write_evidence_status_section(
            _strip_evidence_metadata(body),
            [
                f"- [{entry['status']}] {entry['item']} -- {entry['detail']}"
                for entry in sorted(rendered_entries, key=lambda entry: int(entry["index"]))
            ],
        )
        if refusal is not None:
            # The body stands whole, metadata included: recording entries the
            # section does not show would leave the record saying one thing
            # and the page another, which is the divergence the two writers
            # agreeing is for.
            log(f"refusing to rewrite the `{EVIDENCE_STATUS_HEADING}` section: {refusal}")
            return body
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
        except (KeyError, TypeError, ValueError, OverflowError):
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


def checks_api_env(env: dict[str, str]) -> dict[str, str]:
    """Use the workflow's read-only checks capability without changing publisher identity."""
    scoped = dict(env)
    token = scoped.pop("FACTORY_CHECKS_TOKEN", "").strip()
    if token:
        scoped["GH_TOKEN"] = token
    return scoped


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
        env=checks_api_env(env),
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


def _review_ci_check_name(item: str) -> str | None:
    """A whole single-check obligation eligible for automatic review accounting.

    This is separate from verification recognition below. Qualifiers and extra
    obligations prevent completing the whole item, without hiding its CI checks.
    """
    name = _ci_check_name(item)
    match = re.fullmatch(
        rf"(?i)(?:(?:CI:?[ \t]+)|(?:The[ \t]+))?`(?P<check>[^`\n]+)`"
        rf"(?:[ \t]+(?:{CI_EVIDENCE_NOUN}))?"
        r"(?:[ \t]+\(required branch protection\))?[ \t]+"
        rf"(?:(?:(?:is|must be|stays?)[ \t]+)?(?:green|{CI_EVIDENCE_PASS})"
        r"(?:[ \t]+on[ \t]+(?:(?:the|this|exact)[ \t]+)?(?:PR(?:[ \t]+head)?|head[ \t]+commit))?"
        r"|must finish on the exact PR head and stay green)\.?",
        item.strip(),
    )
    return name if match and match.group("check").strip() == name else None


def _verification_ci_check_names(item: str) -> list[str]:
    """Every explicitly named check that must remain live-verified.

    Preserve the established name recognition, including qualified requirements.
    Coordinated CI lists bind each backticked name, so the last green name cannot
    hide another check. Test commands in a separate trailing clause are not names.
    """
    if not CI_EVIDENCE_KEYWORD_RE.search(item):
        return []
    names = {match.group("check").strip() for pattern in CI_EVIDENCE_NAME_RES
             for match in pattern.finditer(item) if match.group("check").strip()}
    for match in re.finditer(
        r"(?i)\bCI:?[ \t]+(?P<names>`[^`\n]+`(?:[ \t]*(?:,[ \t]*(?:and[ \t]+)?|and\b|&)[ \t]*`[^`\n]+`)+)", item
    ):
        names.update(name.strip() for name in re.findall(r"`([^`\n]+)`", match.group("names")) if name.strip())
    return sorted(names)


def resolve_named_ci_evidence(requested_evidence: list[str], head_sha: str, env: dict[str, str]) -> list[dict]:
    """Resolve exact-head named CI independently of author attestations.

    Keep original contract indexes and fetch duplicate names once. A newer queued
    or running check supersedes an older success; never select completed runs first.
    """
    resolved: dict[str, dict] = {}
    facts = []
    for index, item in enumerate(requested_evidence, 1):
        check_names = _verification_ci_check_names(item)
        automatic_name = _review_ci_check_name(item)
        for check_name in check_names:
            if check_name not in resolved:
                fact = {"check_name": check_name, "head_sha": head_sha, "status": "unavailable",
                        "run_id": None, "url": None, "conclusion": None, "reason": "lookup_unavailable"}
                runs = check_runs_for(check_name, head_sha, env) if re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", head_sha) else None
                if runs == []:
                    fact.update(status="missing", reason="no_matching_run")
                elif runs:
                    valid = all(type(run.get("id")) is int and run["id"] > 0
                                and run.get("head_sha") == head_sha and run.get("name") == check_name
                                for run in runs)
                    if not valid:
                        fact["reason"] = "invalid_or_stale_run"
                    else:
                        run = max(runs, key=lambda value: value["id"])
                        status, conclusion = run.get("status"), run.get("conclusion")
                        fact.update(run_id=run["id"], url=run.get("html_url"), conclusion=conclusion)
                        if status == "completed" and conclusion is None:
                            fact["reason"] = "conclusion_unavailable"
                        elif status == "completed":
                            fact.update(status="satisfied" if conclusion == "success" else "failed", reason="latest_completed")
                        elif status in {"queued", "in_progress", "requested", "waiting", "pending"}:
                            fact.update(status="pending", reason="latest_not_completed")
                        else:
                            fact["reason"] = "unknown_run_status"
                resolved[check_name] = fact
            facts.append({"index": index, "item": item,
                          "automatic_completion": len(check_names) == 1 and automatic_name == check_name,
                          **resolved[check_name]})
    return facts


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


def _gate_verdict(
    accounting: dict[str, object],
    requested_evidence: list[str],
    *,
    skip: set[str],
) -> tuple[object, ...]:
    """What the gate reports off a body, for the items not named in `skip`.

    Two readings of one body compare equal here when a reader would say the
    same things about it: the same verdict for each item, and the same
    complaints -- a section it cannot read, a line it cannot parse, two
    entries for one requirement, an item outbid for its entry. An entry
    answering nothing is left out: the gate reports it nowhere, and the line
    it came from stays visible in the body either way.
    """
    def listed(key: str) -> list[str]:
        return [str(item) for item in list(accounting[key])]  # type: ignore[arg-type]

    bucket: dict[str, str] = {}
    for name in ("complete_items", "blocked_items", "pending_ci_items", "missing_items"):
        for item in listed(name):
            bucket[item] = name
    return (
        tuple(bucket.get(item, "unread") for item in requested_evidence if item not in skip),
        accounting["section_present"],
        accounting["owner_section_unreadable"] is None,
        len(listed("invalid_lines")),
        tuple(sorted(listed("duplicate_items"))),
        tuple(sorted(listed("indistinguishable_entries"))),
        tuple(sorted(listed("contested_items"))),
        tuple(sorted(item for item in listed("unproven_items") if item not in skip)),
    )


def _lane_written_entries(
    accounting: dict[str, object],
    requested_evidence: list[str],
    lane_resolved: dict[str, tuple[str, str]],
) -> list[dict[str, object]]:
    """The entries a metadata comment on this body would carry.

    Every requested item the body answers is recorded, not only the lane's
    own: the metadata is read INSTEAD of the section once it exists, so an
    item left out is one the gate reports missing, and an owner's attested
    line would be the first to go. The shape is the one
    `render_execution_summary_body` writes, `kind` included and read from the
    item the issue asks for, so an owner's `other` item keeps being read from
    its visible line here too.

    What each item is recorded as is `accounting` -- the gate's own reading of
    this body, kind rule and all -- except for the entries this run resolved,
    which are the lane's own and are recorded as the lane found them.
    """
    entries = accounting["entries"]
    matched = accounting["matched"]
    if not isinstance(entries, dict) or not isinstance(matched, dict):
        return []
    written: list[dict[str, object]] = []
    recorded: set[str] = set()
    for index, item in enumerate(requested_evidence, start=1):
        if item in recorded:
            # Two indexes for one text are one entry to the reader, and a
            # second would be read as a duplicate rather than as an answer.
            continue
        if item in lane_resolved:
            status, detail = lane_resolved[item]
        else:
            key = matched.get(item)
            entry = entries.get(key) if isinstance(key, str) else None
            if not isinstance(entry, dict):
                continue
            status = str(entry.get("status", "")).strip()
            detail = str(entry.get("detail", "")).strip()
        if status not in {"complete", "blocked", "pending-ci"} or not detail:
            continue
        recorded.add(item)
        written.append(
            {
                "index": index,
                "item": item,
                "status": status,
                "detail": detail,
                "kind": _evidence_item_kind(item),
            }
        )
    return written


def _write_lane_evidence_metadata(
    reconciled: str,
    requested_evidence: list[str],
    lane_resolved: dict[str, tuple[str, str]],
) -> str:
    """`reconciled` with a metadata comment recording this run, or `reconciled` unchanged.

    A hand-written body carries no metadata, so every `[complete]` line in it
    is read as hand-written, and a lane item stays pending even where the lane
    ran the command and rewrote the line itself (#1693, #1708). Recording the
    run's own entries is what makes them the lane's; the accounting then reads
    them the way it reads a factory body's.

    Written only where it changes nothing else. The gate's verdict for every
    item the lane did not touch, and every complaint the gate makes about the
    section, are compared read off the section against read through the
    metadata, and where they differ the body keeps today's reading. A section
    with a bullet that is not an entry is the case that reaches this: the
    metadata would hand its owner items to a rule that refuses an unreadable
    section, and the lane's work staying invisible there is the state this
    found rather than one it made.
    """
    read_off_the_section = evaluate_evidence_accounting(reconciled, requested_evidence)
    entries = _lane_written_entries(read_off_the_section, requested_evidence, lane_resolved)
    if not entries:
        return reconciled
    written = _insert_evidence_metadata(reconciled, {"entries": entries})
    if reconciled.endswith("\n"):
        written += "\n"
    if len(written) > PR_BODY_LIMIT:
        # The whole body is written back in one edit, and GitHub refuses one
        # this long. Refusing here costs the provenance; letting it through
        # costs the line rewrites as well, since nothing of the edit lands.
        return reconciled
    skip = set(lane_resolved)
    before = _gate_verdict(read_off_the_section, requested_evidence, skip=skip)
    after = _gate_verdict(
        evaluate_evidence_accounting(written, requested_evidence), requested_evidence, skip=skip
    )
    return written if before == after else reconciled


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

    A body with no metadata comment gains one recording what this run
    resolved, so the completions it just wrote are read as the lane's rather
    than as hand-written (`_write_lane_evidence_metadata`). An entry has an
    index only against the contract, so with no contract in hand the body
    keeps today's reading.

    A body that carries metadata is re-rendered from its entries on every
    run, whether or not this one resolved anything. The re-render is also the
    repair: it restores a line edited by hand, scrubs a line for an item the
    metadata has no entry for, and puts back a section deleted outright. Two
    attempts at skipping it when there was nothing to add each let through a
    hand edit a reader could see, so nothing turns on whether a run resolved
    anything.
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
    # What this run resolved, against the contract's own spelling of the item:
    # a metadata entry's index and item are positions in the contract, and a
    # line's wording is not.
    requested_by_key: dict[str, str] = {}
    for contract_item in requested_evidence or []:
        requested_by_key.setdefault(_normalize_evidence_key(contract_item), contract_item)
    lane_resolved: dict[str, tuple[str, str]] = {}

    for line in lines:
        if line.startswith("## "):
            in_evidence_status = re.fullmatch(r"(?i)## Evidence Status", line.strip()) is not None
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
                requested = requested_by_key.get(_normalize_evidence_key(item))
                if requested is not None:
                    lane_resolved.setdefault(requested, (status, detail))
                continue
        updated.append(line)

    reconciled = "\n".join(updated)
    if body.endswith("\n"):
        reconciled += "\n"
    # Only a body with no comment at all. One that carries a malformed or
    # future-versioned comment carries metadata a reader reports on, and
    # replacing it would answer that report by deleting it.
    if not lane_resolved or _latest_evidence_metadata_match(body) is not None:
        return reconciled
    return _write_lane_evidence_metadata(reconciled, list(requested_evidence or []), lane_resolved)


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
