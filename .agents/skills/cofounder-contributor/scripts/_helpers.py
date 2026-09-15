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
    """
    if token.level != 0:
        return False
    if token.type == "hr":
        return token.markup.startswith("-")
    return token.type == "heading_open" and token.tag == "h2"


def _section_bounds(body: str, heading: str) -> tuple[int, int, int] | None:
    """Where `## <heading>` begins, where its text begins, and where the section ends.

    One answer for the reader and the writer. `markdown_section` returns the
    middle slice and `strip_markdown_section` cuts the outer one, so the text
    a caller reads is exactly the text a rewrite replaces -- a line counted as
    a completion cannot be left outside every section by the rewrite that
    follows it (#1723, round 2).

    The boundary is asked of the parser because matching a three-dash line is
    not the rule the page applies: three dashes directly under a line of text
    are that line's setext underline, and a section read as ending there is
    empty on the page and whole here.
    """
    match = re.search(rf"(?mi)^## {re.escape(heading)}\n", body)
    if match is None:
        return None
    line_starts = [0] + [end.end() for end in MARKDOWN_LINE_ENDING_RE.finditer(body)]
    heading_line = bisect.bisect_right(line_starts, match.start()) - 1
    for token in MARKDOWN.parse(MARKDOWN_LINE_ENDING_RE.sub("\n", body)):
        if token.map and token.map[0] > heading_line and is_section_boundary(token):
            return match.start(), match.end(), line_starts[token.map[0]]
    return match.start(), match.end(), len(body)


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


def strip_markdown_section(body: str, heading: str) -> str:
    """The body without the section under `## <heading>`, heading included.

    Every occurrence goes, not only the first: `markdown_section` reads the
    first, so leaving a later one behind puts the stale copy where the next
    read will find it. The loop re-parses because each cut shortens the body,
    and it terminates because each cut takes at least the heading line.
    """
    stripped = body
    while (bounds := _section_bounds(stripped, heading)) is not None:
        stripped = stripped[: bounds[0]] + stripped[bounds[2] :]
    return re.sub(r"\n{3,}", "\n\n", stripped.strip())


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
    cleaned = strip_markdown_section(body.strip(), heading).strip()
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
