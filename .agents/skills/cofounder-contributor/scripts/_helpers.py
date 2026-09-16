"""Shared helpers for contributor runtime modules."""

from __future__ import annotations

import bisect
import json
import os
import re
import subprocess
import sys
from collections.abc import Callable
from itertools import groupby
from pathlib import Path

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
            longest = max((len(list(run)) for char, run in groupby(token.content) if char == "`"), default=0)
            ticks = "`" * (longest + 1)
            pad = " " if token.content.startswith("`") or token.content.endswith("`") else ""
            parts.append(f"{ticks}{pad}{token.content}{pad}{ticks}")
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
    """
    wanted = " ".join(heading.split()).casefold()
    return next(
        (
            index
            for index, token in enumerate(tokens)
            if is_section_heading(token)
            and " ".join(inline_text(tokens[index + 1].children).split()).casefold() == wanted
        ),
        None,
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
            return f"a `{token.markup}` code fence with no closing line"
        if token.type == "html_block" and (missing := _missing_html_closer(token)) is not None:
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


def placement_refusal(body: str, written: str, heading: str) -> str | None:
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
    """
    if has_markdown_section(written, heading):
        return None
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
        return body
    written = _rewritten(body, bounds, removed, section, heading, before_heading, after_heading)
    if (unshown := placement_refusal(body, written, heading)) is not None:
        log(f"refusing to write the `{heading}` section: {unshown}")
        return body
    return written


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
