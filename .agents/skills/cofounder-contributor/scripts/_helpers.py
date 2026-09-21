"""Shared helpers for contributor runtime modules."""

from __future__ import annotations

import bisect
import json
import os
import re
import subprocess
import sys
import unicodedata
import urllib.error
import urllib.request
from collections.abc import Callable
from html.parser import HTMLParser
from itertools import groupby
from pathlib import Path
from typing import NamedTuple

from markdown_it import MarkdownIt
from markdown_it.token import Token


REPO_ROOT = Path(__file__).resolve().parents[4]
SKILL_ROOT = Path(__file__).resolve().parents[1]
GH_DISCUSS_SCRIPT = REPO_ROOT / ".agents" / "skills" / "gh-discuss" / "scripts" / "gh-discuss.py"
VALIDATOR_SCRIPT = SKILL_ROOT / "scripts" / "validate-agent-output.py"

GITHUB_API_TIMEOUT = 30
CLAUDE_TIMEOUT = 300
VALIDATION_TIMEOUT = 30

# One parser for every read of a body, so two readers cannot disagree about
# what a body contains. Tables and strikethrough are GitHub's, and both carry
# meaning a reader sees: a struck-out item is not the item, and a table row is
# a line.
MARKDOWN = MarkdownIt("commonmark").enable(["table", "strikethrough"])
# Every line ending GitHub stores. A body arrives with whatever endings the
# client sent, and a rule anchored on one of them reads a different body than
# the page does.
MARKDOWN_LINE_ENDING_RE = re.compile(r"\r\n|\r|\n")

AGENT_LANE_LABEL = "agent"
AGENT_LANE_LABEL_COLOR = "5319e7"
AGENT_LANE_LABEL_DESCRIPTION = "Work owned by the agent execution lane"
AGENT_TASK_LABEL = "task"
AGENT_TASK_LABEL_COLOR = "0E8A16"
AGENT_TASK_LABEL_DESCRIPTION = "Planned work item"
AGENT_READY_LABEL = "ready"
AGENT_READY_LABEL_COLOR = "5319e7"
AGENT_READY_LABEL_DESCRIPTION = "Execution-approved and ready for an automated contributor to claim"
AGENT_CLAIM_LABEL = "claimed"
AGENT_CLAIM_LABEL_COLOR = "1d76db"
AGENT_CLAIM_LABEL_DESCRIPTION = "Currently being executed by an automated contributor"
AGENT_MERGEABLE_LABEL = "mergeable"
AGENT_MERGEABLE_LABEL_COLOR = "0e8a16"
AGENT_MERGEABLE_LABEL_DESCRIPTION = "Agent-approved, ready for owner merge"


def log(message: str) -> None:
    print(f"[run-contributor] {message}", file=sys.stderr)


def run_checked(
    cmd: list[str],
    *,
    timeout: int,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input: str | None = None,
    on_failure_output: Callable[[str], None] | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            cmd,
            input=input,
            capture_output=True,
            text=True,
            env=env,
            cwd=cwd,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        command = " ".join(cmd)
        print(f"error: command timed out after {exc.timeout}s: {command}", file=sys.stderr)
        if on_failure_output is not None:
            # TimeoutExpired can carry bytes even in text mode.
            partial = exc.stdout
            if isinstance(partial, bytes):
                partial = partial.decode("utf-8", errors="replace")
            on_failure_output(partial or "")
        sys.exit(1)
    if result.returncode != 0:
        command = " ".join(cmd)
        print(f"error: command failed (exit {result.returncode}): {command}", file=sys.stderr)
        if result.stderr.strip():
            print("--- stderr ---", file=sys.stderr)
            print(result.stderr.strip()[:8000], file=sys.stderr)
        if result.stdout.strip():
            # Print-mode CLIs (claude --print) report errors on stdout.
            print("--- stdout ---", file=sys.stderr)
            print(result.stdout.strip()[:8000], file=sys.stderr)
        if on_failure_output is not None:
            on_failure_output(result.stdout or "")
        sys.exit(result.returncode or 1)
    return result


def run_optional(
    cmd: list[str],
    *,
    timeout: int,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    default: str,
) -> str:
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            env=env,
            cwd=cwd,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return default
    if result.returncode != 0:
        return default
    return result.stdout


def persona_slug(persona: str) -> str:
    base = persona.split(",", 1)[0].strip().casefold()
    slug = re.sub(r"[^a-z0-9]+", "-", base).strip("-")
    return slug or "agent"


def short_persona_name(persona: str) -> str:
    return persona.split(",", 1)[0].strip() or persona.strip()


def slugify(value: str, *, max_length: int = 48) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")
    if not slug:
        return "task"
    return slug[:max_length].rstrip("-") or "task"


def branch_name_for_issue(persona: str, issue_number: int, issue_title: str) -> str:
    return f"codex/{persona_slug(persona)}-issue-{issue_number}-{slugify(issue_title)}"


def issue_label_names(issue: dict[str, object]) -> set[str]:
    labels = issue.get("labels", {})
    nodes = labels.get("nodes", []) if isinstance(labels, dict) else []
    return {
        str(label.get("name", "")).strip()
        for label in nodes
        if isinstance(label, dict) and str(label.get("name", "")).strip()
    }


def issue_label_presence(issue: dict[str, object]) -> set[str]:
    return issue_label_names(issue)


# A `<br>` is the one inline tag that renders as something: a line break. It
# arrives as `html_inline` like every other tag, and the tag name is what
# identifies it, so attributes and a self-closing slash are all one shape.
HTML_BREAK_TAG_RE = re.compile(r"(?i)^<br\b[^>]*>$")
def code_span(text: str) -> str:
    """`text` as a code span nothing inside it can break out of, on one line.

    Somebody else's characters reach three surfaces from a note: the workflow
    log, the structured record, and a comment on the pull request. Two of those
    interpret what they are handed. A newline inside a tag's attribute -- which
    a setext heading allows, and the parser keeps in one `html_inline` token --
    puts the text after it at column 0, where `::error::owned` is a workflow
    command the Actions log obeys. A backtick inside an attribute closes the
    span early, and what follows it is live markdown: an `@name` after one is a
    mention GitHub delivers to a person who has nothing to do with this
    (#1730, round 2).

    Four steps, and the ORDER is the escaping.

    1. Every character Unicode files under Cc or Cf goes -- but one that
       SEPARATES becomes a space rather than nothing. Cc is C0, DEL *and* C1 --
       U+0080 to U+009F, where the CSI introducer is a single character that
       opens an escape sequence on a terminal reading the log, and which a
       `[\x00-\x1f\x7f]` class does not name. Cf is the invisible formatting:
       a zero-width space, and a right-to-left override that reorders what a
       reader sees for the rest of the line.

       Deleting them all glues words: `a` tab `b` quoted back as `ab` is text
       the author never wrote, and a note that misquotes on the accepting side
       -- nothing refuses it -- is the failure `inline_text` records for `<br>`,
       where dropping the tag turned `1<br>2 tests passed` into a count nobody
       wrote (#1730, round 3b). So the test is `str.isspace()`: a tab, a line
       feed, a carriage return, a form feed, a vertical tab, the C0 separators
       and U+0085 leave a space behind for step 3 to collapse. NUL and the rest
       of C1 are not whitespace and leave nothing, because there is no
       separator there to keep.
    2. The comment delimiters, to a fixpoint, because one deletion can splice
       a fresh one together.
    3. Runs of whitespace, collapsed.
    4. The fence, one backtick past the longest run inside.

    Step 1 comes before step 2 because a delimiter can be MADE by removing an
    invisible character: `a<!` ZWSP `--b--` ZWSP `>c` carries no delimiter for
    the strip to find, and taking the zero-width spaces out afterwards hands
    the comment a `<!--` the strip had already run (#1730, round 3). Nothing
    that removes characters may run after the strip, and nothing at all may run
    after the fence -- a strip applied to a fenced string joins the backtick
    runs on either side of what it removes and can close the fence (#1730,
    round 2).

    Step 3 is a bare `.split()` on purpose: U+2028, U+2029 and U+0085 are line
    breaks downstream, and narrowing it to `.split(" ")` -- which reads like the
    same thing -- puts all three back.
    """
    visible = "".join(
        character
        if unicodedata.category(character) not in {"Cc", "Cf"}
        else (" " if character.isspace() else "")
        for character in text
    )
    while True:
        stripped = visible.replace("<!--", "").replace("-->", "")
        if stripped == visible:
            break
        visible = stripped
    return fenced_code_span(" ".join(visible.split()) or " ")


def fenced_code_span(text: str) -> str:
    """`text` in backticks, with a fence one longer than the longest run inside it.

    CommonMark's own rule, and the only one that holds for arbitrary content. A
    value that starts or ends on a backtick is padded with a space, which is
    what keeps that backtick inside the span rather than closing it. Shared so
    that `inline_text`, re-emitting a code span it read, and `code_span`,
    quoting text from outside, cannot disagree about it.
    """
    longest = max((len(list(run)) for char, run in groupby(text) if char == "`"), default=0)
    ticks = "`" * (longest + 1)
    pad = " " if text.startswith("`") or text.endswith("`") else ""
    return f"{ticks}{pad}{text}{pad}{ticks}"


def inline_text(children: list[Token] | None, *, break_text: str = " ") -> str:
    """Inline tokens as the text a reader sees, keeping the markup that carries meaning.

    Emphasis is transparent, so `**item**` is the item. A code span keeps its
    backticks, since requested items name commands in them, and a comment
    delimiter inside one is text. A link or image keeps its target, since a
    proof's link is the proof. Strikethrough keeps its tildes, since a
    struck-out item is not the item. A status line never reaches here with
    inline HTML or a break in it (`_unreadable_inline`); a requested item or a
    recorded detail can, and there inline HTML shows nothing and a break is a
    space.

    `break_text` is what a line break becomes. A status line is one line, so a
    break there is a space; a body read line by line (`_rendered_lines`) asks
    for a newline, because a PR body renders a break as a line break. A `<br>`
    is one of those breaks and not an invisible tag: dropping it glued the
    words on either side into one, and `1<br>2 tests passed` then quoted a
    count nobody wrote.
    """
    parts: list[str] = []
    targets: list[str] = []
    for token in children or []:
        kind = token.type
        if kind == "text":
            parts.append(token.content)
        elif kind == "code_inline":
            parts.append(fenced_code_span(token.content))
        elif kind in {"softbreak", "hardbreak"} or (
            kind == "html_inline" and HTML_BREAK_TAG_RE.match(token.content.strip())
        ):
            parts.append(break_text)
        elif kind == "link_open":
            targets.append(str(token.attrGet("href") or ""))
            parts.append("[")
        elif kind == "link_close":
            parts.append(f"]({targets.pop() if targets else ''})")
        elif kind == "image":
            parts.append(f"![{token.content}]({token.attrGet('src') or ''})")
        elif kind in {"s_open", "s_close"}:
            parts.append("~~")
        elif kind not in {"em_open", "em_close", "strong_open", "strong_close", "html_inline"}:
            parts.append(token.content)
    return "".join(parts)


def _parsed(body: str) -> list[Token]:
    """The body as the parser sees it, whatever line endings the client sent.

    Every read that asks the parser a question about a body comes through
    here, so a CR-only body is not a body with no headings to one reader and a
    body with all of them to another.
    """
    return MARKDOWN.parse(MARKDOWN_LINE_ENDING_RE.sub("\n", body))


def code_span_ranges(text: str) -> list[tuple[int, int]]:
    """Half-open ranges covering each code span, by CommonMark's own rules.

    Two callers ask this, so it lives here: a `--` inside a span is an
    argument rather than a boundary (`resolve_persona.py -- mara` is one
    name), and a `<details` inside one is text rather than a disclosure. A
    regex that pairs backticks without CommonMark's rules answers both
    questions wrongly in opposite directions -- it blanked a real `<details`
    between two backticks that open no span at all, so a note nobody was
    shown was recorded as shown and the write stayed silent about a note it
    had dropped (#1773, round 5).

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


def heading_identity(text: str) -> str:
    """One heading's text reduced to what decides whether two headings are one.

    Runs of whitespace collapse, and case folds with `lower()` rather than
    `casefold()`. Full case folding maps characters that are not case variants
    of anything: U+017F, the long s a printer sets in `Statuſ`, folds to `s`,
    so `## Evidence Statuſ` above the real `## Evidence Status` was the SAME
    heading to every reader here and two visibly different headings on the
    page. The first one won the identity and the rewrite's cut, which takes
    every section under that name, removed both -- returning a body holding
    neither section's contents (#1742). `ß` -> `ss` and `ﬁ` -> `fi` are the
    same shape.

    What `lower()` accepts is every single-character case pair Unicode
    records, `Ω`/`ω` and `É`/`é` with `S`/`s`, so a heading shouted in any
    alphabet is still its heading. What it declines is a fold that changes the
    letters rather than their case, which is the set a reader reads as a
    different word.

    NFKC was the other candidate and it goes the wrong way: it maps a
    fullwidth `Ｓ` onto `s` as well, so `## Evidence StatuＳ` would alias too,
    and the page shows that as a different word.
    """
    return " ".join(text.split()).lower()


def is_section_heading(token: Token) -> bool:
    """Whether a parsed token opens a heading at the level a section is addressed by.

    A top-level h2, however the author made it one. This answers "is this the
    section I was asked for", which is a narrower question than "does this end
    the section above it": `markdown_section` finds its heading with a literal
    `^## ` anchor, so a read that accepted an h1 here would match
    `# Evidence Status` as the section while the written read found nothing
    under that name -- the written/rendered split these two predicates exist
    to prevent (#1734).
    """
    return token.level == 0 and token.type == "heading_open" and token.tag == "h2"


def section_heading_index(tokens: list[Token], heading: str) -> int | None:
    """Where `## <heading>` opens in a parsed body, as a token index, or None.

    The one answer to "which heading is this section", asked by the reader,
    the writer and the rendered read alike. It is a parse rather than a
    pattern because a `## Mergeability` line inside a fenced example is code:
    the page shows an example there, and a presence check that matched it told
    the seeder a section was already written and left the body without one
    (#1730). The same line fooled the section cut, which then read an
    example's text as the section and refused every write to it.

    Matched on the text a reader sees, normalised for case and runs of
    whitespace, so a heading carrying trailing spaces or emphasis is the
    heading it looks like. The first such heading wins, which is the rule the
    rendered read already applied: a body with two is a body whose second one
    no reader is reading.

    A heading carrying inline HTML is not this section, whatever its text
    reads as. `inline_text` drops every tag but `<br>`, which is the right
    reading for a requested item or a recorded detail and the wrong one for
    identity: `## Evidence <del>Status</del>` is struck through on the page,
    `## <details>Evidence Status</details>` is a collapsed widget, and
    `## Evidence<br>Status` is two lines -- and each of the three became this
    section, whose contents the rewrite then replaced, with no reader left to
    disagree and raise it (#1730). Both reads agreeing against the page is the
    shape #1734 exists to prevent.

    Any tag, not a list of the ones that show something. `_unreadable_inline`
    in `evidence.py` already answers this question that way for a status line,
    and `_rendered_status_lines` refuses this very heading for carrying inline
    HTML; a second answer here is the disagreement, one function away. The
    alternative needs a set of tags GitHub's sanitizer renders as nothing,
    which is a second renderer built from an allow-list this repo does not
    hold -- and its only plausible members are `<span>` and a trailing
    comment. Checked against GitHub's own renderer: `<details>`, `<del>` and
    `<br>` render as a widget, as struck text and as two lines, so refusing
    those agrees with the page; `<span>` and a trailing comment render as
    ordinary headings, so refusing those two disagrees with it. Neither was
    this section before #1730's change, so the rule declines to widen rather
    than taking something away -- which is the whole of the argument, and it
    is about what is lost, not about what a later reader catches.

    What happens to `## <span>Evidence Status</span>` is that a second, real
    heading is written below it, and the three readers answer differently. The
    owner read refuses, naming this heading (`_rendered_status_lines`). The
    factory turn repairs the body first and its errors come back empty, so the
    turn goes on -- and `rejected_heading_note` is what reaches the run's
    output and the pull request there, because a body with two headings and
    nothing said about why is a message that points at the wrong repair
    (#1730). The readiness gate's own ambiguity check does NOT see it: that
    check matches raw text and is blind to a heading line carrying a tag.
    """
    wanted = heading_identity(heading)
    return next(
        (
            index
            for index, token in enumerate(tokens)
            if is_section_heading(token)
            and not any(child.type == "html_inline" for child in tokens[index + 1].children or [])
            and heading_identity(inline_text(tokens[index + 1].children)) == wanted
        ),
        None,
    )


def rejected_section_headings(tokens: list[Token], heading: str) -> list[tuple[int, str]]:
    """Every heading a reader sees as this section that carries inline HTML, with its first tag.

    The other half of `section_heading_index`: what it skipped, and why. A
    heading is here when its text reads as this heading once the tags are
    dropped -- the same normalisation the acceptance uses -- and it carries at
    least one `html_inline` token. The token index is the `heading_open`, so a
    caller has the line through `token.map`.
    """
    wanted = heading_identity(heading)
    found: list[tuple[int, str]] = []
    for index, token in enumerate(tokens):
        if not is_section_heading(token):
            continue
        children = tokens[index + 1].children or []
        tag = next((child.content for child in children if child.type == "html_inline"), None)
        if tag is None:
            continue
        if heading_identity(inline_text(children)) == wanted:
            found.append((index, tag))
    return found


def rejected_heading_note(body: str, heading: str) -> str | None:
    """What to tell an author whose `## <heading>` was not read as the section, or None.

    The rejection is correct and silent, and silence is what makes it cost a
    round: the body comes back with two headings a reader sees, the owner read
    says "a reader sees 2 ... headings, not one", and the obvious action --
    delete one -- is a coin flip. Deleting the written one leaves a body with
    no readable section and the same refusal (#1730).

    So the message names the line, names the tag, and names both repairs.

    It is asked of the body the write RETURNED, not the one it was handed, and
    it says what it finds there rather than what the write meant to do. Asked
    before the write it claimed "a plain `## <heading>` was written below it"
    on bodies where the write then refused and returned them untouched -- a
    sentence contradicted by the line above it in the same log (#1730, round
    2). Both readings are here, decided by what the body holds.

    Every value quoted from the body goes through `code_span`, because this
    text is posted to a pull request and printed to a workflow log, and both
    of those read what they are given -- see that function for what the two
    surfaces do with a newline and a backtick.
    """
    tokens = _parsed(body)
    rejected = rejected_section_headings(tokens, heading)
    if not rejected:
        return None
    lines = MARKDOWN_LINE_ENDING_RE.sub("\n", body).split("\n")
    index, tag = rejected[0]
    line = lines[tokens[index].map[0]].strip() if tokens[index].map else f"## {heading}"
    readable = section_heading_index(tokens, heading)
    if readable is None:
        where = f"No readable `{heading}` h2 is in this body, so nothing here is read as that section."
    else:
        # Two things this sentence used to say that the body cannot support.
        # It said "a plain `## {heading}`", where the reader that accepts it
        # accepts a setext h2 and an emphasised one too, so the note named a
        # syntax the body need not carry. And it said "was WRITTEN below it",
        # which is a claim about who put it there -- a body is evidence for
        # what is in it and for nothing else. It says where it is and that it
        # is the one being read (codex, gpt-5.6-sol, xhigh).
        below = (tokens[readable].map or (0, 0))[0] > (tokens[index].map or (0, 0))[0]
        where = (
            f"A readable `{heading}` h2 {'below' if below else 'above'} it is the one "
            "read as that section."
        )
    return (
        f"{code_span(line)} carries inline HTML ({code_span(tag)}), so it is not read as the "
        f"`{heading}` section -- a tag can strike, hide or fold what follows it, and "
        f"which one it does is not something this reader decides. {where} "
        "Remove the tags from yours, or remove yours."
    )


def is_section_boundary(token: Token) -> bool:
    """Whether a parsed token starts something other than the section above it.

    A section ends at a top-level heading of level 1 or 2 or a top-level `---`
    rule -- one nested in a list or a quote is inside the section rather than
    after it. The heading counts however the author made it one, hashes or an
    underline: an underline is what turns the line above it into a heading, and
    the page then shows a heading there whatever the author meant.

    An h1 ends a section because the page ends one there: a `# Release
    blockers` under `## Evidence Status` is the author's own top-level section,
    not a block inside this one. Read as inside it, the rewrite of Evidence
    Status carried that heading into `## Evidence Notes` and dropped the status
    bullet under it, since a status line inside the section is the machine's
    and is replaced by the entries in hand (#1734). The readiness gate ends a
    section at a heading of either level on both its views (#1674), and this is
    the predicate that keeps this reader's answer the same as the gate's.

    This is the rule the rendered read always applied; what changed is that the
    written read asks it too, on the same tokens, so neither can place a
    boundary the other does not (#1723). Both directions of that matter. A
    literal three-dash match does not stop at `-----` or at a setext underline,
    which the page stops at; and it does stop at a `##` heading or a `---` rule
    inside a code fence, which the page shows as code -- so a fenced rule could
    truncate a section for the reader while a person saw it whole.

    Its answers for `***`, `___` and an h3 are the answers the readers already
    gave: none of those ends a section.

    A fence that never closes is the exception, and it is the line rather than
    the token that carries it -- see `reparsed_without_runaway`.
    """
    if token.level != 0:
        return False
    if token.type == "hr":
        return token.markup.startswith("-")
    return token.type == "heading_open" and token.tag in {"h1", "h2"}




def _fence_never_closed(token: Token) -> bool:
    """Whether the parser found no closing line for this fence.

    From the token rather than by re-deriving the closing rule: a closed
    fence's span covers its content plus an opening and a closing line, an
    unclosed one's covers content plus the opening line alone. Matching the
    markup against a later line instead gets a fence closed by a run too short
    to close it wrong.
    """
    return token.map is not None and len(token.content.splitlines()) > token.map[1] - token.map[0] - 2


def runaway_fence(tokens: list[Token], lines: list[str]) -> Token | None:
    """The top-level fence, if any, that never closes and so runs to the end of the body."""
    return next(
        (
            token
            for token in tokens
            if token.type == "fence" and token.level == 0 and _fence_never_closed(token)
        ),
        None,
    )


def reparsed_without_runaway(tokens: list[Token], lines: list[str]) -> list[Token] | None:
    """The body parsed again with an unclosed fence's opening line blanked, or None.

    CommonMark runs a fence with no closing line to the end of the document, so
    a section holding one holds every heading written below it and the readers
    take a later section's lines for this one's: a Performance section with a
    runaway fence completed an item on measurements written under a later
    `## Validation` (#1723, round 3). Nobody reads a body that way, and a
    rewrite of such a section deletes every section below it.

    What the author meant below the fence is a question only a parse answers,
    so the opener is blanked and the parser asked again. Blanking keeps the
    line count, so every heading below reports its own line, and it finds the
    ones a pattern cannot -- a heading indented three spaces, or one made by an
    underline. `None` when no fence runs away, which is the ordinary case.

    A fence that DOES close and holds a `##` or a `---` is code the page shows
    as code, and the section runs past it: that is the one acceptance this
    change adds, and it is the closed case only.
    """
    if runaway_fence(tokens, lines) is None:
        return None
    # Blanking one opener can uncover another -- a fence opened with four
    # backticks and "closed" with three leaves the three-backtick line opening
    # a fence of its own -- so it repeats until no fence runs away. Each pass
    # blanks one line, so the loop is bounded by the body.
    blanked, parsed, current = set(), tokens, list(lines)
    while (runaway := runaway_fence(parsed, current)) is not None:
        opened = runaway.map[0]
        if opened in blanked or opened >= len(current):
            break
        blanked.add(opened)
        current[opened] = ""
        parsed = MARKDOWN.parse("\n".join(current))
    return parsed if blanked else None


def unmovable_block(text: str) -> str | None:
    """Why this block cannot be carried somewhere else in the body, or None.

    What a rewrite may move is a block the parser can end. A fence with no
    closing line cannot be ended: moved, it shows whatever lands after it as
    code, and where it stops is decided by the text it is put next to rather
    than by the author. A raw HTML block of kinds 1 to 5 whose closer never
    came is the same shape -- CommonMark runs it to the end of the document.

    A block that closes is carried, raw HTML included. The parser's map is the
    end: kinds 6 and 7 end at a blank line, kinds 1 to 5 at the closer they
    wrote. Deleting a `<details>` note a reader can see, on the grounds that
    some element INSIDE it might still be open, is #1725 in a narrower form --
    and an element left open that way hides no more after the move than
    before, because the block lands directly below the status list rather than
    above it, so the status becomes visible where it was hidden.

    Asked at every level, because a container carries its contents: an
    unclosed comment inside a blockquote is the same hazard as one at the top
    of the body.
    """
    for token in MARKDOWN.parse(MARKDOWN_LINE_ENDING_RE.sub("\n", text)):
        if token.type == "fence" and _fence_never_closed(token):
            # Through `code_span`, because the marker comes from the body and
            # is made of the character that delimits a code span: written as
            # `` f"`{markup}`" `` a ``` fence reached the page as five
            # backticks in a row, which renders as text rather than as the
            # marker the author has to find (#1740, round 3). `code_span`
            # fences one backtick past the longest run inside.
            return f"a {code_span(token.markup)} code fence with no closing line"
        if token.type == "html_block" and (missing := _missing_html_closer(token)) is not None:
            # Backticks and not `code_span` here, and it is not an oversight:
            # the closer is this runtime's own word for what is missing, drawn
            # from a fixed table and never from the body, and `code_span`
            # strips comment delimiters -- so `-->`, the one closer an author
            # most needs named, came back as an empty span (#1740, round 3).
            return f"a raw HTML block with no `{missing}`"
    return None


def section_write_refusal(body: str, heading: str) -> str | None:
    """Why a rewrite of this section would be guessing, or None when it would not.

    A writer replaces the text between a heading and the section's end, so it
    has to know where the end is. A section with no boundary after it may be
    the last one in the body, where the end of the body is the right answer.
    Or the heading the writer matched may not be a heading at all: a `##` line
    inside a fenced example is code, and replacing the "section" under it
    takes the fence's closing line with it -- which is how two ordinary writes
    to a body carrying a fenced `## Evidence Status` example came to delete
    three sections, the first eating the closer and the second taking the rest
    of the body for the section it was replacing (#1723, round 3).

    So a write whose heading the parser reads as code, and whose end falls
    outside the block that heading sits in, refuses: the body stands and the
    caller is told which line to close. Guessing costs the sections below it,
    and a writer that writes too much has already destroyed the evidence of
    having done so, where a reader that reads too much reports too much and is
    visible.
    """
    bounds = _section_bounds(body, heading)
    return bounds[3] if bounds else None


def _section_bounds(
    body: str,
    heading: str,
    *,
    boundary: "Callable[[Token], bool]" = is_section_boundary,
) -> tuple[int, int, int, str | None] | None:
    """Where `## <heading>` begins, where its text begins, and where the section ends.

    One answer for the reader and the writer. `markdown_section` returns the
    middle slice and `strip_markdown_section` cuts the outer one, so the text
    a caller reads is exactly the text a rewrite replaces -- a line counted as
    a completion cannot be left outside every section by the rewrite that
    follows it (#1723, round 2).

    Both ends are asked of the parser, because neither is a rule a pattern
    states. A three-dash line directly under a line of text is that line's
    setext underline, and a section read as ending there is empty on the page
    and whole here; a `## <heading>` line inside a fenced example is code, and
    a section read as starting there is an example's text, which is how a
    write to one came to refuse and a seeder to seed nothing (#1730). An
    unclosed fence is where the parser's answer is the worse one, and
    `reparsed_without_runaway` is that exception -- whichever boundary comes
    first ends the section. That repair answers about the END alone: a heading
    a runaway fence swallows is a heading no reader sees, so no section starts
    there for either view.
    """
    lines = MARKDOWN_LINE_ENDING_RE.split(body)
    tokens = _parsed(body)
    index = section_heading_index(tokens, heading)
    if index is None:
        return None
    # A setext heading is two lines, its underline included, so the text
    # starts where the heading block stops rather than one line below it.
    heading_line, heading_stop = tokens[index].map
    line_starts = [0] + [end.end() for end in MARKDOWN_LINE_ENDING_RE.finditer(body)]

    def offset(line: int) -> int:
        return line_starts[line] if line < len(line_starts) else len(body)

    def first_boundary_after(parsed: list[Token]) -> int | None:
        return next(
            (
                token.map[0]
                for token in parsed
                if token.map and token.map[0] >= heading_stop and boundary(token)
            ),
            None,
        )

    located = first_boundary_after(tokens)
    from_repair = False
    repaired = reparsed_without_runaway(tokens, lines)
    if repaired is not None:
        # A runaway fence hides every heading below it. Whichever boundary
        # comes first is the section's end, and the repaired parse is the only
        # one that can see the hidden ones.
        hidden_boundary = first_boundary_after(repaired)
        if hidden_boundary is not None and (located is None or hidden_boundary < located):
            located, from_repair = hidden_boundary, True
    end = offset(len(line_starts) if located is None else located)
    # The number of lines the author wrote, which is what a block's span reaches
    # when it runs to the end of the body.
    written_lines = len(lines) - 1 if lines and lines[-1] == "" else len(lines)
    return (
        offset(heading_line),
        offset(heading_stop),
        end,
        _write_refusal(tokens, located, written_lines, from_repair=from_repair),
    )


# What each raw-HTML block kind CommonMark ends on. Kinds 1 to 5 end on a
# condition of their own; kinds 6 and 7 end on a blank line, which is why they
# carry no entry and never count as unterminated. The kind is read off the
# opening text because the token does not record it -- the parser has already
# decided this run of lines is one HTML block, and this only asks which of the
# seven it opened as.
# Kind 1's start is a tag NAME, not a prefix: `<pre`, `<script`, `<style` or
# `<textarea` followed by whitespace, `>`, `/` or the end of the line. A
# `<prefix>` is a kind-7 block, which ends on a blank line and needs no closer;
# reading its opener as `<pre` refused a write nobody had broken.
HTML_KIND_1_RE = re.compile(r"^<(pre|script|style|textarea)(?=[\s>/]|$)", re.IGNORECASE)
# Kinds 2 to 5, each with the end condition the spec gives it. `--!>` is not
# the kind-2 end -- the spec's end is `-->` -- so a comment closed that way
# still counts as open, which is the fail-closed answer and the right one.
HTML_BLOCK_CLOSERS = (
    ("<![cdata[", "]]>"),
    ("<!--", "-->"),
    ("<?", "?>"),
)
HTML_DECLARATION_RE = re.compile(r"^<![a-z]", re.IGNORECASE)


def _missing_html_closer(token: Token) -> str | None:
    """The closer an HTML block of kinds 1 to 5 opened and never wrote, or None.

    Kinds 6 and 7 -- a known tag name, or any other complete tag on its own
    line -- end on a blank line or at the end of the body, both legitimately,
    so they have no closer to miss and never appear here.
    """
    content = token.content.lstrip()
    lowered = content.lower()
    if (kind_one := HTML_KIND_1_RE.match(content)) is not None:
        closer = f"</{kind_one.group(1).lower()}>"
        return None if closer in lowered else closer
    for prefix, closer in HTML_BLOCK_CLOSERS:
        if lowered.startswith(prefix):
            return None if closer in lowered else closer
    if HTML_DECLARATION_RE.match(content):
        return None if ">" in content[2:] else ">"
    return None


def unterminated_block(tokens: list[Token], line_count: int) -> tuple[Token, str] | None:
    """The top-level block that opened, never closed, and so runs to the last line.

    A fence with no closing line and a raw-HTML block of kinds 1 to 5 with no
    closer are the same shape: CommonMark runs both to the end of the document,
    so every heading the author wrote below one is inside it. A `<details>`
    (kind 6) and a bare tag (kind 7) end on a blank line and end at the end of
    the body legitimately, so neither is one of these; nor is the factory's own
    metadata comment, which is a kind-2 block that closes.
    """
    for token in tokens:
        if token.level != 0 or token.map is None or token.map[1] < line_count:
            continue
        if token.type == "fence" and _fence_never_closed(token):
            return token, f"a `{token.markup}` code fence with no closing line"
        if token.type == "html_block" and (missing := _missing_html_closer(token)) is not None:
            return token, f"a raw HTML block with no `{missing}`"
    return None


def _write_refusal(
    tokens: list[Token],
    located: int | None,
    line_count: int,
    *,
    from_repair: bool = False,
) -> str | None:
    """Why replacing this section would corrupt the body, or None.

    Two shapes, and both come down to a cut whose far end the author did not
    write. The first: the section has no boundary after it and got there
    through a block that never closed. What decides is the block's kind, not
    where the section sits. A fence with no closing line shows the rest of the
    body as code, so a reader sees that text and the section really does run
    to the end: cutting to the end is correct, and refusing would cost a write
    to a body that works, paid by an author who did nothing wrong. A raw HTML
    block of kinds 1 to 5 hides its contents, so a cut there is over text
    nobody can see, and that is the one to refuse.

    The second: the end is a boundary only the REPAIRED parse can see. The
    repair blanks a fence that never closes and asks the parser again, which
    is a good answer for a reader -- it reads the heading the author wrote
    rather than the code an unclosed fence makes of it -- and a bad one for a
    writer. The line it stops at is inside the fence, so a cut to it takes the
    ` ```markdown ` opener along and the lines that were code come back as
    live markdown: a fenced `# Release blockers` becomes a heading and a
    fenced `- [blocked]` becomes a status line nobody wrote (#1734, round 2).
    A writer that cannot see the end in the body as parsed refuses; the reader
    keeps the repair.

    The shape that used to come first -- a heading the parser reads as code,
    whose fence's closing line the cut would eat -- cannot arise now. A
    section starts at a heading token, and a `##` line inside a fence is not
    one, so there is no section there to cut (#1730). That refusal was the
    cost of finding the start by pattern, and it went with the pattern.

    A last section whose final block closes, or is a `<details>` or any other
    kind-6 or kind-7 block, or is indented code, is not this shape either.
    """
    if from_repair:
        return (
            "the end of this section is a heading only a repaired parse can see: the line at "
            f"line {(located or 0) + 1} sits inside a fence that never closes, so a rewrite "
            "would delete the fence's opening line and show the code below it as markdown"
        )
    if located is not None:
        return None
    open_block = unterminated_block(tokens, line_count)
    if open_block is None or open_block[0].type == "fence":
        return None
    token, description = open_block
    return (
        f"{description} opened at line {token.map[0] + 1} and runs to the end of the body, so "
        "where this section ends is not something the body says; a rewrite would take every "
        "heading below that line with it"
    )


def markdown_section(body: str, heading: str) -> str:
    """The body text under `## <heading>`, as written, up to where the section ends.

    The parser reports which line the section stops at and the original is
    sliced there, so a caller reads the author's characters rather than a
    re-render.
    """
    bounds = _section_bounds(body, heading)
    if bounds is None:
        return ""
    return body[bounds[1] : bounds[2]].strip()


def has_markdown_section(body: str, heading: str) -> bool:
    """Whether the page shows a `## <heading>` heading in this body.

    The same question `_section_bounds` asks, and the same answer, because it
    is the same call: a presence check that matched a pattern said yes to a
    `## Mergeability` line inside a fenced example, so the seeder returned a
    body it had written nothing to and the readiness gate then asked for the
    section the runtime believed it had seeded (#1730). One reader, so a
    caller cannot be told a section is there and then handed an example's
    text when it asks for one.

    The readiness gate asks the same question of the same parser since #1742,
    so this is no longer wider than the section that gate can read: a writer
    whose output the gate must be able to read asks this and nothing else.
    """
    return section_heading_index(_parsed(body), heading) is not None


def _section_removed(body: str, heading: str) -> tuple[str, str | None, list[str]]:
    """The body without this section, the text each cut took, or the reason it stands.

    Every occurrence goes, not only the first: `markdown_section` reads the
    first, so leaving a later one behind puts the stale copy where the next
    read will find it. The loop re-parses because each cut shortens the body,
    and it terminates because each cut takes at least the heading line.

    The cut, the text it takes and the reason for refusing it come from one
    call on one text, so a caller cannot be told the write was refused while
    the write happened, or the reverse, and a caller that carries some of the
    old text forward cannot read a different span than the one that goes.
    That pair disagreed once, over nothing more than whether the body had been
    trimmed first.
    """
    stripped: str = body
    taken: list[str] = []
    while (bounds := _section_bounds(stripped, heading)) is not None:
        if bounds[3] is not None:
            return body, bounds[3], []
        taken.append(stripped[bounds[1] : bounds[2]])
        stripped = stripped[: bounds[0]] + stripped[bounds[2] :]
    return re.sub(r"\n{3,}", "\n\n", stripped.strip()), None, taken


def removed_section_texts(body: str, heading: str) -> tuple[list[str], str | None]:
    """What a rewrite of this section would take out, in the order written, or why it stands.

    A caller that keeps part of the old section reads it from the same call
    that cuts it, so the text it carries forward is exactly the text the
    write removes.
    """
    _, refusal, taken = _section_removed(body, heading)
    return taken, refusal


def strip_markdown_section(body: str, heading: str) -> str:
    """The body without the section under `## <heading>`, heading included.

    A refused cut is reported here rather than passed back, because every
    caller wants the body either way; the run's output is where a refusal has
    to be visible.
    """
    stripped, refusal, _ = _section_removed(body, heading)
    if refusal is not None:
        log(f"refusing to rewrite the `{heading}` section: {refusal}")
    return stripped


def boundary_ignoring_h1(token: Token) -> bool:
    """`is_section_boundary` without the h1, which is the boundary before #1734.

    Asked for one purpose: to measure what an h1 took out of a section, by
    reading the same section under the rule that does not stop at one.
    """
    return is_section_boundary(token) and not (
        token.type == "heading_open" and token.tag == "h1"
    )


def _blocked_by_numbers(section: str) -> list[int]:
    numbers = [int(number) for number in re.findall(r"#(\d+)", section)]
    return list(dict.fromkeys(numbers))


def contract_read_refusal(
    body: str, heading: str, read_items: "Callable[[str], list]"
) -> str | None:
    """Why this section cannot be read as a contract, or None.

    A section ends at a top-level heading of level 1 or 2 (#1734), which for
    every other section is exactly what the page shows. A contract is the one
    section where reading LESS is a loosening: the items under `## Requested
    Evidence` are what a pull request must prove, and the issues under
    `## Blocked By` are what must land first, so a heading an author writes in
    the middle of one silently drops the obligations below it. Nothing on the
    page says an item stopped counting, and the run that stops demanding it
    says nothing either.

    So the question asked is the harm itself, not a shape that might cause it:
    the section is read twice, once under the boundary in force and once under
    the boundary that does not stop at an h1, and a contract whose items are
    the same either way is not cut, whatever headings it contains. An h1 with
    prose under it costs nothing and is not refused; an h1 with one item below
    it is. Asking it this way also reaches the cut a shape rule cannot see --
    an h1 inside a fence that never closes is not an h1 token in the body as
    parsed, and the section still ends there, because the reader repairs the
    fence before looking (`reparsed_without_runaway`).

    An h2 ends a contract silently, as it always has: a heading at the
    section's own level reads as the next section to everyone, author
    included.
    """
    short = _section_bounds(body, heading)
    if short is None:
        return None
    long = _section_bounds(body, heading, boundary=boundary_ignoring_h1)
    if long is None or long[2] <= short[2]:
        return None
    if read_items(body[short[1] : short[2]].strip()) == read_items(body[long[1] : long[2]].strip()):
        return None
    lines = MARKDOWN_LINE_ENDING_RE.split(body)
    cut_line = len(MARKDOWN_LINE_ENDING_RE.findall(body[: short[2]]))
    written = lines[cut_line].strip() if cut_line < len(lines) else ""
    return (
        f"the `## {heading}` section is cut by the top-level heading at line {cut_line + 1} "
        f"(`{written}`); move the heading below the section or the items under it"
    )


def blocked_by_contract(body: str) -> tuple[list[int], str | None]:
    """The issue numbers a `## Blocked By` section names, or why it cannot be read.

    The reader of record for both paths that ask: the contributor runtime
    through `github_state` and the lifecycle sync through its own entry point.
    They held character-identical copies and drifted the moment one of them
    read a boundary the other did not, so there is one copy (#1723, round 2).

    The numbers and the reason come back together because a caller that took
    the numbers alone would read a shortened blocker list as an empty one and
    start work the issue says is blocked (`contract_read_refusal`).
    """
    refusal = contract_read_refusal(body, "Blocked By", _blocked_by_numbers)
    if refusal is not None:
        return [], refusal
    numbers = _blocked_by_numbers(markdown_section(body, "Blocked By"))
    return numbers, None


def section_heading_offset(body: str, heading: str) -> int | None:
    """Where the page's `## <heading>` heading starts in the body, or None if it shows none.

    A writer that places a section "before" a heading has to place it before a
    heading a reader sees. A `##` line inside a fenced example is code, and a
    section written in front of one lands inside the fence -- taking the whole
    status list and the metadata beside it out of the rendered body, which is
    how a second ordinary write came to leave a pull request showing no
    Evidence Status at all (#1723). So the heading is the one the parser
    found, which is the same heading `markdown_section` reads and the same one
    `has_markdown_section` answers about: a body whose only match is code has
    no heading here, and the caller appends rather than guessing.
    """
    tokens = _parsed(body)
    index = section_heading_index(tokens, heading)
    if index is None:
        return None
    line_starts = [0] + [end.end() for end in MARKDOWN_LINE_ENDING_RE.finditer(body)]
    line = tokens[index].map[0]
    return line_starts[line] if line < len(line_starts) else len(body)


# GitHub's own answer to the one question a placement asks: would a reader
# have to open something to see this section? Element nesting across a body is
# what decides it, and a nesting model is the thing this seam exists not to
# build -- `unterminated_block` knows the fence and raw-HTML kinds 1 to 5, and
# a `<details>` is kind 6, which ends at a blank line to the parser while the
# element stays open on the page (#1742, item 3). `POST /markdown` in `gfm`
# mode returns the HTML the pull request page shows, and a fold read off that
# HTML needs no tag grammar and no nesting rules.
#
# The readiness gate holds a character-alike copy of this seam. Two copies,
# because the gate and this skill are standalone scripts with their own PEP
# 723 pins and their own import graphs -- the same trade the parser definition
# makes -- and the cost is paid by a test that pins the two request shapes
# together (`test_pr_readiness.py`, `ParserDefinitionTests` for the parser and
# the renderer agreement test for this).
MARKDOWN_API_URL = "https://api.github.com/markdown"
MARKDOWN_API_VERSION = "2022-11-28"
# One call per body that could be folded, against a body GitHub caps at 65,536
# characters. Ten seconds is far past the ~0.2 s the call takes and short
# enough that a turn waiting on an unreachable renderer still finishes.
RENDER_TIMEOUT_SECONDS = 10
DEFAULT_REPOSITORY = "fairchild/workspaces"
RENDERER_USER_AGENT = "workspaces-contributor"


class RendererUnavailable(Exception):
    """GitHub did not render the body. The message is why, in one clause.

    `transient` is the discriminator a caller needs to decide what a missing
    answer MEANS, and the message alone was not one -- every cause read the
    same way, so a laptop run with no token exported took the fail-open branch
    on every placement rather than on a rare one. A missing token is a
    permanent condition of the environment and one the author can act on, so
    it refuses; an HTTP failure or an unreachable renderer is a blip whose
    harm is a reading defect, and refusing there would turn a passing outage
    into a blocked PR, so those proceed unverified with the announcement
    (#1773, round 6).

    Keyword-only and required: the next cause added here decides which family
    it belongs to at the raise site, where the cause is known, rather than
    inheriting a default nobody chose.
    """

    def __init__(self, reason: str, *, transient: bool) -> None:
        super().__init__(reason)
        self.transient = transient


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
    references against, so a lane passes the token it already has and a laptop
    passes whatever `gh` exported. An unauthenticated call is not attempted,
    because the anonymous allowance is 60 an hour shared across the whole
    host, and a check spending it would refuse one author's body and place the
    next one with nothing changed between them.
    """
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        raise RendererUnavailable(
            "no GH_TOKEN or GITHUB_TOKEN in the environment", transient=False
        )
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
            "User-Agent": RENDERER_USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=RENDER_TIMEOUT_SECONDS) as response:
            return response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        raise RendererUnavailable(http_failure_reason(error), transient=True) from error
    except (urllib.error.URLError, OSError) as error:
        raise RendererUnavailable(
            f"the renderer was unreachable ({error})", transient=True
        ) from error


class RenderedPage(NamedTuple):
    """What the renderer said about a body, or why it said nothing.

    `unverified` is the whole fallback contract in one field: when it is set
    no page was seen and the check stands on the source model's answer, and it
    says so on the run's output, because a write placed without the page's
    answer was placed by a weaker check than the one a lane runs.

    A tuple rather than a dataclass because this module is loaded by path in
    several suites, and a dataclass resolves its annotations through
    `sys.modules` under `from __future__ import annotations` -- which a loader
    that never registered the module does not have.
    """

    html: str = ""
    unverified: str | None = None
    # Whether the cause was a blip. A permanent one -- no token exported --
    # is not something to proceed past: see `RendererUnavailable`.
    transient: bool = True


_RENDERED_PAGES: dict[str, RenderedPage] = {}


def rendered_page(text: str) -> RenderedPage:
    """The page's answer for this body, asked of GitHub once per text.

    Cached on the text: a turn writes the status section and then the notes
    section beside it, and both writes ask this question of a body that may
    already have been rendered.
    """
    if text in _RENDERED_PAGES:
        return _RENDERED_PAGES[text]
    try:
        html = render_markdown(text)
    except RendererUnavailable as unavailable:
        # Not cached. A failure is not an answer about this body: a 503, a
        # spent minute of a rate limit or a dropped connection says nothing
        # about the text, and storing it disabled the check for that body for
        # the rest of the process -- so a turn that writes twice would take
        # the fallback on the second write after the renderer had come back
        # (#1773, round 2).
        return RenderedPage(unverified=str(unavailable), transient=unavailable.transient)
    _RENDERED_PAGES[text] = RenderedPage(html=html)
    return _RENDERED_PAGES[text]


# A disclosure's opening tag, as a tag NAME rather than a prefix: `<detailsx>`
# is a different element, and `</details>` is not an opening tag at all -- the
# `<` there is followed by `/`, which this cannot match.
DISCLOSURE_OPEN_RE = re.compile(r"<details(?=[\s>/]|$)", re.IGNORECASE)
DISCLOSURE_CLOSE_RE = re.compile(r"</details(?=[\s>]|$)", re.IGNORECASE)
# An HTML comment, including one nobody closed -- which runs to the end of the
# text it was opened in, exactly as CommonMark and the page read it.
HTML_COMMENT_RE = re.compile(r"<!--.*?(?:-->|\Z)", re.DOTALL)


def _blanked(match: re.Match[str]) -> str:
    """The match with every character but its line breaks replaced, so later lines keep their numbers."""
    return "".join(char if char == "\n" else " " for char in match.group(0))


class FoldedSectionReader(HTMLParser):
    """Every heading the page shows that reads as this section, and whether a fold holds it.

    A LIST rather than the first match, because the question a placement asks
    is not "is a heading of this name folded" but "is THE heading this write
    is about to land on folded". Those differ on a body carrying the name
    twice: `section_heading_index` skips a heading carrying inline HTML, so
    with `## Evidence <del>Status</del>` at the top level and a plain
    `## Evidence Status` below an unclosed `<details>`, a reader that answered
    about the first match said "not folded" about the struck-out one and the
    write landed in the fold -- and the rewrite took the `</details>` with it,
    folding `## Validation` too (#1773, round 2, reproduced against GitHub's
    own renderer).

    The identity of the target is carried into the question instead: the
    caller knows which of the body's headings of this name the source model
    chose, and asks about that one by position. So this enumerates the SAME
    SET the source enumerates rather than applying the source's acceptance
    rule -- a `<br>` is a space here because `inline_text` makes it one there,
    and a heading carrying a tag is counted here because it is counted there,
    even though neither reader would choose it.

    A stack rather than a count, because whether a heading is folded is
    whether any disclosure still open around it is CLOSED. `<details open>` is
    displayed on load and hides nothing, so it contributes no fold; a closed
    one nested inside an open one still does (#1773, round 3). A `<details>`
    written INSIDE a heading opens after the `h2` start tag, so the heading's
    own state is taken before it and such a heading is not its own fold.
    """

    def __init__(self, heading: str) -> None:
        super().__init__(convert_charrefs=True)
        self.wanted = heading_identity(heading)
        # One entry per heading the page shows that reads as this section, in
        # document order: True where a fold holds it.
        self.folded: list[bool] = []
        # One entry per `<details>` still open, True where it is a CLOSED one.
        self._folds: list[bool] = []
        self._heading: list[str] | None = None
        self._heading_folded = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        name = tag.lower()
        if name == "details":
            # `<details open>` shows its contents on load, so it hides nothing
            # and folds nothing. GitHub returns it as `<details open="">`, and
            # counting it refused a section the page displays (#1773, round 3).
            # A CLOSED disclosure nested inside an open one still folds what it
            # holds, which is why this is a stack rather than a flag.
            self._folds.append(not any(key.lower() == "open" for key, _ in attrs))
        elif name == "br" and self._heading is not None:
            # A space, which is what `inline_text` makes of a break in a
            # heading. The two readers have to enumerate one set.
            self._heading.append(" ")
        elif name == "h2":
            self._heading = []
            self._heading_folded = any(self._folds)

    def handle_endtag(self, tag: str) -> None:
        name = tag.lower()
        if name == "details":
            # A `</details>` the renderer emits without an opening one is not a
            # document this reader has to model, and popping an empty stack
            # would read a later fold as no fold at all.
            if self._folds:
                self._folds.pop()
        elif name == "h2" and self._heading is not None:
            text, self._heading = "".join(self._heading), None
            if heading_identity(text) == self.wanted:
                self.folded.append(self._heading_folded)

    def handle_data(self, data: str) -> None:
        if self._heading is not None:
            self._heading.append(data)


def folded_headings_on_the_page(html: str, heading: str) -> list[bool]:
    """One entry per heading the page shows reading as this section: True where a fold holds it."""
    reader = FoldedSectionReader(heading)
    reader.feed(html)
    reader.close()
    return reader.folded


def section_heading_line(body: str, heading: str) -> int | None:
    """Which line `## <heading>` opens on, zero-based, or None if the body shows none."""
    tokens = _parsed(body)
    index = section_heading_index(tokens, heading)
    return None if index is None or tokens[index].map is None else tokens[index].map[0]


def open_disclosure_line(body: str, before_line: int) -> int | None:
    """The line a `<details>` still open at `before_line` was opened on, zero-based, or None.

    Read off the raw-HTML blocks the parser found rather than off the body's
    text, so a `<details>` inside a fenced example is not named as the one
    that folded something: a fence is a `fence` token and never an
    `html_block`. A disclosure written inside a paragraph is not read either
    -- the token that holds it carries the paragraph's line and not its own --
    so a fold from one is a refusal that names no line, which is the whole of
    what it costs.

    A commented-out disclosure is not one. The factory writes its own metadata
    as an HTML comment and authors leave notes in them, so a `<details>` a
    comment holds counted toward the nesting and named a line whose repair
    does nothing (#1773, round 2). The comment's text is blanked rather than
    removed, so the line numbers of everything after it still hold.

    The OUTERMOST of the ones still open is named, not the innermost. The
    refusal tells an author which element to close, and closing an inner
    disclosure inside an outer one that is also open leaves the section
    folded by the outer one -- a repair that does not repair. The outermost is
    the one whose closing puts the section back on the page.

    This counts opening tags against closing ones, which is the nesting model
    the page is asked to replace. It decides nothing: the page has already
    said the section is folded, and this only looks for the line to name.
    """
    opened: list[int] = []
    for token in _parsed(body):
        if token.type != "html_block" or token.map is None or token.map[0] >= before_line:
            continue
        content = HTML_COMMENT_RE.sub(_blanked, token.content)
        tags = sorted(
            [(match.start(), True) for match in DISCLOSURE_OPEN_RE.finditer(content)]
            + [(match.start(), False) for match in DISCLOSURE_CLOSE_RE.finditer(content)]
        )
        for offset, opens in tags:
            if opens:
                opened.append(token.map[0] + content.count("\n", 0, offset))
            elif opened:
                opened.pop()
    return opened[0] if opened else None


def _unshown_refusal(body: str, heading: str) -> str:
    """Why a section the page does not show as a heading is not a write, naming the block that ate it."""
    lines = MARKDOWN_LINE_ENDING_RE.split(body)
    written_lines = len(lines) - 1 if lines and lines[-1] == "" else len(lines)
    open_block = unterminated_block(_parsed(body), written_lines)
    where = (
        f" below {open_block[1]} opened at line {open_block[0].map[0] + 1}"
        if open_block is not None
        else ""
    )
    return (
        f"the `## {heading}` section this write places{where} is not a heading on the page, so "
        "it would be in the body and absent from what a reader sees"
    )


# How much of the author's line a refusal quotes. The line is named by its
# NUMBER, so the quotation is there to recognise it by, not to reproduce it --
# and a `<details …>` carrying a long attribute is a line a body can hold
# 65,536 characters of, which composed a comment past what GitHub stores and
# got the whole note refused (#1773, round 3).
QUOTED_LINE_LIMIT = 200


def _quotable(line: str) -> str:
    """Enough of a line to recognise it by, with an ellipsis where the rest went."""
    return line if len(line) <= QUOTED_LINE_LIMIT else f"{line[: QUOTED_LINE_LIMIT - 1]}\u2026"


def _folded_refusal(written: str, heading: str) -> str:
    """Why a section the page folds away is not a write, naming the disclosure that folds it."""
    line = section_heading_line(written, heading)
    at = None if line is None else open_disclosure_line(written, line)
    if at is None:
        where = "inside a `<details>`"
    else:
        # `code_span`, not a pair of backticks: the opening line is the
        # author's characters, this sentence reaches a comment the app posts,
        # and a backtick inside the tag closes a hand-written span early --
        # after which an `@name` in the same tag is a mention GitHub delivers
        # to someone with nothing to do with this (#1730, round 2; #1773,
        # round 2).
        opening = _quotable(MARKDOWN_LINE_ENDING_RE.split(written)[at].strip())
        where = f"inside the `<details>` opened at line {at + 1} ({code_span(opening)})"
    return (
        f"the `## {heading}` section this write places renders {where}, so the page folds it "
        "away and a reader sees a disclosure where the section should be; closing that element "
        "above the section is what puts the section back on the page"
    )


def unverified_note(reason: str) -> str:
    """The sentence an author is owed when the page could not be asked about their write."""
    return (
        f"rendered view unverified: {reason}. Whether the section this write places is folded "
        "away behind a disclosure was decided by the source model alone, which cannot see a "
        "fold"
    )


def _unasked_refusal(heading: str, reason: str) -> str:
    """What an author is told when the page could not be asked and, as things stand, never can be."""
    return (
        f"the page could not be asked whether the `## {heading}` section this write places is "
        f"folded away: {reason}. That is a condition of this environment rather than a blip, so "
        "the write stands down instead of placing a section on a weaker check than a lane runs -- "
        "export a token the renderer accepts and run again"
    )


# The base of the token appended to the heading this write places, so the page
# can be asked about THAT heading and no other. Renaming a heading cannot
# change what folds it, so the probe body's fold structure is the real one.
PLACEMENT_PROBE_MARK = "wsx7placementprobe"


# How many marks to try before giving up. Each retry costs one render, and a
# body that collides with three of them in a row is a body nothing should keep
# rendering for.
PLACEMENT_PROBE_ATTEMPTS = 3


def placement_probe_mark(written: str, attempt: int = 0) -> str:
    """The `attempt`-th mark this body does not already carry, chosen the same way every time.

    Uniqueness by construction rather than by hoping. The base is a string no
    author writes, which is not the same as one no author CAN write -- by
    accident, or by someone who has read this code -- and a body already
    carrying it puts two matches on the page and draws the ambiguity refusal:
    safe, but a refusal on a legitimate body with a message about a heading
    the author cannot see (#1773, round 4).

    Deterministic, never random: the recorded renderer responses are keyed by
    the sha256 of the probe body, so the same body has to produce the same
    probe on every run or no fixture ever matches. Counting up terminates
    because the body is finite and the candidates are not.

    This scan is the cheap FIRST GUESS and not the guarantee. It is an exact,
    case-sensitive substring scan of the source, and the property is about the
    PAGE: `## Evidence Status wsx7placementprob&#101;` carries no such
    substring and renders as a heading whose text is exactly the mark, as do a
    case variant, an empty comment inside the word, and an `<em>` around its
    last letter. All four were confirmed against the renderer, and all four
    made the page show the name twice -- so the exactly-one check refused a
    placement the page shows unfolded (#1773, round 5).

    Mirroring `heading_identity` in this scan would model the renderer, which
    is the thing the mark exists to avoid. So `attempt` lets the caller ask
    for the next candidate and settle the question where it lives: render,
    and if the page shows the name more than once, come back for another mark.
    """
    seen, suffix = 0, 0
    while True:
        mark = PLACEMENT_PROBE_MARK if suffix == 0 else f"{PLACEMENT_PROBE_MARK}{suffix}"
        if mark not in written:
            if seen == attempt:
                return mark
            seen += 1
        suffix += 1


SETEXT_UNDERLINE_RE = re.compile(r"^[ \t]{0,3}(=+|-+)[ \t]*$")


def probe_body_naming_one_heading(
    written: str, heading: str, heading_line: int, mark: str = PLACEMENT_PROBE_MARK
) -> str | None:
    """`written` with the heading this write places renamed to something unique, or None.

    The page cannot be asked "is the heading I placed folded" while several
    headings read as that name, and which rendered heading is which cannot be
    decided without a model of what the renderer does to a heading carrying a
    tag -- a model round 2 measured as needing two branches. So the question
    is made unambiguous instead of the answer being guessed: the placed
    heading gets a name nothing else has, and the page is asked about that.

    A setext underline below the renamed line goes, because the line above it
    is an ATX heading now and the underline would be a rule of its own. The
    replacement is one line for one line, so every line number below it holds
    and the body's block structure -- which is what folds anything -- is
    untouched.
    """
    lines = MARKDOWN_LINE_ENDING_RE.split(written)
    if not 0 <= heading_line < len(lines):
        return None
    lines[heading_line] = f"## {heading} {mark}"
    following = heading_line + 1
    if following < len(lines) and SETEXT_UNDERLINE_RE.match(lines[following]):
        lines[following] = ""
    return "\n".join(lines)


def could_be_folded(written: str) -> bool:
    """Whether anything above this heading could fold it, read as text rather than as structure.

    A page folds a heading only inside a `<details>`, and a `<details>` is
    text an author wrote. So a body with no such opening tag has nothing to
    ask the page about, and asking anyway would spend a request on every
    ordinary write.

    The WHOLE body, not the text above the heading. Gating on what sits above
    while asking a question about the body was a rule whose answer depended on
    where an unrelated disclosure happened to sit -- the same body refused or
    placed according to something that had nothing to do with it (#1773,
    round 3). The gate and the question are about the same text now.

    Read as text on purpose, which makes it over-inclusive: a `<details>`
    inside a fenced example costs one call and the page answers that nothing
    is folded. Under-inclusive it cannot be -- a fold needs the tag -- and
    that is the direction that would matter.
    """
    return DISCLOSURE_OPEN_RE.search(written) is not None


class PlacementAnswer(NamedTuple):
    """What a placement check decided, and what it could not ask.

    Two fields because they are two different things a caller owes an author.
    `refusal` is why this write did not happen. `unverified` is a question
    that went unasked -- the renderer was unreachable, so the check that ran
    is weaker than the one a lane runs -- and it travels on an ACCEPTED write
    too, which is the case it exists for: a renderer 503 used to accept a
    folded placement with nothing visible anywhere (#1773, round 2).
    """

    refusal: str | None = None
    unverified: str | None = None


def placement_refusal(body: str, written: str, heading: str) -> PlacementAnswer:
    """Why the page would not show the section this write places, or None.

    A write is a write when a reader can see it. Every placement is either
    before a heading the page shows or at the end of the body, and the end of
    a body holding a block that never closes is inside that block: the section
    is then in the source, absent from the page, and still carried to every
    gate by the metadata beside it -- an approval over evidence nobody can
    read (#1734).

    Asked of the result rather than of the shapes that produce it, with the
    same call that answers whether a body has a section at all. A write whose
    section the page does not show is wrong however it got there, and a
    postcondition cannot be argued out of by the next placement rule.

    Absent from the page is one way to be unreadable and folded away is the
    other, and the parse cannot see the second: a `<details>` ends at a blank
    line to CommonMark while the element stays open on the page, so a section
    written below an unclosed one is a heading to every reader here and a
    heading behind a disclosure to everyone else (#1742, item 3). Which is a
    question about element nesting across a whole body, so it is asked of the
    page rather than modelled -- the move the readiness gate made for the
    status lines it reads (#1745), with the same fallback: no page means the
    source model's answer and a sentence saying the page went unread, never a
    silent accept of something the model would not accept on its own. That
    sentence comes BACK to the caller rather than going to a log, because
    every plane that runs this check runs it where stderr is a step log and
    the author is somewhere else (#1740, #1773 round 2).

    What the page is asked is whether it folds ANY heading reading as this
    section, not whether it folds the one this write lands on. The first
    version asked about the first heading of that name, which is a true answer
    about the wrong element: a struck-out `## Evidence <del>Status</del>` above
    a plain heading inside a fold answered "not folded" for a write that landed
    in the fold, and took the `</details>` with it so `## Validation` folded too
    (#1773, round 2). Picking the right one instead needs a model of what the
    renderer does to a heading carrying a tag -- it decorates some and leaves
    others -- and that model is the thing this seam exists not to build. The
    question with no index in it has neither problem and errs toward refusing.

    A section is refused for the fold the page shows, not for the fold its own
    text makes. A `<details>` an author opens INSIDE the section folds that
    section's contents, and whether those contents are readable is the reader's
    question -- the gate reads folded text and refuses a folded status on its
    own account (#1769). What a placement decides is whether the heading is
    somewhere a reader arrives at, so a heading the page shows unfolded is
    placed whatever its section then holds.
    """
    if not has_markdown_section(written, heading):
        return PlacementAnswer(refusal=_unshown_refusal(body, heading))
    heading_line = section_heading_line(written, heading)
    if heading_line is None or not could_be_folded(written):
        return PlacementAnswer()
    # Uniqueness is settled against the PAGE, because that is what it is a
    # claim about. The source scan picks a candidate, the page is asked, and a
    # name the page shows twice sends the loop back for the next candidate --
    # bounded, so a pathological body refuses rather than spins (#1773,
    # round 5).
    shown: list[bool] = []
    for attempt in range(PLACEMENT_PROBE_ATTEMPTS):
        mark = placement_probe_mark(written, attempt)
        probe = probe_body_naming_one_heading(written, heading, heading_line, mark)
        if probe is None:
            return PlacementAnswer(refusal=_unshown_refusal(body, heading))
        page = rendered_page(probe)
        if page.unverified is not None:
            if not page.transient:
                return PlacementAnswer(refusal=_unasked_refusal(heading, page.unverified))
            return PlacementAnswer(unverified=unverified_note(page.unverified))
        shown = folded_headings_on_the_page(page.html, f"{heading} {mark}")
        if not shown:
            # A heading the parse reads and the page does not show at all. The
            # same refusal as a swallowed section, because that is what it is.
            return PlacementAnswer(refusal=_unshown_refusal(body, heading))
        if len(shown) == 1:
            break
    else:
        # Every candidate collided on the page. Refusing says so rather than
        # picking one of them.
        return PlacementAnswer(refusal=_unshown_refusal(body, heading))
    # Exactly the heading this write places, because the probe gave it a name
    # nothing else has. "Any heading of this name" was the round-2 answer and
    # it refused placements a reader can see: a raw `<h2>Evidence Status</h2>`
    # inside a CLOSED `<details>`, or a heading inside a `<summary>`, is a
    # folded heading of this name that the PARSER never reads as an h2 at all
    # -- so `rejected_heading_note` cannot flag it either, and the author got
    # a refusal naming no line and no repair (#1773, round 3).
    return PlacementAnswer(refusal=_folded_refusal(written, heading) if shown[0] else None)


def insert_markdown_section(
    body: str,
    heading: str,
    content: str,
    *,
    before_heading: str | None = None,
    after_heading: str | None = None,
) -> str:
    """The body with this section rewritten, where the author already had one.

    A section that exists is replaced where it stands. Placement is a question
    only about a section the body does not have yet: moving one an author
    placed reorders their document for them, and it did -- the rewrite that
    stopped deleting a `# Release blockers` heading under Evidence Status then
    lifted Evidence Status out from under it, because the cut was shorter and
    the re-insert went to the placement point rather than back to the offset
    it came from (#1734, round 2). Keeping the content is the headline;
    keeping it where its author put it is the property.

    `before_heading` and `after_heading` place a NEW section: above a heading
    the page shows, or directly below one, respectively. `after_heading` is
    how a carried-notes section lands under the status list it was carried out
    of, rather than merely somewhere above the next heading.
    """
    # Newlines only, at both ends. The first line's indentation is content
    # where a block was written as indented code -- taking four spaces off it
    # turns a `## Validation` a reviewer pasted as an example into a heading --
    # and the trailing spaces on the last line are a line break on the page.
    return inserted_markdown_section(
        body,
        heading,
        content,
        before_heading=before_heading,
        after_heading=after_heading,
    ).body


class SectionInsert(NamedTuple):
    """The body an insert produced, why it stood down, and what it could not ask."""

    body: str
    refusal: str | None = None
    unverified: str | None = None


def inserted_markdown_section(
    body: str,
    heading: str,
    content: str,
    *,
    before_heading: str | None = None,
    after_heading: str | None = None,
) -> SectionInsert:
    """`insert_markdown_section`, with the reason a stand-down happened beside the body.

    The reason comes back rather than only reaching a log, because the body an
    insert declines to write is a body with no such section -- so a caller
    that asked the postcondition about it a second time was told "not a
    heading on the page", and the fold that actually stopped the write stayed
    in a step log nobody opens. The specific reason is the one an author can
    act on (#1773).

    `unverified` rides along for the same reason one step further: a write
    that went ahead without the page having been asked was decided by a
    weaker check than a lane runs, and a caller with a surface the author
    reads is the only place that fact is worth anything (#1773, round 2).
    """
    section = f"## {heading}\n{content.strip(chr(10))}".rstrip("\n")
    # The author's body, untrimmed, because that is the text the cut is made
    # on and the text `section_write_refusal` answers about. Trimming here and
    # not there made the guard name a refusal while the write went ahead.
    bounds = _section_bounds(body, heading)
    removed, refusal, _ = _section_removed(body, heading)
    if refusal is not None:
        # Reported here and only here: appending the new section to a body
        # whose old one could not be removed would leave two, and returning
        # the body without saying so let a caller believe it had written.
        log(f"refusing to rewrite the `{heading}` section: {refusal}")
        return SectionInsert(body, refusal)
    written = _rewritten(body, bounds, removed, section, heading, before_heading, after_heading)
    answer = placement_refusal(body, written, heading)
    if answer.unverified is not None:
        log(answer.unverified)
    if answer.refusal is not None:
        log(f"refusing to write the `{heading}` section: {answer.refusal}")
        return SectionInsert(body, answer.refusal, answer.unverified)
    return SectionInsert(written, None, answer.unverified)


def _rewritten(
    body: str,
    bounds: tuple[int, int, int, str | None] | None,
    removed: str,
    section: str,
    heading: str,
    before_heading: str | None,
    after_heading: str | None,
) -> str:
    """The body with the section in place, before the postcondition is asked of it."""
    if bounds is not None:
        # In place: everything above the old section's heading, the new
        # section, then the rest. Above the splice only line endings come off,
        # because two spaces at the end of that line are a hard break on the
        # page and trimming them changed how a body renders around a section
        # this was only asked to replace. Below it the leading whitespace does
        # come off, and that is not symmetry lost: an indent kept there can
        # stop the next line being a boundary at all once the section's own
        # content is a list -- the section would then run past the heading that
        # used to end it. A later copy of the section is cut from the tail,
        # which is the same cut `_section_removed` makes, and only when there
        # is one, since that cut also normalises blank lines.
        above = body[: bounds[0]].rstrip("\r\n")
        below = body[bounds[2] :]
        if _section_bounds(below, heading) is not None:
            below, _, _ = _section_removed(below, heading)
        return "\n\n".join(part for part in (above, section, below.strip()) if part)
    cleaned = removed.strip()
    if before_heading and (at := section_heading_offset(cleaned, before_heading)) is not None:
        return f"{cleaned[:at]}{section}\n\n{cleaned[at:]}"
    if after_heading and (span := _section_bounds(cleaned, after_heading)) is not None:
        above, below = cleaned[: span[2]].rstrip(), cleaned[span[2] :].strip()
        return "\n\n".join(part for part in (above, section, below) if part)
    if cleaned:
        return f"{cleaned}\n\n{section}"
    return section


def _parse_timestamp(value: str) -> "datetime | None":
    from datetime import datetime
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _normalize_login(login: str) -> str:
    return login.removesuffix("[bot]").strip().casefold()


def normalize_provider_env(env: dict[str, str]) -> dict[str, str]:
    normalized = dict(env)
    if not normalized.get("OPENAI_API_KEY"):
        fallback = normalized.get("GITHUB_CODESPACES_OPENAI_API_KEY", "").strip()
        if fallback:
            normalized["OPENAI_API_KEY"] = fallback
    return normalized


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if value:
        return value
    print(f"error: required environment variable {name} is not set", file=sys.stderr)
    sys.exit(1)


def extract_persona(prompt_file: Path) -> str:
    """Extract persona name from the prompt file heading."""
    try:
        for line in prompt_file.read_text().splitlines():
            if line.startswith("# "):
                return line[2:].split("—")[0].split("–")[0].strip()
    except OSError:
        pass
    return ""
