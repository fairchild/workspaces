"""Claiming issues, branching, committing, and PR operations."""

from __future__ import annotations

import hmac
import json
import os
import re
import subprocess
import sys
import tempfile

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
    issue_label_names,
    issue_label_presence,
    log,
    persona_slug,
    run_checked,
    run_optional,
    short_persona_name,
)
from evidence import (
    _extract_test_commands,
    _needs_macos_evidence,
    _needs_screenshot_evidence,
    classify_evidence_errors,
    render_execution_summary_body,
    review_evidence_gate_error,
    synthesize_initial_execution_evidence,
    validate_evidence_accounting,
    validate_requested_test_commands,
)
from github_state import (
    current_branch,
    default_branch,
    detect_bot_login,
    extract_pr_issue_reference,
    find_issue_execution_state,
    find_pr_review_state,
    repo_owner_name,
)

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
) -> tuple[str, list[str]]:
    summary_body = str(data.get("body", "")).strip()
    if not requested_evidence:
        return summary_body, []
    evidence_complete, evidence_blocked, evidence_pending_ci = synthesize_initial_execution_evidence(
        requested_evidence,
        visual_evidence_available=visual_evidence_available,
    )
    return render_execution_summary_body(
        summary_body,
        requested_evidence=requested_evidence,
        evidence_complete=evidence_complete,
        evidence_blocked=evidence_blocked,
        evidence_pending_ci=evidence_pending_ci,
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
    log(
        "Emitted outputs: "
        f"needs_macos_evidence={needs_evidence}, "
        f"needs_screenshot_evidence={needs_screenshot_evidence}, "
        f"pr_branch={branch}, "
        f"pr_number={pr_number}, "
        f"pr_head_sha={pr_head_sha}, "
        f"test_commands={test_commands}"
    )


def _factory_evidence_should_block(
    *,
    factory_requires_evidence: bool,
    needs_macos_evidence: bool,
    visual_evidence_blocked: bool,
) -> bool:
    return visual_evidence_blocked or (
        factory_requires_evidence and not needs_macos_evidence
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
    )
    if summary_errors:
        print(
            "error: PR body evidence accounting is incomplete: "
            + "; ".join(summary_errors),
            file=sys.stderr,
        )
        log(json.dumps({"error_class": "evidence_validation", "detail": "; ".join(summary_errors), "issue": issue_number}))
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
        _write_github_outputs(
            evidence_needed,
            screenshot_evidence_needed,
            branch,
            test_commands,
            pr_number,
            pr_head_sha,
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
    _write_github_outputs(
        evidence_needed,
        screenshot_evidence_needed,
        branch,
        test_commands,
        pr_number,
        pr_head_sha,
    )
    return 0


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
        return 1, None, "validation timed out"
    if result.returncode == 0:
        return 0, result.stdout, result.stderr
    error_text = result.stderr.strip()
    if error_text:
        print(error_text, file=sys.stderr)
    return result.returncode, None, error_text


def route_action(validated_json: str, dry_run: bool, env: dict[str, str]) -> int:
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
                )
                if evidence_gate_error is not None:
                    print(
                        f"error: PR #{pr_number} cannot be reviewed with verdict '{verdict}': {evidence_gate_error}",
                        file=sys.stderr,
                    )
                    categories = [c["category"] for c in classify_evidence_errors(review_state["evidence_errors"])]
                    log(json.dumps({"error_class": "evidence_gate", "categories": categories, "pr": pr_number, "verdict": verdict}))
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
