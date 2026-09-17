"""Claiming issues, branching, committing, and PR operations."""

from __future__ import annotations

import hmac
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from _helpers import (
    AGENT_CLAIM_LABEL,
    AGENT_CLAIM_LABEL_COLOR,
    AGENT_CLAIM_LABEL_DESCRIPTION,
    AGENT_LANE_LABEL,
    AGENT_LANE_LABEL_COLOR,
    AGENT_LANE_LABEL_DESCRIPTION,
    AGENT_MERGEABLE_LABEL,
    AGENT_MERGEABLE_LABEL_COLOR,
    AGENT_MERGEABLE_LABEL_DESCRIPTION,
    AGENT_READY_LABEL,
    AGENT_READY_LABEL_COLOR,
    AGENT_READY_LABEL_DESCRIPTION,
    GH_DISCUSS_SCRIPT,
    GITHUB_API_TIMEOUT,
    REPO_ROOT,
    VALIDATION_TIMEOUT,
    VALIDATOR_SCRIPT,
    _normalize_login,
    branch_name_for_issue,
    gate_reads_markdown_section,
    has_markdown_section,
    rejected_heading_note,
    insert_markdown_section,
    issue_label_names,
    issue_label_presence,
    log,
    markdown_section,
    persona_slug,
    run_checked,
    run_optional,
    short_persona_name,
)
from evidence import (
    _ci_check_name,
    _evidence_item_kind,
    _extract_evidence_metadata,
    _extract_test_commands,
    _has_unautomatable_evidence,
    _needs_macos_evidence,
    _needs_screenshot_evidence,
    classify_evidence_errors,
    resolve_named_ci_evidence,
    requested_evidence_contract,
    render_execution_summary_body,
    review_evidence_gate_error,
    synthesize_initial_execution_evidence,
    update_evidence_entries,
    validate_evidence_accounting,
    validate_requested_test_commands,
)
from github_state import (
    current_branch,
    default_branch,
    detect_bot_login,
    extract_pr_issue_reference,
    fetch_detailed_issue,
    find_issue_execution_state,
    find_pr_review_state,
    repo_owner_name,
)
from telemetry import redact_secrets

_label_cache: set[str] | None = None
AUTHOR_LABEL_COLOR = "BFD4F2"
AUTHOR_LABEL_DESCRIPTION = "PRs authored by the {agent} agent"
EVIDENCE_BLOCK_LABEL = "blocked:evidence"
EVIDENCE_BLOCK_LABEL_COLOR = "B60205"
EVIDENCE_BLOCK_LABEL_DESCRIPTION = "Required merge evidence is unavailable"

APP_BOT_GIT_IDENTITIES = {
    # PR authorship comes from the GitHub App token; commit/contributor
    # attribution comes from this git identity. Keep reviewer-only apps out of
    # this table so they cannot accidentally seed CONTRIBUTOR status.
    "april-clearwater": {
        "login": "april-clearwater[bot]",
        "email": "268297116+april-clearwater[bot]@users.noreply.github.com",
    },
    "workspace-agents": {
        "login": "workspace-agents[bot]",
        "email": "266434718+workspace-agents[bot]@users.noreply.github.com",
    },
}


def app_bot_git_identity(env: dict[str, str], persona: str, bot_login: str) -> tuple[str, str]:
    app_slug = env.get("GH_APP_SLUG", "").strip()
    if not app_slug:
        return bot_login or short_persona_name(persona), f"{persona_slug(persona)}@users.noreply.github.com"

    identity = APP_BOT_GIT_IDENTITIES.get(app_slug)
    if identity is None:
        raise RuntimeError(
            f"GH_APP_SLUG={app_slug!r} does not have an approved commit identity. "
            "Add it to APP_BOT_GIT_IDENTITIES only for apps that are allowed to push commits."
        )
    return identity["login"], identity["email"]


def _dismiss_own_blocking_reviews(pr_number: int, bot_login: str, env: dict[str, str]) -> None:
    """Dismiss prior CHANGES_REQUESTED reviews from this bot before approving."""
    owner, name = repo_owner_name(env)
    raw = run_optional(
        [
            "gh", "api", f"repos/{owner}/{name}/pulls/{pr_number}/reviews",
            "--jq", f'[.[] | select(.user.login == "{bot_login}" and .state == "CHANGES_REQUESTED") | .id] | .[]',
        ],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    )
    for review_id in raw.strip().splitlines():
        review_id = review_id.strip()
        if not review_id:
            continue
        run_optional(
            [
                "gh", "api", f"repos/{owner}/{name}/pulls/{pr_number}/reviews/{review_id}/dismissals",
                "-X", "PUT",
                "-f", "message=Superseded by subsequent approval from the same reviewer.",
                "-f", "event=DISMISS",
            ],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
            default="",
        )
        log(f"Dismissed prior CHANGES_REQUESTED review {review_id} on PR #{pr_number}")


def ensure_label_exists(env: dict[str, str], name: str, color: str, description: str) -> None:
    global _label_cache
    if _label_cache is None:
        labels = run_optional(
            ["gh", "label", "list", "--limit", "200", "--json", "name"],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
            default="[]",
        )
        try:
            _label_cache = {item["name"] for item in json.loads(labels)}
        except json.JSONDecodeError:
            _label_cache = set()
    if name in _label_cache:
        return
    run_checked(
        [
            "gh",
            "label",
            "create",
            name,
            "--color",
            color,
            "--description",
            description,
        ],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )
    _label_cache.add(name)


def ensure_claim_label(env: dict[str, str]) -> None:
    ensure_label_exists(env, AGENT_LANE_LABEL, AGENT_LANE_LABEL_COLOR, AGENT_LANE_LABEL_DESCRIPTION)
    ensure_label_exists(env, AGENT_CLAIM_LABEL, AGENT_CLAIM_LABEL_COLOR, AGENT_CLAIM_LABEL_DESCRIPTION)


def author_label_for_persona(persona: str) -> str:
    labels = {
        "april-clearwater": "author:april",
        "plat-ironwood": "author:plat",
    }
    slug = persona_slug(persona)
    return labels.get(slug, f"author:{slug}")


def claim_marker(issue_number: int, persona: str, branch: str) -> str:
    return (
        f"<!-- contributor:issue={issue_number};status=claimed;"
        f"agent={persona_slug(persona)};branch={branch} -->"
    )


def compose_claim_comment(issue_number: int, persona: str, branch: str) -> str:
    return (
        f"*{persona}*\n\n"
        f"Claiming this issue for execution on `{branch}`.\n\n"
        f"{claim_marker(issue_number, persona, branch)}"
    )


def pr_marker(issue_number: int, persona: str) -> str:
    return f"<!-- contributor:issue={issue_number};agent={persona_slug(persona)} -->"


def compose_pr_body(
    issue_number: int,
    persona: str,
    summary_body: str,
) -> str:
    return (
        f"*{persona}*\n\n"
        f"{summary_body.strip()}\n\n"
        f"Closes #{issue_number}\n\n"
        f"{pr_marker(issue_number, persona)}"
    )


# The comments this runtime posts carry NO factory markers. Markers are the
# lane's attestation that an outcome actually happened, and the lane's resolve
# job posts them only after validating it against live state -- a marker next
# to model prose could be forged or fence-hidden (the #1364 reader trusts the
# last visible line, and an unterminated fence swallows everything after it),
# and a marker written before validation attests to a push the branch may not
# carry. Model text is neutralized below for the same reason: no line of it
# may parse as a marker.
REVISION_COMMENT_SECTIONS = ("What", "Validation", "Risks")

# `Summary` is what the section explaining the change was called before the
# opening paragraph took over the explaining. Bodies written under it are still
# open, and a turn that advances one must not drop its own reply on the floor.
WHAT_HEADINGS = ("What", "Summary")


def what_section(body: str) -> str:
    """The section that says what changed, under either name it has had."""
    for heading in WHAT_HEADINGS:
        if section := markdown_section(body, heading):
            return section
    return ""


def _neutralized_model_text(text: str) -> str:
    """Model prose, unable to impersonate factory machinery in a comment.

    HTML comment delimiters go so no line can form a marker; the reader is
    author- and position-bound, but the author here IS the bot, so the text
    itself must be unable to spell one. To a fixpoint, not a single pass:
    one deletion can splice a fresh delimiter together (`<<!--!--` becomes
    `<!--`).
    """
    while True:
        stripped = text.replace("<!--", "").replace("-->", "")
        if stripped == text:
            return text
        text = stripped


def fetch_review(pr_number: int, review_id: str, env: dict[str, str]) -> dict[str, object]:
    """The review a revision turn answers, or {} when it cannot be read.

    Best-effort: only the reference line degrades, and the marker the lane
    matches on carries the review id either way.
    """
    owner, name = repo_owner_name(env)
    raw = run_optional(
        ["gh", "api", f"repos/{owner}/{name}/pulls/{pr_number}/reviews/{review_id}"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    )
    try:
        review = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return review if isinstance(review, dict) else {}


def _review_reference(review: dict[str, object]) -> str:
    """The answered review as plain text, never as an `@` mention: mention
    triage watches comment bodies, and the reviewer gains nothing from a ping."""
    user = review.get("user")
    login = str(user.get("login") or "").strip() if isinstance(user, dict) else ""
    subject = (
        f"{login.removesuffix('[bot]')}'s requested changes"
        if login
        else "the requested changes"
    )
    url = str(review.get("html_url") or "").strip()
    return f"[{subject}]({url})" if url else subject


def compose_revision_comment(
    persona: str,
    body: str,
    *,
    review: dict[str, object],
) -> str:
    """April's reply on the PR after a revision turn: what she did, bound to
    the review that asked for it. Markerless -- the lane attests separately."""
    found = {
        heading: what_section(body) if heading == "What" else markdown_section(body, heading)
        for heading in REVISION_COMMENT_SECTIONS
    }
    sections = [
        f"## {heading}\n{_neutralized_model_text(content)}"
        for heading, content in found.items()
        if content
    ]
    return "\n".join(
        [
            f"*{persona}*",
            "",
            f"Answering {_review_reference(review)}.",
            "",
            "\n\n".join(sections) or "This revision turn recorded no summary.",
        ]
    ) + "\n"


def compose_revision_escalation_comment(
    persona: str,
    body: str,
    *,
    owner: str,
) -> str:
    """April's explanation when a revision turn moved nothing on purpose.

    Markerless: the lane's resolve step posts the deterministic escalation
    that carries the marker and the `owner-action` label; this comment is the
    reasoning next to it.
    """
    reason = _neutralized_model_text(
        what_section(body) or "No reason was recorded; see the workflow run."
    )
    return "\n".join(
        [
            f"*{persona}*",
            "",
            f"**This needs @{owner}** — this turn changed neither the code nor the PR body:",
            "",
            reason,
        ]
    ) + "\n"


REJECTED_HEADING_CHECKED_PREFIX = "Read from this PR's body at commit"


def rejected_heading_checked_line(head_sha: str) -> str:
    """The line that says which head this note was read from, and dedups it.

    A visible line and not a hidden marker. The markers this runtime writes are
    the lane's attestation that an outcome happened, validated against live
    state before they are written; a note about somebody's heading attests
    nothing, and giving it a marker would put a forgeable token next to model
    prose for no gain.

    It is forgeable, and the cost is not only a repeat suppressed: a copy
    posted BEFORE the first genuine note suppresses that one (codex,
    gpt-5.6-sol, xhigh). `_is_prior_rejected_heading_note` asks for the
    headline beside it and for this text to be a line of its own, so a forgery
    has to reproduce the note -- at which point the author has been told, which
    is the whole point of saying it.
    """
    return f"{REJECTED_HEADING_CHECKED_PREFIX} `{head_sha}`."


def compose_rejected_heading_comment(persona: str, note: str, head_sha: str) -> str:
    """The note on the PR when an author's own heading was not read as the section.

    The write went ahead, so this is not a stand-down: the body now carries a
    plain `## Evidence Status` below the author's. The author reads the pull
    request, not the workflow log, so the reason crosses here the way
    `compose_body_standdown_comment` does.

    What it says about the consequence is measured rather than reasoned. It
    used to say "every check that reads this section refuses it", which is not
    true of the checks this repo has: the owner read does refuse, naming the
    tagged heading, and the readiness gate's ambiguity check does not see it at
    all, because that check matches the heading line as raw text and a tag
    hides it there (`scripts/pr-readiness.py`). Saying "every check" made the
    note the same kind of claim as the refusal it exists to correct -- true
    sounding, wrongly attributed (#1730, round 2).

    Nothing here touches the note. Every value it quotes is already fenced by
    `code_span`, which takes the comment delimiters out BEFORE it measures the
    backtick runs -- and a strip applied afterwards, which is what this used to
    do, can join two runs into one long enough to close the fence and put a
    live `@mention` back in the comment (codex, gpt-5.6-sol, xhigh). A string
    that has been fenced is finished.
    """
    return "\n".join(
        [
            f"*{persona}*",
            "",
            REJECTED_HEADING_HEADLINE,
            "",
            f"- {note}",
            "",
            "This turn went ahead and the body was updated. While both headings stand, "
            "the read that collects your evidence refuses this body -- \"a reader sees 2 "
            "`Evidence Status` headings, not one\" -- and names yours as the one carrying "
            "the tag. The readiness gate does not refuse it for this: its ambiguity check "
            "reads the heading line as raw text, where a tag hides it.",
            "",
            rejected_heading_checked_line(head_sha),
        ]
    )


def post_rejected_heading_note(
    pr_number: int,
    persona: str,
    written_body: str,
    head_sha: str,
    env: dict[str, str],
) -> bool:
    """Tell the author about a declined heading, once per head, after the body is written.

    Composed from the body GitHub now holds, not from what the model wrote and
    not before the write: the note says a plain heading was written below
    theirs, and that sentence is only true of a body where it was. Asked before
    the write, it was said on turns whose write then refused and returned the
    body untouched (#1730, round 2).

    Once per head in the ordinary case, and best-effort about it. Re-running a
    turn at the same head re-posts nothing; a new commit that still carries the
    tagged heading says it again, which is right -- the author has pushed since
    and the heading is still there.

    Three ways it says the note twice, all of them deliberate rather than
    fixed, and all in the same direction (codex, gpt-5.6-sol, xhigh). The
    comment read returns a page, so a pull request past that length stops
    finding the older note. A read that fails returns nothing and the note goes
    again. And two turns racing at one head can both find no note and both
    post. The alternative to each is a note that is never said, and the reason
    this exists is that nothing was said at all.

    One way it is quieter than the head suggests: a PR body can be edited
    without a commit, so a second body-only turn at the same head does not
    repeat the note even if the author has since written a different tagged
    heading.

    A comment is the report of the work, never the work, so neither the read
    nor the post can fail this turn.
    """
    note = rejected_heading_note(written_body, "Evidence Status")
    if note is None:
        return False
    log(note)
    log(json.dumps({"error_class": "rejected_heading", "detail": note, "pr": pr_number}))
    checked = rejected_heading_checked_line(head_sha)
    if any(
        _is_prior_rejected_heading_note(body, checked)
        for body in _pr_comment_bodies(pr_number, env)
    ):
        return False
    return _post_pr_comment(
        pr_number, compose_rejected_heading_comment(persona, note, head_sha), env
    )


def compose_body_standdown_comment(persona: str, reasons: list[str]) -> str:
    """April's note on the PR when its body could not be rewritten.

    The reasons name a line in the body -- a fence or an HTML block that never
    closes -- and the person who has to close it is the person who edited the
    body, who reads the pull request and not the workflow log. Announced
    through `log()` alone the run said it on stderr, where the author never
    looks (#1733); this is the crossing `emit_refused_privileged_paths` makes
    for the same gap on the issue side.
    """
    listed = "\n".join(f"- {reason}" for reason in reasons)
    return "\n".join(
        [
            f"*{persona}*",
            "",
            "**This PR body was left as written.** The evidence section could not be "
            "rewritten, so nothing was changed rather than writing over text whose end "
            "the body does not state:",
            "",
            listed,
            "",
            "Closing the block named above lets the next run write the section.",
        ]
    ) + "\n"


def _post_pr_comment(pr_number: int, body: str, env: dict[str, str]) -> bool:
    """Post a comment, and say whether it landed. Never raise.

    The return value is the contract: a caller decides what a failed comment
    means. `run_optional` already turns a timeout and a non-zero exit into the
    default, but it does not catch an `OSError` -- `gh` missing from `PATH`
    raises `FileNotFoundError` out of `subprocess.run` -- so a comment nobody
    was waiting on could end a turn that had already pushed (#1730, round 2).
    A comment is never the work; it is the report of the work.
    """
    sentinel = "__COMMENT_FAILED__"
    try:
        posted = run_optional(
            ["gh", "pr", "comment", str(pr_number), "--body", body],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
            default=sentinel,
        )
    except OSError as error:
        log(f"could not comment on PR #{pr_number}: {error}")
        return False
    return posted != sentinel


REJECTED_HEADING_HEADLINE = "**Your `## Evidence Status` heading was not read as the section.**"


def _is_prior_rejected_heading_note(comment: str, checked: str) -> bool:
    """Whether this comment is this runtime's note about this head.

    Two conditions, because one was forgeable in the direction that matters. A
    substring match on the head line alone is satisfied by that text inside an
    HTML comment or a fence in somebody else's comment -- and a copy posted
    before the first genuine note suppresses it, which is worse than a repeat
    (codex, gpt-5.6-sol, xhigh). So the head line has to be a line of its own,
    and the note's headline has to be here too. A comment that carries both has
    said the thing this one would say.
    """
    return REJECTED_HEADING_HEADLINE in comment and any(
        line.strip() == checked for line in comment.splitlines()
    )


def _pr_comment_bodies(pr_number: int, env: dict[str, str]) -> list[str]:
    """The comments `gh` returns for this pull request, or [] when they cannot be read.

    Not every comment: `gh pr view --json comments` asks GraphQL for a page,
    and a pull request longer than that page hides its oldest comments from
    this read. Best-effort in the same direction as a failed read -- both end
    in the note being said again rather than never, which is the failure this
    is allowed to have.
    """
    try:
        raw = run_optional(
            ["gh", "pr", "view", str(pr_number), "--json", "comments"],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
            default="",
        )
    except OSError:
        return []
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return []
    comments = payload.get("comments") if isinstance(payload, dict) else None
    if not isinstance(comments, list):
        return []
    return [str(comment.get("body", "")) for comment in comments if isinstance(comment, dict)]


# Path-prefix → readiness surface label, first match wins. Feeds the
# `## Mergeability` block that scripts/pr-readiness.py requires on every
# non-draft PR; without a seeded block every factory PR fails the gate at open.
MERGEABILITY_SURFACE_RULES: tuple[tuple[str, str], ...] = (
    ("web/src/lib/agent-runtime/", "agent-runtime"),
    ("web/", "web"),
    ("web-next/", "web"),
    ("Sources/", "desktop"),
    ("Tests/", "desktop"),
    ("Package.swift", "desktop"),
    ("infra/", "infra"),
    (".github/", "infra"),
    (".agents/", "infra"),
    ("scripts/", "infra"),
    ("config/", "infra"),
    ("docs/", "docs"),
    ("backlog/", "docs"),
)
MERGEABILITY_DOC_SUFFIXES = (".md", ".mdx", ".markdown", ".txt")

# The body contract is `.github/pull_request_template.md`; scripts/pr-readiness.py
# grades against it. Seeding reads the field list out of that file rather than
# repeating it, so a field the owner adds to the template reaches every factory
# PR without a second edit here.
PR_TEMPLATE_PATH = REPO_ROOT / ".github" / "pull_request_template.md"
MERGEABILITY_FIELD_PATTERN = re.compile(r"(?m)^[ \t]*[-*][ \t]*(?P<label>[^:\n]+):")
# Used only when the template is unreadable: a runtime that can't open a PR is
# worse than one seeding a field list that has drifted.
FALLBACK_MERGEABILITY_LABELS: tuple[str, ...] = (
    "Surface",
    "User-facing behavior changed",
    "Non-happy paths considered",
    "Release/ops preconditions",
    "Residual risk or follow-up",
)


def mergeability_field_labels() -> tuple[str, ...]:
    """Mergeability field labels the PR template declares, in template order."""
    try:
        template = PR_TEMPLATE_PATH.read_text(encoding="utf-8")
    except OSError:
        return FALLBACK_MERGEABILITY_LABELS
    labels = tuple(
        match.group("label").strip()
        for match in MERGEABILITY_FIELD_PATTERN.finditer(
            markdown_section(template, "Mergeability")
        )
    )
    return labels or FALLBACK_MERGEABILITY_LABELS


def _mergeability_clip(text: str, max_len: int = 160) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) <= max_len:
        return text
    return text[: max_len - 3].rstrip() + "..."


def _first_content_line(section: str) -> str:
    for raw_line in section.splitlines():
        line = raw_line.strip().lstrip("-*").strip()
        if line:
            return line
    return ""


def _mergeability_surface(changed_files: list[str]) -> str:
    if not changed_files:
        return "not detected by the runtime; author must name the touched surface"
    labels: list[str] = []
    for path in changed_files:
        label = next(
            (surface for prefix, surface in MERGEABILITY_SURFACE_RULES if path.startswith(prefix)),
            None,
        )
        if label is None and path.endswith(MERGEABILITY_DOC_SUFFIXES):
            label = "docs"
        if label is not None and label not in labels:
            labels.append(label)
    preview = ", ".join(f"`{path}`" for path in changed_files[:3])
    if len(changed_files) > 3:
        preview += f" (+{len(changed_files) - 3} more)"
    if labels:
        return f"{' / '.join(labels)} — {preview}"
    return preview


def _changed_surface_files(env: dict[str, str]) -> list[str]:
    """Changed paths for Surface seeding: this run's dirty tree plus, on an
    existing PR branch, commits already ahead of the default branch."""
    files: list[str] = []

    def add(path: str) -> None:
        path = path.strip().strip('"')
        if path and path not in files:
            files.append(path)

    porcelain = run_optional(
        ["git", "status", "--porcelain"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    )
    for line in porcelain.splitlines():
        if len(line) <= 3:
            continue
        path = line[3:]
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        add(path)

    base = default_branch(env)
    for ref in (f"origin/{base}", base):
        committed = run_optional(
            ["git", "diff", "--name-only", f"{ref}...HEAD"],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
            default="",
        )
        if committed.strip():
            for line in committed.splitlines():
                add(line)
            break
    return files


def seed_mergeability_section(summary_body: str, *, changed_files: list[str]) -> str:
    """Seed the `## Mergeability` block scripts/pr-readiness.py requires when
    the agent omitted it.

    The field list comes from the PR template; the values come from what the
    runtime actually knows — changed paths for Surface, the agent's own
    What/Validation/Risks sections for the rest — with honest
    author-must-confirm placeholders where it knows nothing, so the gate's
    structural checks pass at PR-open time without inventing claims. An
    agent-authored Mergeability section is kept verbatim.
    """
    # Two questions, and seeding is skipped only when both say yes. The page
    # has to show the heading, or a `## Mergeability` line inside a fenced
    # example counts and the body goes out with no section at all (#1730); and
    # the gate has to be able to read it, or a heading the page shows but the
    # gate's literal start misses -- emphasis, an indent, a setext underline --
    # leaves the runtime believing it healed a body the gate then blocks.
    # Dropping either half reintroduces one of the two. The second is the
    # gate's narrowness, not this reader's, and it comes out when #1742 moves
    # the gate's start onto a parse.
    #
    # What the second question asks is narrower than "the gate can read this
    # section": it asks whether the gate can find the section's START. A
    # `## Mergeability` with another `##` directly below it has a start both
    # readers find and no content, so seeding is skipped and the gate reports
    # the section missing -- main's behaviour, unchanged here, and not closed
    # by this conjunct however the sentence above reads.
    if has_markdown_section(summary_body, "Mergeability") and gate_reads_markdown_section(
        summary_body, "Mergeability"
    ):
        return summary_body

    what_line = _mergeability_clip(_first_content_line(what_section(summary_body)))
    validation_line = _mergeability_clip(_first_content_line(markdown_section(summary_body, "Validation")))
    risks_line = _mergeability_clip(_first_content_line(markdown_section(summary_body, "Risks")))

    behavior = (
        f"Per the What section: {what_line}"
        if what_line
        else "Not stated by the author; confirm against the diff"
    )
    non_happy = (
        f"Per the validation notes: {validation_line}"
        if validation_line
        else "Not separately assessed; author should list error paths or explain why none apply"
    )
    residual = (
        f"Per the risks section: {risks_line}"
        if risks_line
        else "None noted by the author in this run"
    )
    seeded = {
        "Surface": _mergeability_surface(changed_files),
        "User-facing behavior changed": behavior,
        "Non-happy paths considered": non_happy,
        "Residual risk or follow-up": residual,
    }
    # A field the runtime can't speak to gets "n/a", which the gate reads as
    # unanswered: silent on an ordinary PR, and still demanding a real answer
    # where the field is required (Release/ops preconditions on release paths).
    content = "\n".join(
        f"- {label}: {seeded.get(label, 'n/a')}" for label in mergeability_field_labels()
    )
    return insert_markdown_section(summary_body, "Mergeability", content)


def build_body(data: dict[str, object]) -> str:
    persona = str(data.get("persona", ""))
    body = str(data.get("body", ""))
    if data["action"] == "propose":
        return f"*Proposed by {persona}*\n\n{body}"
    return f"*{persona}*\n\n{body}"


def build_execution_summary_body(
    data: dict[str, object],
    *,
    requested_evidence: list[str],
    visual_evidence_available: bool = True,
    published_body: str = "",
) -> tuple[str, list[str]]:
    """The PR body this turn will publish.

    `data["body"]` is what the model wrote this turn. `published_body` is what
    GitHub currently holds, which is the only copy a person can have edited --
    so it, and not the model's text, is what an owner-written evidence line is
    read from.
    """
    summary_body = str(data.get("body", "")).strip()
    if not requested_evidence:
        return summary_body, []
    evidence_complete, evidence_blocked, evidence_pending_ci = synthesize_initial_execution_evidence(
        requested_evidence,
        visual_evidence_available=visual_evidence_available,
        body=summary_body,
    )
    return render_execution_summary_body(
        summary_body,
        requested_evidence=requested_evidence,
        evidence_complete=evidence_complete,
        evidence_blocked=evidence_blocked,
        evidence_pending_ci=evidence_pending_ci,
        published_body=published_body,
    )


def set_git_identity(env: dict[str, str], persona: str, bot_login: str) -> None:
    user_name, user_email = app_bot_git_identity(env, persona, bot_login)
    run_checked(["git", "config", "user.name", user_name], timeout=GITHUB_API_TIMEOUT, cwd=REPO_ROOT, env=env)
    run_checked(["git", "config", "user.email", user_email], timeout=GITHUB_API_TIMEOUT, cwd=REPO_ROOT, env=env)


def working_tree_dirty(env: dict[str, str]) -> bool:
    status = run_optional(
        ["git", "status", "--porcelain"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    )
    return bool(status.strip())


def ensure_issue_claimed(
    issue_number: int,
    persona: str,
    branch: str,
    latest_claim: dict[str, str] | None,
    current_labels: set[str],
    env: dict[str, str],
    bot_login: str = "",
) -> None:
    already_claimed = (
        latest_claim is not None
        and latest_claim.get("agent") == persona_slug(persona)
        and latest_claim.get("branch") == branch
    )
    if not already_claimed:
        ensure_claim_label(env)
        cmd = [
            "gh",
            "issue",
            "edit",
            str(issue_number),
            "--add-label",
            AGENT_LANE_LABEL,
            "--add-label",
            AGENT_CLAIM_LABEL,
        ]
        if AGENT_READY_LABEL in current_labels:
            cmd.extend(["--remove-label", AGENT_READY_LABEL])
        run_checked(cmd, timeout=GITHUB_API_TIMEOUT, cwd=REPO_ROOT, env=env)
        run_checked(
            ["gh", "issue", "comment", str(issue_number), "--body", compose_claim_comment(issue_number, persona, branch)],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
    if bot_login:
        result = run_optional(
            ["gh", "issue", "edit", str(issue_number), "--add-assignee", bot_login],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
            default="",
        )
        if not result:
            log(f"Could not assign {bot_login} to #{issue_number} (bot accounts cannot be assignees); skipping")


def _update_mergeable_label(pr_number: int, verdict: str, env: dict[str, str]) -> None:
    if verdict not in ("approve", "approve_with_followups", "request_changes"):
        return
    pr_data = json.loads(
        run_checked(
            ["gh", "pr", "view", str(pr_number), "--json", "body,labels"],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        ).stdout
    )
    pr_body = str(pr_data.get("body") or "")
    pr_labels = {
        str(label.get("name") or "")
        for label in pr_data.get("labels", [])
        if isinstance(label, dict)
    }
    current_linked_issue, _ = extract_pr_issue_reference(pr_body)
    expected_linked_issue_text = env.get("FACTORY_EXPECTED_LINKED_ISSUE", "").strip()
    expected_linked_issue = int(expected_linked_issue_text) if expected_linked_issue_text else None
    linked_issue = expected_linked_issue
    if expected_linked_issue is not None and current_linked_issue != expected_linked_issue:
        print(
            f"error: PR #{pr_number} linked issue changed during Factory review",
            file=sys.stderr,
        )
        return

    if verdict == "request_changes":
        if AGENT_MERGEABLE_LABEL in pr_labels:
            run_checked(
                ["gh", "pr", "edit", str(pr_number), "--remove-label", AGENT_MERGEABLE_LABEL],
                timeout=GITHUB_API_TIMEOUT,
                cwd=REPO_ROOT,
                env=env,
            )
        if linked_issue is not None:
            issue_labels = json.loads(
                run_checked(
                    ["gh", "issue", "view", str(linked_issue), "--json", "labels"],
                    timeout=GITHUB_API_TIMEOUT,
                    cwd=REPO_ROOT,
                    env=env,
                ).stdout
            ).get("labels", [])
            if any(
                isinstance(label, dict) and label.get("name") == AGENT_MERGEABLE_LABEL
                for label in issue_labels
            ):
                run_checked(
                    ["gh", "issue", "edit", str(linked_issue), "--remove-label", AGENT_MERGEABLE_LABEL],
                    timeout=GITHUB_API_TIMEOUT,
                    cwd=REPO_ROOT,
                    env=env,
                )
        return

    ensure_label_exists(
        env,
        AGENT_MERGEABLE_LABEL,
        AGENT_MERGEABLE_LABEL_COLOR,
        AGENT_MERGEABLE_LABEL_DESCRIPTION,
    )
    if linked_issue is not None:
        run_checked(
            [
                "gh",
                "issue",
                "edit",
                str(linked_issue),
                "--add-label",
                AGENT_MERGEABLE_LABEL,
            ],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
    run_checked(
        ["gh", "pr", "edit", str(pr_number), "--add-label", AGENT_MERGEABLE_LABEL],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )


def _pr_body_and_head(pr_number: int, env: dict[str, str]) -> tuple[str, str]:
    pr = json.loads(
        run_checked(
            ["gh", "pr", "view", str(pr_number), "--json", "body,headRefOid"],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        ).stdout
    )
    return str(pr.get("body") or ""), str(pr.get("headRefOid") or "")


def _pr_evidence_entries(body: str) -> list[dict[str, object]]:
    """The entries the body's authoritative metadata block records.

    Two callers ask different things of this, so it answers the narrower one.
    The live CI gate reads it for the checks it re-verifies;
    `_complete_diff_evidence_after_approval` reads it to pick entries it then
    writes completions onto, through `update_evidence_entries`, which resolves
    an index against the last block. A read that ranged wider than that writer
    would select an entry from one block and update the same index in another.
    """
    metadata = _extract_evidence_metadata(body)
    entries = metadata.get("entries") if isinstance(metadata, dict) else None
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, dict)]


def _live_ci_evidence_gate_error(pr_number: int, env: dict[str, str]) -> str | None:
    """The PR body is untrusted at review time: before an approve counts,
    every named-check evidence entry is re-verified against the live
    check-run state on the current head, never the recorded conclusion."""
    body, head_sha = _pr_body_and_head(pr_number, env)
    expected = env.get("FACTORY_EXPECTED_PR_HEAD_SHA", "").strip()
    if expected and not hmac.compare_digest(head_sha, expected):
        return "PR head changed during Factory review"
    if not head_sha:
        return "PR head could not be resolved for live CI verification"
    requested = []
    issue_number, _ = extract_pr_issue_reference(body)
    if issue_number is not None:
        owner, name = repo_owner_name(env)
        issue = fetch_detailed_issue(owner, name, issue_number, env)
        if issue is None:
            return "linked issue evidence requirements are unavailable"
        requested, contract_refusal = requested_evidence_contract(str(issue.get("body", "")))
        if contract_refusal is not None:
            return f"linked issue evidence requirements cannot be read: {contract_refusal}"
    # Legacy CI entries remain binding even if the linked issue no longer names
    # them. Omission from the PR body never hides a requirement in the issue.
    items = list(dict.fromkeys(requested + [str(entry.get("item", "")).strip()
                                          for entry in _pr_evidence_entries(body)]))
    for fact in resolve_named_ci_evidence(items, head_sha, env):
        if fact["status"] != "satisfied":
            return (f"named check `{fact['check_name']}` is not green on head {head_sha[:12]} "
                    f"(live state: {fact['status']}; live conclusion: {fact['conclusion'] or 'none'})")

    return None


def _latest_approving_review(
    pr_number: int,
    head_sha: str,
    env: dict[str, str],
) -> dict[str, object] | None:
    """Most recent APPROVED review bound to exactly this head, or None."""
    owner, name = repo_owner_name(env)
    raw = run_optional(
        ["gh", "api", f"repos/{owner}/{name}/pulls/{pr_number}/reviews"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    )
    try:
        reviews = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(reviews, list):
        return None
    approved = [
        review
        for review in reviews
        if isinstance(review, dict)
        and review.get("state") == "APPROVED"
        and str(review.get("commit_id", "")) == head_sha
    ]
    if not approved:
        return None
    return max(approved, key=lambda review: str(review.get("submitted_at", "")))


def _edit_pr_body(pr_number: int, body: str, env: dict[str, str]) -> None:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".md", delete=False) as handle:
        handle.write(body)
        body_file = handle.name
    try:
        run_checked(
            ["gh", "pr", "edit", str(pr_number), "--body-file", body_file],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
    finally:
        try:
            os.unlink(body_file)
        except OSError:
            pass


def _complete_diff_evidence_after_approval(pr_number: int, env: dict[str, str]) -> None:
    """The approving review is the verification act for diff-kind evidence:
    bind the completion to the review URL and the exact reviewed head.

    Best-effort by design — if anything here fails, the entries stay
    pending-ci and the readiness gate stays red (fail-closed)."""
    body, head_sha = _pr_body_and_head(pr_number, env)
    if not head_sha:
        return
    pending_diff = [
        entry
        for entry in _pr_evidence_entries(body)
        if _evidence_item_kind(str(entry.get("item", "")).strip()) == "diff"
        and str(entry.get("status", "")).strip() == "pending-ci"
    ]
    if not pending_diff:
        return
    review = _latest_approving_review(pr_number, head_sha, env)
    if review is None:
        log(
            f"PR #{pr_number}: no approving review bound to head {head_sha[:12]}; "
            "leaving diff evidence pending"
        )
        return
    review_url = str(review.get("html_url", "") or "").strip()
    link = f" — {review_url}" if review_url else ""
    updates: dict[int, dict[str, object]] = {}
    for entry in pending_diff:
        try:
            index = int(entry["index"])
        # OverflowError too: `1e9999` in the PR-editable metadata parses as
        # infinity, and `int()` of that raises a class the others do not cover.
        except (KeyError, TypeError, ValueError, OverflowError):
            continue
        updates[index] = {
            "status": "complete",
            "detail": f"diff-verified by the counterpart approving review on head {head_sha[:12]}{link}",
            "kind": "diff",
            "verified_head_sha": head_sha,
            "proof_url": review_url,
        }
    if not updates:
        return
    new_body = update_evidence_entries(body, updates)
    if new_body == body:
        return
    if not _factory_expected_pr_head_is_current(pr_number, env):
        return
    _edit_pr_body(pr_number, new_body, env)
    log(f"PR #{pr_number}: completed {len(updates)} diff evidence entries from the approving review")


def _factory_expected_pr_head_is_current(pr_number: int, env: dict[str, str]) -> bool:
    expected = env.get("FACTORY_EXPECTED_PR_HEAD_SHA", "").strip()
    if not expected:
        return True
    current = run_checked(
        ["gh", "pr", "view", str(pr_number), "--json", "headRefOid", "--jq", ".headRefOid"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    ).stdout.strip()
    if hmac.compare_digest(current, expected):
        return True
    print(
        f"error: PR #{pr_number} head changed during Factory review",
        file=sys.stderr,
    )
    return False


def _write_github_outputs(
    needs_evidence: bool,
    needs_screenshot_evidence: bool,
    branch: str,
    test_commands: list[str],
    pr_number: int,
    pr_head_sha: str,
    *,
    revision_outcome: str = "",
    revision_comment_posted: bool = False,
) -> None:
    output_file = os.environ.get("GITHUB_OUTPUT", "")
    if not output_file:
        log("GITHUB_OUTPUT not set; skipping output emission")
        return
    with open(output_file, "a") as f:
        f.write(f"needs_macos_evidence={str(needs_evidence).lower()}\n")
        f.write(f"needs_screenshot_evidence={str(needs_screenshot_evidence).lower()}\n")
        f.write(f"pr_branch={branch}\n")
        f.write(f"pr_number={pr_number}\n")
        f.write(f"pr_head_sha={pr_head_sha}\n")
        f.write(f"test_commands_json={json.dumps(test_commands, separators=(',', ':'))}\n")
        # Only a revision turn has an outcome; the implement and review lanes
        # must see the output set they see today.
        if revision_outcome:
            f.write(f"revision_outcome={revision_outcome}\n")
            f.write(f"revision_comment_posted={str(revision_comment_posted).lower()}\n")
    log(
        "Emitted outputs: "
        f"needs_macos_evidence={needs_evidence}, "
        f"needs_screenshot_evidence={needs_screenshot_evidence}, "
        f"pr_branch={branch}, "
        f"pr_number={pr_number}, "
        f"pr_head_sha={pr_head_sha}, "
        f"test_commands={test_commands}"
        + (
            f", revision_outcome={revision_outcome}, "
            f"revision_comment_posted={str(revision_comment_posted).lower()}"
            if revision_outcome
            else ""
        )
    )


def _factory_evidence_should_block(
    *,
    factory_requires_evidence: bool,
    needs_macos_evidence: bool,
    visual_evidence_blocked: bool,
    has_unautomatable_evidence: bool | None = None,
) -> bool:
    """blocked:evidence at open means no automation can ever complete the
    contract: `other`-kind items, or a required visual lane that is offline.
    `ci`/`diff`/macOS kinds ride on Evidence Status pending-ci redness and
    complete through their own lanes (#1120).

    has_unautomatable_evidence=None preserves the pre-#1120 rule (any
    contract with no macOS-verifiable items blocks) for older callers.
    """
    if has_unautomatable_evidence is None:
        has_unautomatable_evidence = not needs_macos_evidence
    return visual_evidence_blocked or (
        factory_requires_evidence and has_unautomatable_evidence
    )


def _mark_factory_evidence_blocked(
    pull_request: str,
    *,
    env: dict[str, str],
) -> None:
    ensure_label_exists(
        env,
        EVIDENCE_BLOCK_LABEL,
        EVIDENCE_BLOCK_LABEL_COLOR,
        EVIDENCE_BLOCK_LABEL_DESCRIPTION,
    )
    run_checked(
        ["gh", "pr", "edit", pull_request, "--add-label", EVIDENCE_BLOCK_LABEL],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )


def _post_revision_reply(
    pr_number: int,
    persona: str,
    body: str,
    review_id: str,
    env: dict[str, str],
) -> bool:
    posted = _post_pr_comment(
        pr_number,
        compose_revision_comment(
            persona,
            body,
            review=fetch_review(pr_number, review_id, env),
        ),
        env,
    )
    if not posted:
        log(
            f"warning: PR #{pr_number} revision reply for review {review_id} was not "
            "posted; the lane's attestation comment still records the turn"
        )
    return posted


def _finish_revision_without_diff(
    data: dict[str, object],
    env: dict[str, str],
    *,
    persona: str,
    pr_number: int,
    pr_body: str,
    review_id: str,
    branch: str,
    requested_evidence: list[str],
    evidence_needed: bool,
    factory_evidence_blocked: bool,
) -> int:
    """Close out a revision turn that produced no file changes.

    A PR body the model actually rewrote still answers the review, so it lands
    and the lane sends the PR back for review. A body identical to the live one
    means the turn moved nothing at all, which is the runtime's signal that the
    review needs the owner. Labels stay untouched here: the lane's resolve step
    owns owner-action.
    """
    live_body, live_head = _pr_body_and_head(pr_number, env)
    model_body = str(data.get("body", ""))
    if live_body.strip() != pr_body.strip():
        outcome = "body-only"
        if factory_evidence_blocked:
            _mark_factory_evidence_blocked(str(pr_number), env=env)
        run_checked(
            [
                "gh",
                "pr",
                "edit",
                str(pr_number),
                "--title",
                str(data["pr_title"]).strip(),
                "--body",
                pr_body,
            ],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
        # This path publishes a body too, without committing one, so it owes
        # the same report as the paths that push. The head is the live one --
        # nothing was pushed -- and that is the commit this body is attached
        # to, so it is the right thing to say the note was read from.
        post_rejected_heading_note(pr_number, persona, pr_body, live_head, env)
        posted = _post_revision_reply(pr_number, persona, model_body, review_id, env)
    else:
        outcome = "needs-owner"
        owner, _ = repo_owner_name(env)
        posted = _post_pr_comment(
            pr_number,
            compose_revision_escalation_comment(persona, model_body, owner=owner),
            env,
        )
        if not posted:
            # Her reasoning is enrichment now, not the escalation itself: the
            # lane's resolve step posts the deterministic escalation and the
            # `owner-action` label for every needs-owner outcome, so a lost
            # comment degrades the explanation, never the state machine.
            log(
                f"warning: April's needs-owner reasoning for review {review_id} on "
                f"PR #{pr_number} was not posted; resolve escalates without it"
            )
    _write_github_outputs(
        evidence_needed,
        _needs_screenshot_evidence(requested_evidence),
        branch,
        _extract_test_commands(requested_evidence),
        pr_number,
        live_head,
        revision_outcome=outcome,
        revision_comment_posted=posted,
    )
    return 0


def route_execution_action(
    data: dict[str, object],
    env: dict[str, str],
    *,
    require_existing_pr: bool,
) -> int:
    persona = str(data.get("persona", ""))
    bot_login = detect_bot_login(env)
    issue_number = int(data["issue_number"])
    state = find_issue_execution_state(
        issue_number,
        env,
        persona=persona,
        bot_login=bot_login,
    )
    if state is None:
        print(f"error: issue #{issue_number} is not available for execution", file=sys.stderr)
        log(json.dumps({"error_class": "execution_state", "detail": "issue not available for execution", "issue": issue_number}))
        return 1

    own_pr = state.get("own_pr")
    other_pr = state.get("other_pr")
    if require_existing_pr:
        if own_pr is None:
            print(
                f"error: issue #{issue_number} has no open PR owned by {persona_slug(persona)} to advance",
                file=sys.stderr,
            )
            log(json.dumps({"error_class": "execution_state", "detail": "no open PR to advance", "issue": issue_number}))
            return 1
        if int(data["pr_number"]) != int(own_pr["number"]):
            print(
                f"error: issue #{issue_number} is linked to PR #{own_pr['number']}, not PR #{data['pr_number']}",
                file=sys.stderr,
            )
            log(json.dumps({"error_class": "execution_conflict", "detail": f"PR mismatch: expected #{own_pr['number']}, got #{data['pr_number']}", "issue": issue_number}))
            return 1

    if own_pr is None and not bool(state.get("approved")):
        print(
            f"error: issue #{issue_number} is not execution-approved ({state.get('approval_reason')})",
            file=sys.stderr,
        )
        log(json.dumps({"error_class": "execution_state", "detail": f"not execution-approved: {state.get('approval_reason')}", "issue": issue_number}))
        return 1
    if own_pr is None and state.get("blockers"):
        print(
            f"error: issue #{issue_number} is still blocked by {state['blockers']}",
            file=sys.stderr,
        )
        log(json.dumps({"error_class": "execution_blocked", "detail": f"blocked by {state['blockers']}", "issue": issue_number}))
        return 1
    contract_refusals = list(state.get("contract_refusals", []))
    if contract_refusals:
        # Before the contract is read as a list of obligations, not after: the
        # items that survive a cut section are a smaller promise than the
        # issue made, and executing against them ships a PR whose gate asks
        # for less than the author wrote (#1734, round 2).
        detail = "; ".join(contract_refusals)
        print(
            f"error: issue #{issue_number} has a contract section that cannot be read: {detail}",
            file=sys.stderr,
        )
        log(json.dumps({"error_class": "evidence_validation", "detail": detail, "issue": issue_number}))
        return 1

    requested_evidence = list(state.get("requested_evidence", []))
    factory_requires_evidence = (
        env.get("FACTORY_REQUIRE_EXPLICIT_EVIDENCE", "false").casefold() == "true"
    )
    if factory_requires_evidence and not requested_evidence:
        print(
            "error: Factory execution requires an explicit Requested Evidence contract",
            file=sys.stderr,
        )
        log(
            json.dumps(
                {
                    "error_class": "evidence_validation",
                    "detail": "missing explicit Requested Evidence contract",
                    "issue": issue_number,
                }
            )
        )
        return 1
    test_command_errors = validate_requested_test_commands(requested_evidence, env)
    if test_command_errors:
        print(
            "error: requested test evidence is invalid: " + "; ".join(test_command_errors),
            file=sys.stderr,
        )
        log(json.dumps({"error_class": "evidence_validation", "detail": "; ".join(test_command_errors), "issue": issue_number}))
        return 1
    evidence_needed = _needs_macos_evidence(requested_evidence)
    if other_pr is not None:
        print(
            f"error: issue #{issue_number} already has open PR #{other_pr['number']} by another agent",
            file=sys.stderr,
        )
        log(json.dumps({"error_class": "execution_conflict", "detail": f"open PR #{other_pr['number']} by another agent", "issue": issue_number}))
        return 1

    latest_claim = state.get("latest_claim")
    if (
        own_pr is None
        and latest_claim is not None
        and latest_claim.get("agent")
        and latest_claim.get("agent") != persona_slug(persona)
    ):
        print(
            f"error: issue #{issue_number} is already claimed by {latest_claim['agent']}",
            file=sys.stderr,
        )
        log(json.dumps({"error_class": "execution_conflict", "detail": f"claimed by {latest_claim['agent']}", "issue": issue_number}))
        return 1

    summary_body, summary_errors = build_execution_summary_body(
        data,
        requested_evidence=requested_evidence,
        visual_evidence_available=(
            env.get("FACTORY_VISUAL_EVIDENCE_AVAILABLE", "true").casefold() != "false"
        ),
        published_body=str((own_pr or {}).get("body", "")),
    )
    if summary_errors:
        print(
            "error: PR body evidence accounting is incomplete: "
            + "; ".join(summary_errors),
            file=sys.stderr,
        )
        log(json.dumps({"error_class": "evidence_validation", "detail": "; ".join(summary_errors), "issue": issue_number}))
        # On the pull request as well as in the log, where the author who
        # edited the body can see which line to close. Only the errors about
        # the write itself: the rest are the runtime's own accounting, and a
        # person cannot act on those.
        standdown = [error for error in summary_errors if "was not rewritten" in error]
        if standdown and own_pr is not None:
            _post_pr_comment(
                int(own_pr["number"]), compose_body_standdown_comment(persona, standdown), env
            )
        return 1

    _, evidence_errors = validate_evidence_accounting(summary_body, requested_evidence)
    if evidence_errors:
        print(
            "error: PR body evidence accounting is incomplete: "
            + "; ".join(evidence_errors),
            file=sys.stderr,
        )
        log(json.dumps({"error_class": "evidence_validation", "detail": "; ".join(evidence_errors), "issue": issue_number}))
        return 1
    summary_body = seed_mergeability_section(
        summary_body,
        changed_files=_changed_surface_files(env),
    )
    pr_body = compose_pr_body(issue_number, persona, summary_body)
    author_label = author_label_for_persona(persona)
    ensure_label_exists(
        env,
        author_label,
        AUTHOR_LABEL_COLOR,
        AUTHOR_LABEL_DESCRIPTION.format(agent=author_label.removeprefix("author:")),
    )
    if factory_requires_evidence:
        ensure_label_exists(
            env,
            EVIDENCE_BLOCK_LABEL,
            EVIDENCE_BLOCK_LABEL_COLOR,
            EVIDENCE_BLOCK_LABEL_DESCRIPTION,
        )
    factory_visual_blocked = (
        env.get("FACTORY_VISUAL_EVIDENCE_AVAILABLE", "true").casefold() == "false"
        and _needs_screenshot_evidence(requested_evidence)
    )
    factory_evidence_blocked = _factory_evidence_should_block(
        factory_requires_evidence=factory_requires_evidence,
        needs_macos_evidence=evidence_needed,
        visual_evidence_blocked=factory_visual_blocked,
        has_unautomatable_evidence=_has_unautomatable_evidence(requested_evidence),
    )
    if factory_visual_blocked and not factory_requires_evidence:
        ensure_label_exists(
            env,
            EVIDENCE_BLOCK_LABEL,
            EVIDENCE_BLOCK_LABEL_COLOR,
            EVIDENCE_BLOCK_LABEL_DESCRIPTION,
        )

    branch = current_branch(env)
    if own_pr is not None:
        expected_branch = str(own_pr.get("headRefName", ""))
        if branch != expected_branch:
            print(
                f"error: issue #{issue_number} already has PR #{own_pr['number']} on "
                f"branch '{expected_branch}'. Check out that branch before editing.",
                file=sys.stderr,
            )
            log(json.dumps({"error_class": "execution_state", "detail": f"branch mismatch: expected '{expected_branch}'", "issue": issue_number}))
            return 1
    else:
        default = default_branch(env)
        if branch in {"HEAD", "", default, "main", "master"}:
            branch = branch_name_for_issue(
                persona,
                issue_number,
                str(state["issue"].get("title", f"issue-{issue_number}")),
            )
            run_checked(
                ["git", "checkout", "-b", branch],
                timeout=GITHUB_API_TIMEOUT,
                cwd=REPO_ROOT,
                env=env,
            )
    # A revision turn answers one blocking review: it must never push onto a
    # head that moved under it, and an empty diff is an outcome there rather
    # than the failure it is on every other execution path.
    revision_review_id = (
        env.get("FACTORY_REVISION_REVIEW_ID", "").strip() if require_existing_pr else ""
    )
    if revision_review_id and own_pr is not None:
        revision_pr_number = int(own_pr["number"])
        if not _factory_expected_pr_head_is_current(revision_pr_number, env):
            print(
                f"error: PR #{revision_pr_number} head moved during the revision turn; "
                "nothing was committed",
                file=sys.stderr,
            )
            log(
                json.dumps(
                    {
                        "error_class": "revision_conflict",
                        "detail": "PR head moved during the revision turn",
                        "pr": revision_pr_number,
                    }
                )
            )
            return 1
        if not working_tree_dirty(env):
            return _finish_revision_without_diff(
                data,
                env,
                persona=persona,
                pr_number=revision_pr_number,
                pr_body=pr_body,
                review_id=revision_review_id,
                branch=branch,
                requested_evidence=requested_evidence,
                evidence_needed=evidence_needed,
                factory_evidence_blocked=factory_evidence_blocked,
            )

    if not working_tree_dirty(env):
        print(
            f"error: {data['action']} selected for #{issue_number} but no file changes were made",
            file=sys.stderr,
        )
        log(json.dumps({"error_class": "execution_state", "detail": "no file changes", "issue": issue_number}))
        return 1

    if own_pr is None:
        ensure_issue_claimed(
            issue_number,
            persona,
            branch,
            latest_claim if isinstance(latest_claim, dict) else None,
            issue_label_presence(state["issue"]),
            env,
            bot_login=bot_login or "",
        )

    set_git_identity(env, persona, bot_login)
    run_checked(["git", "add", "-A"], timeout=GITHUB_API_TIMEOUT, cwd=REPO_ROOT, env=env)
    run_checked(
        ["git", "commit", "-m", str(data["commit_message"]).strip()],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )
    run_checked(
        ["gh", "auth", "setup-git"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )
    run_checked(
        ["git", "push", "--set-upstream", "origin", branch],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )

    screenshot_evidence_needed = _needs_screenshot_evidence(requested_evidence)
    test_commands = _extract_test_commands(requested_evidence)
    pr_head_sha = run_checked(
        ["git", "rev-parse", "HEAD"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    ).stdout.strip()

    if own_pr is not None:
        pr_number = int(own_pr["number"])
        if factory_evidence_blocked:
            _mark_factory_evidence_blocked(
                str(pr_number),
                env=env,
            )
        run_checked(
            [
                "gh",
                "pr",
                "edit",
                str(pr_number),
                "--title",
                str(data["pr_title"]).strip(),
                "--body",
                pr_body,
            ],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
        # After the body write, and only now: the note says a plain heading was
        # written below the author's, which is a claim about the body GitHub
        # holds. It is also after `validate_evidence_accounting`, which returns
        # above on failure -- a turn that ends without publishing has nothing
        # to tell the author about their heading (#1730, round 2).
        post_rejected_heading_note(pr_number, persona, pr_body, pr_head_sha, env)
        revision_comment_posted = bool(revision_review_id) and _post_revision_reply(
            pr_number, persona, str(data.get("body", "")), revision_review_id, env
        )
        _write_github_outputs(
            evidence_needed,
            screenshot_evidence_needed,
            branch,
            test_commands,
            pr_number,
            pr_head_sha,
            revision_outcome="pushed" if revision_review_id else "",
            revision_comment_posted=revision_comment_posted,
        )
        return 0

    create_args = [
        "gh",
        "pr",
        "create",
        "--base",
        default_branch(env),
        "--head",
        branch,
        "--title",
        str(data["pr_title"]).strip(),
        "--body",
        pr_body,
        "--label",
        author_label,
    ]
    if factory_evidence_blocked:
        create_args.extend(["--label", EVIDENCE_BLOCK_LABEL])
    created = run_checked(
        create_args,
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )
    number_match = re.search(r"/pull/(?P<number>\d+)", created.stdout)
    if number_match is None:
        print("error: could not parse created PR number", file=sys.stderr)
        return 1
    pr_number = int(number_match.group("number"))
    # Same crossing on the path that opens the PR rather than editing one: the
    # body is on GitHub now, so the note can say what is in it.
    post_rejected_heading_note(pr_number, persona, pr_body, pr_head_sha, env)
    _write_github_outputs(
        evidence_needed,
        screenshot_evidence_needed,
        branch,
        test_commands,
        pr_number,
        pr_head_sha,
    )
    return 0


def _preserve_unparseable_output(raw_output: str, env: dict[str, str]) -> None:
    """Persist the exact text that failed output validation as a run artifact.

    #1179: a review whose analysis fully completed died at this stage and
    was never posted, then its GitHub Actions log expired before anyone
    could inspect it. When FACTORY_TELEMETRY_DIR is set, the run already
    uploads that directory as a workflow artifact (see
    factory-review-execute.yml's "Upload {April,Plat} review telemetry"
    step), so writing here needs no new plumbing -- it only adds one more
    file to what's already collected. Best-effort: a write failure here must
    never fail the contributor run, same as telemetry.record_run_telemetry.
    """
    telemetry_dir = (env.get("FACTORY_TELEMETRY_DIR") or "").strip()
    if not telemetry_dir:
        return
    try:
        failures_dir = Path(telemetry_dir) / "parse-failures"
        failures_dir.mkdir(parents=True, exist_ok=True)
        seq = sum(1 for _ in failures_dir.glob("*.txt")) + 1
        redacted = redact_secrets(raw_output, env)
        (failures_dir / f"{seq:04d}-unparsed-output.txt").write_text(redacted, encoding="utf-8")
    except Exception as exc:  # artifact preservation is best-effort
        log(f"artifact preservation: skipped ({exc})")


def validate_output(raw_output: str, env: dict[str, str]) -> tuple[int, str | None, str]:
    log("Validating agent output")
    try:
        result = subprocess.run(
            ["uv", "run", str(VALIDATOR_SCRIPT), "--check-dedup"],
            input=raw_output,
            capture_output=True,
            text=True,
            env=env,
            cwd=REPO_ROOT,
            timeout=VALIDATION_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        print("error: validation timed out", file=sys.stderr)
        _preserve_unparseable_output(raw_output, env)
        return 1, None, "validation timed out"
    if result.returncode == 0:
        return 0, result.stdout, result.stderr
    error_text = result.stderr.strip()
    if error_text:
        print(error_text, file=sys.stderr)
    if not (result.returncode == 2 and error_text.startswith("duplicate:")):
        _preserve_unparseable_output(raw_output, env)
    return result.returncode, None, error_text


def route_action(validated_json: str, dry_run: bool, env: dict[str, str], *, images_inspected: bool = False) -> int:
    data = json.loads(validated_json)
    action = data["action"]

    if dry_run:
        log(f"Dry run; action={action}")
        print(json.dumps(data, indent=2, ensure_ascii=False))
        return 0

    log(f"Routing action {action}")
    body = build_body(data) if action not in {"execute_issue", "advance_pr"} else ""

    if action == "propose":
        run_checked(
            [
                "uv",
                "run",
                str(GH_DISCUSS_SCRIPT),
                "create",
                str(data["title"]),
                "--body",
                body,
                "--category",
                "General",
            ],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
        return 0

    if action == "comment":
        run_checked(
            [
                "uv",
                "run",
                str(GH_DISCUSS_SCRIPT),
                "update",
                str(data["discussion_number"]),
                body,
            ],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
        return 0

    if action == "recommend_close":
        run_checked(
            [
                "uv",
                "run",
                str(GH_DISCUSS_SCRIPT),
                "update",
                str(data["discussion_number"]),
                body,
            ],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
        run_checked(
            [
                "uv",
                "run",
                str(GH_DISCUSS_SCRIPT),
                "complete",
                str(data["discussion_number"]),
            ],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
        return 0

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(body)
        body_file = handle.name

    # Look up through the entrypoint module to allow mock.patch.object patching.
    _mod = sys.modules.get("run_contributor", sys.modules[__name__])

    try:
        if action == "review_pr":
            verdict = str(data.get("verdict", "")).lower()
            pr_number = int(data["pr_number"])
            if not _factory_expected_pr_head_is_current(pr_number, env):
                return 1
            review_state = _mod.find_pr_review_state(pr_number, env)
            if review_state is not None:
                evidence_gate_error = review_evidence_gate_error(
                    verdict,
                    review_state["evidence_accounting"],
                    review_state["evidence_errors"],
                    images_inspected=images_inspected,
                )
                if evidence_gate_error is not None:
                    print(
                        f"error: PR #{pr_number} cannot be reviewed with verdict '{verdict}': {evidence_gate_error}",
                        file=sys.stderr,
                    )
                    categories = [c["category"] for c in classify_evidence_errors(review_state["evidence_errors"])]
                    log(json.dumps({"error_class": "evidence_gate", "categories": categories, "pr": pr_number, "verdict": verdict}))
                    return 1
            if verdict in ("approve", "approve_with_followups"):
                live_gate_error = _mod._live_ci_evidence_gate_error(pr_number, env)
                if live_gate_error is not None:
                    print(
                        f"error: PR #{pr_number} cannot be approved: {live_gate_error}",
                        file=sys.stderr,
                    )
                    log(json.dumps({"error_class": "evidence_gate", "categories": ["ci_live_verification"], "pr": pr_number, "verdict": verdict}))
                    return 1
            review_flag = {
                "approve": "--approve",
                "approve_with_followups": "--approve",
                "request_changes": "--request-changes",
            }.get(verdict, "--comment")
            review_cmd = [
                "gh",
                "pr",
                "review",
                str(data["pr_number"]),
                review_flag,
                "--body-file",
                body_file,
            ]
            expected_head = env.get("FACTORY_EXPECTED_PR_HEAD_SHA", "").strip()
            if expected_head:
                owner, name = repo_owner_name(env)
                review_event = {
                    "approve": "APPROVE",
                    "approve_with_followups": "APPROVE",
                    "request_changes": "REQUEST_CHANGES",
                }.get(verdict, "COMMENT")
                _mod.run_checked(
                    [
                        "gh",
                        "api",
                        f"repos/{owner}/{name}/pulls/{pr_number}/reviews",
                        "--method",
                        "POST",
                        "--field",
                        f"body=@{body_file}",
                        "--field",
                        f"commit_id={expected_head}",
                        "--field",
                        f"event={review_event}",
                    ],
                    timeout=GITHUB_API_TIMEOUT,
                    cwd=REPO_ROOT,
                    env=env,
                )
            else:
                _mod.run_checked(
                    review_cmd,
                    timeout=GITHUB_API_TIMEOUT,
                    cwd=REPO_ROOT,
                    env=env,
                )
            if review_flag == "--approve":
                bot = detect_bot_login(env)
                if bot:
                    _dismiss_own_blocking_reviews(pr_number, bot, env)
            if not _factory_expected_pr_head_is_current(pr_number, env):
                return 1
            if review_flag == "--approve":
                _mod._complete_diff_evidence_after_approval(pr_number, env)
            _mod._update_mergeable_label(int(data["pr_number"]), verdict, env)
            return 0
        if action == "execute_issue":
            return route_execution_action(data, env, require_existing_pr=False)
        if action == "advance_pr":
            return route_execution_action(data, env, require_existing_pr=True)
    finally:
        try:
            os.unlink(body_file)
        except OSError:
            pass

    print(f"error: unknown action: {action}", file=sys.stderr)
    log(json.dumps({"error_class": "execution_state", "detail": f"unknown action: {action}"}))
    return 1
