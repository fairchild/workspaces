"""Shared helpers for contributor runtime modules."""

from __future__ import annotations

import bisect
import json
import os
import re
import subprocess
import sys
from collections.abc import Callable
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


def is_section_boundary(token: Token) -> bool:
    """Whether a parsed token starts something other than the section above it.

    A section ends at a top-level h2 or a top-level `---` rule -- one nested in
    a list or a quote is inside the section rather than after it. The h2 counts
    however the author made it one, hashes or an underline: an underline is
    what turns the line above it into a heading, and the page then shows a
    heading there whatever the author meant.

    This is the rule the rendered read always applied; what changed is that the
    written read asks it too, on the same tokens, so neither can place a
    boundary the other does not (#1723). Both directions of that matter. A
    literal three-dash match does not stop at `-----` or at a setext underline,
    which the page stops at; and it does stop at a `##` heading or a `---` rule
    inside a code fence, which the page shows as code -- so a fenced rule could
    truncate a section for the reader while a person saw it whole.

    Its answers for `***`, `___`, an h1 and an h3 are the answers the readers
    already gave: none of those ends a section.

    A fence that never closes is the exception, and it is the line rather than
    the token that carries it -- see `reparsed_without_runaway`.
    """
    if token.level != 0:
        return False
    if token.type == "hr":
        return token.markup.startswith("-")
    return token.type == "heading_open" and token.tag == "h2"




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


def _section_bounds(body: str, heading: str) -> tuple[int, int, int, str | None] | None:
    """Where `## <heading>` begins, where its text begins, and where the section ends.

    One answer for the reader and the writer. `markdown_section` returns the
    middle slice and `strip_markdown_section` cuts the outer one, so the text
    a caller reads is exactly the text a rewrite replaces -- a line counted as
    a completion cannot be left outside every section by the rewrite that
    follows it (#1723, round 2).

    The boundary is asked of the parser because matching a three-dash line is
    not the rule the page applies: three dashes directly under a line of text
    are that line's setext underline, and a section read as ending there is
    empty on the page and whole here. An unclosed fence is where the parser's
    answer is the worse one, and `reparsed_without_runaway` is that exception --
    whichever boundary comes first ends the section.
    """
    # `\r?\n`, because GitHub stores a body with whatever endings the client
    # sent and the rest of this reads through `MARKDOWN_LINE_ENDING_RE`. Anchored
    # on `\n` alone, a CRLF body read as having no section while
    # `has_markdown_section` said it had one, and the writer then appended a
    # second copy of it rather than replacing the first.
    match = re.search(rf"(?mi)^## {re.escape(heading)}\r?\n", body)
    if match is None:
        return None
    line_starts = [0] + [end.end() for end in MARKDOWN_LINE_ENDING_RE.finditer(body)]
    heading_line = bisect.bisect_right(line_starts, match.start()) - 1
    lines = MARKDOWN_LINE_ENDING_RE.split(body)
    tokens = MARKDOWN.parse(MARKDOWN_LINE_ENDING_RE.sub("\n", body))

    def first_boundary_after(parsed: list[Token]) -> int | None:
        return next(
            (
                token.map[0]
                for token in parsed
                if token.map and token.map[0] > heading_line and is_section_boundary(token)
            ),
            None,
        )

    located = first_boundary_after(tokens)
    repaired = reparsed_without_runaway(tokens, lines)
    if repaired is not None:
        # A runaway fence hides every heading below it. Whichever boundary
        # comes first is the section's end, and the repaired parse is the only
        # one that can see the hidden ones.
        hidden_boundary = first_boundary_after(repaired)
        if hidden_boundary is not None and (located is None or hidden_boundary < located):
            located = hidden_boundary
    stop = len(line_starts) if located is None else located
    end = line_starts[stop] if stop < len(line_starts) else len(body)
    # The number of lines the author wrote, which is what a block's span reaches
    # when it runs to the end of the body.
    written_lines = len(lines) - 1 if lines and lines[-1] == "" else len(lines)
    return match.start(), match.end(), end, _write_refusal(tokens, heading_line, located, written_lines)


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
    tokens: list[Token], heading_line: int, located: int | None, line_count: int
) -> str | None:
    """Why replacing this section would corrupt the body, or None.

    Two shapes, and both come down to a cut whose far end the author did not
    write. The first: the heading a literal match found is a `##` line inside a
    fenced example, which is code rather than a heading, so cutting from there
    to the section's end takes the fence's closing line along and the next
    write to any section above the opener takes the rest of the body.

    The second: the section has no boundary after it and got there through a
    block that never closed. What decides there is the block's kind, not where
    the section sits. A fence with no closing line shows the rest of the body
    as code, so a reader sees that text and the section really does run to the
    end: cutting to the end is correct, and refusing would cost a write to a
    body that works, paid by an author who did nothing wrong. A raw HTML block
    of kinds 1 to 5 hides its contents, so a cut there is over text nobody can
    see, and that is the one to refuse.

    The two fence cases are told apart by the repair rather than by this: where
    an unclosed fence hides a heading, `reparsed_without_runaway` finds it and
    the section ends there, so this never sees the case. Where the repair finds
    no boundary, nothing below the fence is a section and everything below it
    is visible as code.

    A last section whose final block closes, or is a `<details>` or any other
    kind-6 or kind-7 block, or is indented code, is not this shape either.
    """
    holder = next(
        (
            token
            for token in tokens
            if token.type in {"fence", "code_block"}
            and token.map
            and token.map[0] <= heading_line < token.map[1]
        ),
        None,
    )
    if holder is not None and holder.map[1] < line_count and (located is None or located > holder.map[1]):
        return (
            f"the `##` line at line {heading_line + 1} is inside the code block opened at line "
            f"{holder.map[0] + 1}, so it is an example rather than a heading; replacing it would "
            "take the block's closing line with it"
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
    return re.search(rf"(?mi)^## {re.escape(heading)}\s*$", body) is not None


def _section_removed(body: str, heading: str) -> tuple[str, str | None]:
    """The body without this section, or the body and the reason it stands.

    Every occurrence goes, not only the first: `markdown_section` reads the
    first, so leaving a later one behind puts the stale copy where the next
    read will find it. The loop re-parses because each cut shortens the body,
    and it terminates because each cut takes at least the heading line.

    The cut and the reason for refusing it come from one call on one text, so
    a caller cannot be told the write was refused while the write happened, or
    the reverse. That pair disagreed once, over nothing more than whether the
    body had been trimmed first.
    """
    stripped = body
    while (bounds := _section_bounds(stripped, heading)) is not None:
        if bounds[3] is not None:
            return body, bounds[3]
        stripped = stripped[: bounds[0]] + stripped[bounds[2] :]
    return re.sub(r"\n{3,}", "\n\n", stripped.strip()), None


def strip_markdown_section(body: str, heading: str) -> str:
    """The body without the section under `## <heading>`, heading included.

    A refused cut is reported here rather than passed back, because every
    caller wants the body either way; the run's output is where a refusal has
    to be visible.
    """
    stripped, refusal = _section_removed(body, heading)
    if refusal is not None:
        log(f"refusing to rewrite the `{heading}` section: {refusal}")
    return stripped


def extract_blocked_by(body: str) -> list[int]:
    """The issue numbers a `## Blocked By` section names, in the order written.

    The reader of record for both paths that ask: the contributor runtime
    through `github_state` and the lifecycle sync through its own entry point.
    They held character-identical copies and drifted the moment one of them
    read a boundary the other did not, so there is one copy (#1723, round 2).
    """
    numbers = [int(number) for number in re.findall(r"#(\d+)", markdown_section(body, "Blocked By"))]
    return list(dict.fromkeys(numbers))


def insert_markdown_section(
    body: str,
    heading: str,
    content: str,
    *,
    before_heading: str | None = None,
) -> str:
    section = f"## {heading}\n{content.strip()}".rstrip()
    # The author's body, untrimmed, because that is the text the cut is made
    # on and the text `section_write_refusal` answers about. Trimming here and
    # not there made the guard name a refusal while the write went ahead.
    removed, refusal = _section_removed(body, heading)
    if refusal is not None:
        # Reported here and only here: appending the new section to a body
        # whose old one could not be removed would leave two, and returning
        # the body without saying so let a caller believe it had written.
        log(f"refusing to rewrite the `{heading}` section: {refusal}")
        return body
    cleaned = removed.strip()
    if before_heading and has_markdown_section(cleaned, before_heading):
        pattern = rf"(?mi)^(## {re.escape(before_heading)})\s*$"
        return re.sub(pattern, lambda match: f"{section}\n\n{match.group(1)}", cleaned, count=1)
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
