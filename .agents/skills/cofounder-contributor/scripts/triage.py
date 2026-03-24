"""Priority classification, context building, and work selection."""

from __future__ import annotations

import json
import platform
import re
from datetime import datetime, timedelta, timezone

from _helpers import (
    AGENT_CLAIM_LABEL,
    AGENT_READY_LABEL,
    GITHUB_API_TIMEOUT,
    REPO_ROOT,
    _normalize_login,
    _parse_timestamp,
    issue_label_names,
    log,
    persona_slug,
    run_checked,
    run_optional,
)
from evidence import (
    _explicit_evidence_contract,
    evaluate_evidence_accounting,
    extract_requested_evidence,
    format_requested_evidence_numbered,
    summarize_evidence_accounting_by_index,
    summarize_requested_evidence,
)
from github_state import (
    HISTORY_QUERY,
    claim_is_stale,
    extract_blocked_by,
    extract_execution_priority,
    extract_issue_discussion_number,
    extract_pr_issue_reference,
    fetch_issue_state_map,
    fetch_pr_diff,
    fetch_work_state,
    latest_issue_claim,
    repo_owner_name,
    trusted_automation_logins,
    trusted_comment_author,
)

ENGAGEMENT_RECENT_HOURS = 72
LOW_COMMENT_THRESHOLD = 1
PR_DIFF_MAX_LINES = 2000
DISCUSSION_WIP_CAP = 12
ISSUE_WIP_CAP = 30
STALE_DISCUSSION_DAYS = 14
UNTRUSTED_BODY_NOTE = "[body omitted from untrusted public author]"

_DIRECTED_PR_RE = re.compile(
    r"(?:re-?review|review|CR|cr|code[\s-]?review)\s*#?\s*(\d+)",
    re.IGNORECASE,
)


def parse_directed_pr_number(message: str) -> int | None:
    """Extract a PR number from a directed task message.

    Supports: 'Review PR #198', 'CR 123', 'cr #123', 'cr # 123',
    'code review 198', 're-review PR #198', etc.
    """
    match = _DIRECTED_PR_RE.search(message)
    if match:
        return int(match.group(1))
    # Fallback: 'PR #N' or 'PR N' anywhere
    fallback = re.search(r"PR\s*#?\s*(\d+)", message, re.IGNORECASE)
    return int(fallback.group(1)) if fallback else None


def _has_persona(text: str, markers: list[str]) -> bool:
    return any(m in text for m in markers)


def _find_agent_threads(
    data: dict,
    markers: list[str],
    *,
    trusted_logins: set[str] | None = None,
) -> list[dict]:
    """Find threads where the agent acted, returning the last action + replies."""
    threads: list[dict] = []
    repo = data.get("data", {}).get("repository", {})

    for pr in repo.get("pullRequests", {}).get("nodes", []):
        items: list[dict] = []
        for r in pr.get("reviews", {}).get("nodes", []):
            items.append({
                "body": r.get("body", ""),
                "author": (r.get("author") or {}).get("login", ""),
                "authorAssociation": r.get("authorAssociation", ""),
                "time": r.get("submittedAt", ""),
            })
        for c in pr.get("comments", {}).get("nodes", []):
            items.append({
                "body": c.get("body", ""),
                "author": (c.get("author") or {}).get("login", ""),
                "authorAssociation": c.get("authorAssociation", ""),
                "time": c.get("createdAt", ""),
            })
        items.sort(key=lambda x: x["time"])
        agent_indices = [
            i
            for i, x in enumerate(items)
            if _has_persona(x["body"], markers)
            and trusted_comment_author(x, trusted_logins=trusted_logins)
        ]
        if not agent_indices:
            continue
        last = agent_indices[-1]
        threads.append({
            "kind": "PR",
            "number": pr["number"],
            "title": pr["title"],
            "agent_item": items[last],
            "replies": items[last + 1:],
        })

    for issue in repo.get("issues", {}).get("nodes", []):
        items = [
            {
                "body": c.get("body", ""),
                "author": (c.get("author") or {}).get("login", ""),
                "authorAssociation": c.get("authorAssociation", ""),
                "time": c.get("createdAt", ""),
            }
            for c in issue.get("comments", {}).get("nodes", [])
        ]
        agent_indices = [
            i
            for i, x in enumerate(items)
            if _has_persona(x["body"], markers)
            and trusted_comment_author(x, trusted_logins=trusted_logins)
        ]
        if not agent_indices:
            continue
        last = agent_indices[-1]
        threads.append({
            "kind": "Issue",
            "number": issue["number"],
            "title": issue["title"],
            "agent_item": items[last],
            "replies": items[last + 1:],
        })

    for disc in repo.get("discussions", {}).get("nodes", []):
        disc_body = disc.get("body", "")
        items = [
            {
                "body": c.get("body", ""),
                "author": (c.get("author") or {}).get("login", ""),
                "authorAssociation": c.get("authorAssociation", ""),
                "time": c.get("createdAt", ""),
            }
            for c in disc.get("comments", {}).get("nodes", [])
        ]
        discussion_item = {
            "body": disc_body,
            "author": ((disc.get("author") or {}).get("login", "")),
            "authorAssociation": disc.get("authorAssociation", ""),
            "time": disc.get("createdAt", ""),
        }
        if _has_persona(disc_body, markers) and trusted_comment_author(
            discussion_item,
            trusted_logins=trusted_logins,
        ):
            threads.append({
                "kind": "Discussion (proposed)",
                "number": disc["number"],
                "title": disc["title"],
                "agent_item": discussion_item,
                "replies": items,
            })
            continue
        agent_indices = [
            i
            for i, x in enumerate(items)
            if _has_persona(x["body"], markers)
            and trusted_comment_author(x, trusted_logins=trusted_logins)
        ]
        if not agent_indices:
            continue
        last = agent_indices[-1]
        threads.append({
            "kind": "Discussion",
            "number": disc["number"],
            "title": disc["title"],
            "agent_item": items[last],
            "replies": items[last + 1:],
        })

    threads.sort(key=lambda t: t["agent_item"]["time"], reverse=True)
    return threads


def _render_reply_excerpt(
    item: dict[str, object],
    *,
    trusted_logins: set[str] | None = None,
    limit: int,
) -> str:
    if trusted_comment_author(item, trusted_logins=trusted_logins):
        return str(item.get("body", ""))[:limit].replace("\n", "\n      ")
    return UNTRUSTED_BODY_NOTE


def _format_thread(
    t: dict,
    *,
    trusted_logins: set[str] | None = None,
) -> str:
    excerpt = t["agent_item"]["body"][:500].replace("\n", "\n    ")
    lines = [
        f"  {t['kind']} #{t['number']} — {t['title']}",
        f"    You wrote ({t['agent_item']['time']}):",
        f"    {excerpt}",
    ]
    if t["replies"]:
        lines.append("    Replies since:")
        for r in t["replies"][:5]:
            r_text = _render_reply_excerpt(
                r,
                trusted_logins=trusted_logins,
                limit=300,
            )
            lines.append(f"    - {r['author']} ({r['time']}): {r_text}")
    else:
        lines.append("    No replies yet.")
    return "\n".join(lines)


def gather_agent_history(
    persona: str,
    owner: str,
    name: str,
    env: dict[str, str],
    *,
    bot_login: str = "",
) -> str:
    if not persona:
        return ""

    log(f"Gathering recent history for {persona}")
    raw = run_optional(
        [
            "gh", "api", "graphql",
            "-f", f"query={HISTORY_QUERY}",
            "-f", f"owner={owner}",
            "-f", f"name={name}",
        ],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="{}",
    )
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return ""

    markers = [f"*{persona}", f"*Proposed by {persona}"]
    trusted_logins = trusted_automation_logins(env)
    if bot_login:
        trusted_logins.add(bot_login.casefold())
    threads = _find_agent_threads(data, markers, trusted_logins=trusted_logins)
    if not threads:
        return ""

    formatted = "\n\n".join(
        _format_thread(t, trusted_logins=trusted_logins)
        for t in threads[:3]
    )
    return (
        f"Your last actions as {persona} and what happened since:\n\n"
        f"{formatted}"
    )


def gather_backlog_state() -> str:
    lines: list[str] = []
    for path in sorted((REPO_ROOT / "backlog").glob("*.md")):
        status = "unknown"
        try:
            for line in path.read_text().splitlines():
                if line.startswith("status:"):
                    status = line.split(":", 1)[1].strip() or "unknown"
                    break
        except OSError:
            continue
        lines.append(f"{path.name}: {status}")
    return "\n".join(lines)


def _extract_proposed_persona(body: str) -> str:
    match = re.search(r"\*Proposed by ([^*\n]+)\*", body)
    if not match:
        return ""
    return match.group(1).split(",", 1)[0].strip()


def _is_idea_discussion(title: str) -> bool:
    return "[idea]" in title.casefold()


def compute_wip_state(
    discussions: list[dict[str, object]],
    issues: list[dict[str, object]],
    *,
    owner_login: str,
    now: datetime | None = None,
) -> dict[str, object]:
    if now is None:
        now = datetime.now(timezone.utc)
    owner = _normalize_login(owner_login)

    open_discussions = len(discussions)
    open_agent_issues = sum(
        1 for issue in issues
        if "agent:task" in issue_label_names(issue)
    )

    stale: list[dict[str, object]] = []
    for disc in discussions:
        if not _is_idea_discussion(str(disc.get("title", ""))):
            continue
        comments = disc.get("comments", {})
        comment_nodes = comments.get("nodes", []) if isinstance(comments, dict) else []
        last_activity = _parse_timestamp(str(disc.get("createdAt", "")))
        for comment in comment_nodes:
            ts = _parse_timestamp(str(comment.get("createdAt", "")))
            if ts is not None and (last_activity is None or ts > last_activity):
                last_activity = ts
        owner_replied = any(
            _normalize_login((comment.get("author") or {}).get("login", "")) == owner
            for comment in comment_nodes
        )
        if last_activity is not None and (now - last_activity).days >= STALE_DISCUSSION_DAYS:
            stale.append({
                "number": disc.get("number"),
                "title": disc.get("title"),
                "days_stale": (now - last_activity).days,
                "owner_replied": owner_replied,
            })

    return {
        "open_discussions": open_discussions,
        "open_agent_issues": open_agent_issues,
        "discussions_at_cap": open_discussions >= DISCUSSION_WIP_CAP,
        "issues_at_cap": open_agent_issues >= ISSUE_WIP_CAP,
        "stale_discussions": stale,
        "discussion_cap": DISCUSSION_WIP_CAP,
        "issue_cap": ISSUE_WIP_CAP,
    }


def format_wip_state(wip: dict[str, object]) -> str:
    lines = [
        f"WIP state: {wip['open_discussions']}/{wip['discussion_cap']} open discussions, "
        f"{wip['open_agent_issues']}/{wip['issue_cap']} open agent:task issues"
    ]
    if wip["discussions_at_cap"]:
        lines.append(
            "DISCUSSION CAP REACHED — close or resolve existing discussions before proposing new ones."
        )
    if wip["issues_at_cap"]:
        lines.append(
            "ISSUE CAP REACHED — close existing issues (ship PRs or mark won't-do) before planning new ones."
        )
    stale = list(wip.get("stale_discussions") or [])
    if stale:
        stale_items = ", ".join(
            f"#{s['number']} ({s['days_stale']}d)" for s in stale
        )
        lines.append(f"Stale discussions ({STALE_DISCUSSION_DAYS}+ days idle): {stale_items}")
    return "\n".join(lines)


def format_open_discussions(
    discussions: list[dict[str, object]],
    *,
    trusted_logins: set[str] | None = None,
) -> str:
    lines: list[str] = []
    for disc in discussions:
        comments = disc.get("comments", {})
        comment_nodes = comments.get("nodes", []) if isinstance(comments, dict) else []
        comment_count = comments.get("totalCount", len(comment_nodes)) if isinstance(comments, dict) else 0
        category = disc.get("category", {})
        category_name = category.get("name", "Unknown") if isinstance(category, dict) else "Unknown"
        line = (
            f"#{disc.get('number')} [{category_name}] {disc.get('title')} "
            f"({comment_count} comments)"
        )
        previews: list[str] = []
        omitted_untrusted = 0
        for comment in comment_nodes:
            if not trusted_comment_author(comment, trusted_logins=trusted_logins):
                omitted_untrusted += 1
                continue
            author = (comment.get("author") or {}).get("login", "unknown")
            body = str(comment.get("body", "")).replace("\n", " ")[:200]
            previews.append(f"  -> {author}: {body}")
            if len(previews) == 2:
                break
        if previews:
            line = f"{line}\n" + "\n".join(previews)
        if omitted_untrusted:
            line = (
                f"{line}\n  -> {omitted_untrusted} untrusted comment preview(s) omitted"
            )
        lines.append(line)
    return "\n".join(lines)


def find_discussions_needing_engagement(
    discussions: list[dict[str, object]],
    *,
    owner_login: str,
    persona: str,
    now: datetime | None = None,
) -> list[dict[str, object]]:
    if now is None:
        now = datetime.now(timezone.utc)

    owner = _normalize_login(owner_login)
    current_persona = persona.casefold()
    candidates: list[dict[str, object]] = []

    for disc in discussions:
        title = str(disc.get("title", ""))
        if not _is_idea_discussion(title):
            continue

        body = str(disc.get("body", ""))
        comments = disc.get("comments", {})
        comment_nodes = comments.get("nodes", []) if isinstance(comments, dict) else []
        comment_count = comments.get("totalCount", len(comment_nodes)) if isinstance(comments, dict) else 0
        proposed_by = _extract_proposed_persona(body)
        created_at = _parse_timestamp(str(disc.get("createdAt", "")))
        age = now - created_at if created_at is not None else None
        owner_replied = any(
            _normalize_login((comment.get("author") or {}).get("login", "")) == owner
            for comment in comment_nodes
        )
        other_agent_recent = bool(
            proposed_by
            and proposed_by.casefold() != current_persona
            and age is not None
            and age <= timedelta(hours=ENGAGEMENT_RECENT_HOURS)
        )

        reasons: list[str] = []
        if other_agent_recent:
            age_hours = max(1, int(age.total_seconds() // 3600)) if age is not None else ENGAGEMENT_RECENT_HOURS
            reasons.append(f"{proposed_by} opened this {age_hours}h ago")
        if comment_count == 0:
            reasons.append("0 comments")
        elif comment_count <= LOW_COMMENT_THRESHOLD:
            reasons.append("only 1 comment")
        if not owner_replied:
            reasons.append("no owner reply yet")

        if not reasons:
            continue

        if other_agent_recent:
            priority = 0
        elif comment_count <= LOW_COMMENT_THRESHOLD:
            priority = 1
        else:
            priority = 2

        sort_timestamp = created_at.timestamp() if created_at is not None else 0.0
        candidates.append(
            {
                "number": disc.get("number"),
                "title": title,
                "proposed_by": proposed_by,
                "comment_count": comment_count,
                "owner_replied": owner_replied,
                "reasons": reasons,
                "priority": priority,
                "sort_timestamp": sort_timestamp,
            }
        )

    candidates.sort(
        key=lambda item: (
            int(item["priority"]),
            int(item["comment_count"]),
            -float(item["sort_timestamp"]),
        )
    )
    return candidates


def format_engagement_candidates(candidates: list[dict[str, object]]) -> str:
    if not candidates:
        return ""

    lines = ["PRIORITY — discussions needing engagement before new proposals:\n"]
    for candidate in candidates[:5]:
        reasons = ", ".join(str(reason) for reason in candidate["reasons"])
        lines.append(
            f"  Discussion #{candidate['number']} — {candidate['title']}\n"
            f"    Reasons: {reasons}"
        )
    return "\n".join(lines)


def build_engagement_retry_message(candidate: dict[str, object]) -> str:
    reasons = ", ".join(str(reason) for reason in candidate["reasons"])
    return (
        "Do not propose a new discussion. Comment on the existing discussion "
        f"#{candidate['number']} instead and help move that thread forward. "
        f"It needs engagement because: {reasons}. Respond to the existing thesis, "
        "refine the scope, or ask one concrete question that advances the thread."
    )


def format_issue_list_for_context(issues: list[dict[str, object]]) -> str:
    payload = [
        {
            "number": issue.get("number"),
            "title": issue.get("title"),
            "labels": sorted(issue_label_names(issue)),
            "url": issue.get("url"),
        }
        for issue in issues
    ]
    return json.dumps(payload, indent=2, ensure_ascii=False)


def format_pr_list_for_context(
    pull_requests: list[dict[str, object]],
    issues: list[dict[str, object]],
    *,
    pr_diffs: dict[int, str] | None = None,
) -> str:
    issue_map = {
        int(issue["number"]): issue
        for issue in issues
        if issue.get("number") is not None
    }
    pr_diffs = pr_diffs or {}
    payload: list[dict[str, object]] = []
    seen_pr_numbers: set[int] = set()
    for pr in pull_requests:
        pr_number = int(pr.get("number", 0))
        seen_pr_numbers.add(pr_number)
        pr_body = str(pr.get("body", ""))
        issue_number, _ = extract_pr_issue_reference(pr_body)
        entry: dict[str, object] = {
            "number": pr_number,
            "title": pr.get("title"),
            "author": (pr.get("author") or {}).get("login", ""),
            "isDraft": pr.get("isDraft"),
            "reviewDecision": pr.get("reviewDecision"),
            "headRefName": pr.get("headRefName"),
            "url": pr.get("url"),
        }
        if issue_number is not None:
            issue_body = str(issue_map.get(issue_number, {}).get("body", ""))
            requested_evidence = extract_requested_evidence(issue_body)
            accounting = evaluate_evidence_accounting(pr_body, requested_evidence)
            entry["linkedIssue"] = issue_number
            if _explicit_evidence_contract(requested_evidence):
                summary: dict[str, object] = {
                    "contract": "explicit",
                    "requested": len(requested_evidence),
                    "complete": len(accounting["complete_items"]),
                    "blocked": len(accounting["blocked_items"]),
                    "missing": len(accounting["missing_items"]),
                    "source": accounting["source"],
                }
                if accounting["source"] == "markdown":
                    summary["malformed"] = len(accounting["invalid_lines"])
                entry["evidenceSummary"] = summary
            else:
                entry["evidenceSummary"] = {
                    "contract": "none",
                }
        diff = pr_diffs.get(pr_number, "")
        if diff:
            entry["diff"] = diff
        payload.append(entry)
    for pr_number, diff in sorted(pr_diffs.items()):
        if pr_number in seen_pr_numbers or not diff:
            continue
        payload.append({
            "number": pr_number,
            "title": "Directed PR outside open work state",
            "state": "not_in_open_work_state",
            "diff": diff,
        })
    return json.dumps(payload, indent=2, ensure_ascii=False)


def find_prs_awaiting_rereview(
    pull_requests: list[dict[str, object]],
    bot_login: str,
) -> str:
    awaiting: list[str] = []

    for pr in pull_requests:
        reviews = (pr.get("reviews") or {}).get("nodes", [])
        agent_reviews = [
            review
            for review in reviews
            if _normalize_login((review.get("author") or {}).get("login", "")) == _normalize_login(bot_login)
        ]
        if not agent_reviews:
            continue

        latest_agent_review = max(agent_reviews, key=lambda review: review.get("submittedAt", ""))
        if latest_agent_review.get("state") == "APPROVED":
            continue

        commits = (pr.get("commits") or {}).get("nodes", [])
        if not commits:
            continue
        latest_commit_date = commits[0].get("commit", {}).get("committedDate", "")
        review_date = latest_agent_review.get("submittedAt", "")

        if latest_commit_date > review_date:
            awaiting.append(
                f"  PR #{pr['number']} — {pr['title']}\n"
                f"    Your review: {latest_agent_review['state']} at {review_date}\n"
                f"    Latest commit: {latest_commit_date} (pushed AFTER your review)"
            )

    if not awaiting:
        return ""

    return (
        "PRIORITY — PRs awaiting your re-review (you reviewed but didn't approve, "
        "and the author has pushed new commits since):\n\n"
        + "\n\n".join(awaiting)
    )


def latest_external_review(
    pr: dict[str, object],
    *,
    normalized_bot: str,
    trusted_logins: set[str] | None = None,
) -> dict[str, str] | None:
    reviews = (pr.get("reviews") or {}).get("nodes", [])
    external_reviews = [
        review
        for review in reviews
        if _normalize_login((review.get("author") or {}).get("login", "")) != normalized_bot
        and str(review.get("body", "")).strip()
    ]
    if not external_reviews:
        return None
    latest = max(external_reviews, key=lambda review: review.get("submittedAt", ""))
    body = str(latest.get("body", "")).strip()
    if not trusted_comment_author(latest, trusted_logins=trusted_logins):
        body = "[review body omitted from untrusted public author]"
    return {
        "author": str((latest.get("author") or {}).get("login", "")),
        "state": str(latest.get("state", "")),
        "submittedAt": str(latest.get("submittedAt", "")),
        "body": body,
    }


def format_review_excerpt(review: dict[str, str] | None, *, indent: str) -> str:
    if review is None:
        return f"{indent}Latest external review: none"
    excerpt = " ".join(review["body"].split())
    if len(excerpt) > 280:
        excerpt = excerpt[:277].rstrip() + "..."
    return (
        f"{indent}Latest external review: {review['author']} ({review['state']}) at {review['submittedAt']}\n"
        f"{indent}  {excerpt}"
    )


def classify_execution_work(
    issues: list[dict[str, object]],
    pull_requests: list[dict[str, object]],
    discussions: list[dict[str, object]],
    issue_states: dict[int, str],
    *,
    owner_login: str,
    persona: str,
    bot_login: str,
    trusted_logins: set[str] | None = None,
    now: datetime | None = None,
) -> dict[str, list[dict[str, object]]]:
    current_agent = persona_slug(persona)
    normalized_bot = _normalize_login(bot_login)
    trusted_actor_logins = set(trusted_logins or trusted_automation_logins())
    if bot_login:
        trusted_actor_logins.add(bot_login.casefold())
    issue_pr_map: dict[int, list[dict[str, object]]] = {}
    for pr in pull_requests:
        issue_number, marker_agent = extract_pr_issue_reference(str(pr.get("body", "")))
        if issue_number is None:
            continue
        author_login = str((pr.get("author") or {}).get("login", ""))
        issue_pr_map.setdefault(issue_number, []).append(
            {
                "number": pr.get("number"),
                "title": pr.get("title"),
                "url": pr.get("url"),
                "body": pr.get("body", ""),
                "author_login": author_login,
                "reviewDecision": pr.get("reviewDecision"),
                "headRefName": pr.get("headRefName"),
                "reviews": pr.get("reviews", {}),
                "comments": pr.get("comments", {}),
                "agent": marker_agent or (current_agent if _normalize_login(author_login) == normalized_bot else ""),
            }
        )

    own_open_prs: list[dict[str, object]] = []
    claimed_issues: list[dict[str, object]] = []
    ready_issues: list[dict[str, object]] = []

    for issue in issues:
        labels = issue_label_names(issue)
        if AGENT_CLAIM_LABEL not in labels and AGENT_READY_LABEL not in labels and "agent:task" not in labels:
            continue
        if "agent:task" not in labels:
            continue

        issue_number = int(issue["number"])
        body = str(issue.get("body", ""))
        discussion_number = extract_issue_discussion_number(body)
        priority = extract_execution_priority(body)
        blocked_by = extract_blocked_by(body)
        requested_evidence = extract_requested_evidence(body)
        blockers = [
            blocker
            for blocker in blocked_by
            if issue_states.get(blocker, "OPEN").upper() != "CLOSED"
        ]
        latest_claim = latest_issue_claim(
            issue_number,
            issue.get("comments", {}),
            trusted_logins=trusted_actor_logins,
        )
        claim_agent = latest_claim.get("agent") if latest_claim else None
        linked_prs = issue_pr_map.get(issue_number, [])
        stale_claim = claim_is_stale(latest_claim, has_open_pr=bool(linked_prs), now=now)
        if stale_claim:
            latest_claim = None
            claim_agent = None
        own_pr = next(
            (
                pr
                for pr in linked_prs
                if pr["agent"] == current_agent
                or (
                    not pr["agent"]
                    and _normalize_login(str(pr["author_login"])) == normalized_bot
                )
            ),
            None,
        )

        item = {
            "issue_number": issue_number,
            "title": issue.get("title"),
            "url": issue.get("url"),
            "discussion_number": discussion_number,
            "priority": priority,
            "blocked_by": blocked_by,
            "requested_evidence": requested_evidence,
            "approval_reason": (
                f"{AGENT_READY_LABEL} label present"
                if AGENT_READY_LABEL in labels
                else f"waiting for {AGENT_READY_LABEL} label"
            ),
            "claim_branch": latest_claim.get("branch") if latest_claim else "",
            "claim_agent": claim_agent or "",
        }

        if own_pr is not None:
            accounting = evaluate_evidence_accounting(str(own_pr.get("body", "")), requested_evidence)
            own_open_prs.append(
                {
                    **item,
                    "pr_number": own_pr["number"],
                    "pr_title": own_pr["title"],
                    "pr_url": own_pr["url"],
                    "pr_branch": own_pr["headRefName"],
                    "review_decision": own_pr["reviewDecision"] or "REVIEW_REQUIRED",
                    "evidence_accounting": accounting,
                    "latest_external_review": latest_external_review(
                        own_pr,
                        normalized_bot=normalized_bot,
                        trusted_logins=trusted_actor_logins,
                    ),
                }
            )
            continue

        if latest_claim is not None and claim_agent == current_agent:
            claimed_issues.append(item)
            continue

        if AGENT_READY_LABEL not in labels or blockers or linked_prs:
            continue
        if latest_claim is not None and claim_agent and claim_agent != current_agent:
            continue
        if AGENT_CLAIM_LABEL in labels and latest_claim is None:
            continue

        ready_issues.append(item)

    def sort_key(item: dict[str, object]) -> tuple[int, int]:
        priority = int(item["priority"]) if item.get("priority") is not None else 9999
        return priority, int(item["issue_number"])

    own_open_prs.sort(key=sort_key)
    claimed_issues.sort(key=sort_key)
    ready_issues.sort(key=sort_key)
    return {
        "own_open_prs": own_open_prs,
        "claimed_issues": claimed_issues,
        "ready_issues": ready_issues,
    }


def format_own_open_prs(items: list[dict[str, object]]) -> str:
    if not items:
        return ""
    lines = ["PRIORITY — your open PRs to advance after reviews:\n"]
    for item in items[:5]:
        lines.append(
            f"  PR #{item['pr_number']} — {item['pr_title']}\n"
            f"    Issue: #{item['issue_number']} | Review decision: {item['review_decision']} | Branch: {item['pr_branch']}\n"
            f"    IMPORTANT: `git checkout {item['pr_branch']}` before editing — the runtime rejects commits on the wrong branch."
        )
        lines.append(
            format_requested_evidence_numbered(
                list(item["requested_evidence"]),
                indent="    ",
            )
        )
        lines.append(
            f"    {summarize_evidence_accounting_by_index(item['evidence_accounting'], list(item['requested_evidence']))}"
        )
        lines.append(
            format_review_excerpt(
                item.get("latest_external_review"),
                indent="    ",
            )
        )
    return "\n".join(lines)


def format_claimed_issues(items: list[dict[str, object]]) -> str:
    if not items:
        return ""
    lines = ["PRIORITY — issues you already claimed and should keep moving:\n"]
    for item in items[:5]:
        priority = item.get("priority")
        priority_text = f"Priority {priority}" if priority is not None else "Priority unrecorded"
        lines.append(
            f"  Issue #{item['issue_number']} — {item['title']}\n"
            f"    {priority_text} | Branch: {item['claim_branch'] or 'not recorded'}\n"
            f"    Requested evidence summary: {summarize_requested_evidence(list(item['requested_evidence']))}"
        )
        lines.append(
            format_requested_evidence_numbered(
                list(item["requested_evidence"]),
                indent="    ",
            )
        )
    return "\n".join(lines)


def format_ready_issues(items: list[dict[str, object]]) -> str:
    if not items:
        return ""
    lines = ["PRIORITY — execution-approved issues ready to claim if no PR work is waiting:\n"]
    for item in items[:5]:
        priority = item.get("priority")
        priority_text = f"Priority {priority}" if priority is not None else "Priority unrecorded"
        discussion = (
            f"discussion #{item['discussion_number']}"
            if item.get("discussion_number") is not None
            else "linked discussion unavailable"
        )
        lines.append(
            f"  Issue #{item['issue_number']} — {item['title']}\n"
            f"    {priority_text} | Approval: {item['approval_reason']} | From {discussion}\n"
            f"    Requested evidence summary: {summarize_requested_evidence(list(item['requested_evidence']))}"
        )
        lines.append(
            format_requested_evidence_numbered(
                list(item["requested_evidence"]),
                indent="    ",
            )
        )
    return "\n".join(lines)


def maybe_block_new_proposal(
    validated_json: str,
    engagement_candidates: list[dict[str, object]],
    *,
    discussions_at_cap: bool = False,
) -> dict[str, object] | None:
    data = json.loads(validated_json)
    if data.get("action") != "propose":
        return None
    if engagement_candidates:
        return engagement_candidates[0]
    if discussions_at_cap:
        return {
            "number": 0,
            "title": "WIP cap reached",
            "proposed_by": "",
            "comment_count": 0,
            "owner_replied": False,
            "reasons": ["discussion WIP cap reached — close existing discussions first"],
            "priority": 0,
            "sort_timestamp": 0.0,
        }
    return None


def runner_platform_note() -> str:
    if platform.system() == "Darwin":
        return "Runner platform: macOS"
    return (
        "Runner platform: Linux (Swift toolchain unavailable for native app targets; "
        "use evidence_pending_ci for build/test/screenshot items — "
        "the downstream evidence job will resolve them)"
    )


def gather_context(
    env: dict[str, str],
    persona: str = "",
    bot_login: str = "",
    message: str = "",
) -> tuple[str, list[dict[str, object]], dict[str, object]]:
    log("Gathering context")
    owner, name = repo_owner_name(env)

    recent_commits = run_checked(
        ["git", "log", "--oneline", "--since=2 weeks ago"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    ).stdout.rstrip()

    work_state = fetch_work_state(owner, name, env)
    discussion_nodes = work_state["discussions"]
    trusted_logins = trusted_automation_logins(env)
    if bot_login:
        trusted_logins.add(bot_login.casefold())
    discussions = format_open_discussions(
        discussion_nodes,
        trusted_logins=trusted_logins,
    )
    engagement_candidates = find_discussions_needing_engagement(
        discussion_nodes,
        owner_login=owner,
        persona=persona,
    )
    engagement_summary = format_engagement_candidates(engagement_candidates)
    open_issues = format_issue_list_for_context(work_state["issues"])

    # Pre-fetch PR diffs so the agent can review without needing gh CLI access.
    # All open PRs get diffs at a generous limit — context window can absorb it.
    directed_pr = parse_directed_pr_number(message) if message else None
    pr_diffs: dict[int, str] = {}
    for pr in work_state["pull_requests"]:
        pr_number = int(pr.get("number", 0))
        diff = fetch_pr_diff(pr_number, env, max_lines=PR_DIFF_MAX_LINES)
        if diff:
            pr_diffs[pr_number] = diff
    if directed_pr and directed_pr not in pr_diffs:
        # Directed PR might not be in work_state (e.g., already merged) — fetch anyway
        diff = fetch_pr_diff(directed_pr, env, max_lines=PR_DIFF_MAX_LINES)
        if diff:
            pr_diffs[directed_pr] = diff
    if pr_diffs:
        log(f"Pre-fetched diffs for {len(pr_diffs)} PR(s)")

    open_prs = format_pr_list_for_context(work_state["pull_requests"], work_state["issues"], pr_diffs=pr_diffs)

    wip_state = compute_wip_state(
        discussion_nodes,
        work_state["issues"],
        owner_login=owner,
    )
    wip_summary = format_wip_state(wip_state)

    backlog_state = gather_backlog_state()
    history = gather_agent_history(
        persona,
        owner,
        name,
        env,
        bot_login=bot_login,
    )
    issue_states = fetch_issue_state_map(env)
    execution_state = classify_execution_work(
        work_state["issues"],
        work_state["pull_requests"],
        discussion_nodes,
        issue_states,
        owner_login=owner,
        persona=persona,
        bot_login=bot_login,
        trusted_logins=trusted_logins,
    )
    pending_reviews = find_prs_awaiting_rereview(work_state["pull_requests"], bot_login) if bot_login else ""
    own_open_prs = format_own_open_prs(execution_state["own_open_prs"])
    claimed_issues = format_claimed_issues(execution_state["claimed_issues"])
    ready_issues = format_ready_issues(execution_state["ready_issues"])

    sections = []
    sections.append(runner_platform_note())
    sections.append(wip_summary)
    if pending_reviews:
        sections.append(pending_reviews)
    if own_open_prs:
        sections.append(own_open_prs)
    if claimed_issues:
        sections.append(claimed_issues)
    if ready_issues:
        sections.append(ready_issues)
    if engagement_summary:
        sections.append(engagement_summary)
    sections.extend([
        f"Recent commits (last 2 weeks):\n{recent_commits}",
        f"Open discussions:\n{discussions}",
        f"Open issues:\n{open_issues}",
        f"Open PRs:\n{open_prs}",
        f"Backlog state:\n{backlog_state}",
    ])
    if history:
        sections.append(history)
    return "\n\n".join(sections), engagement_candidates, wip_state
