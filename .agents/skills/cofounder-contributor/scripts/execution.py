"""Claiming issues, branching, committing, and PR operations."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

from _helpers import (
    AGENT_CLAIM_LABEL,
    AGENT_CLAIM_LABEL_COLOR,
    AGENT_CLAIM_LABEL_DESCRIPTION,
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
    render_execution_summary_body,
    review_evidence_gate_error,
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
    ensure_label_exists(env, AGENT_CLAIM_LABEL, AGENT_CLAIM_LABEL_COLOR, AGENT_CLAIM_LABEL_DESCRIPTION)


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
) -> tuple[str, list[str]]:
    summary_body = str(data.get("body", "")).strip()
    use_structured = (
        data.get("action") == "advance_pr"
        or "evidence_complete" in data
        or "evidence_blocked" in data
        or "evidence_pending_ci" in data
    )
    if not use_structured:
        return summary_body, []
    return render_execution_summary_body(
        summary_body,
        requested_evidence=requested_evidence,
        evidence_complete=data.get("evidence_complete"),
        evidence_blocked=data.get("evidence_blocked"),
        evidence_pending_ci=data.get("evidence_pending_ci"),
    )


def set_git_identity(env: dict[str, str], persona: str, bot_login: str) -> None:
    user_name = bot_login or short_persona_name(persona)
    user_email = f"{persona_slug(persona)}@users.noreply.github.com"
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
        cmd = ["gh", "issue", "edit", str(issue_number), "--add-label", AGENT_CLAIM_LABEL]
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
    pr_body = run_optional(
        ["gh", "pr", "view", str(pr_number), "--json", "body", "--jq", ".body"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    )
    linked_issue, _ = extract_pr_issue_reference(pr_body)
    if linked_issue is None:
        return
    if verdict in ("approve", "approve_with_followups"):
        ensure_label_exists(env, AGENT_MERGEABLE_LABEL, AGENT_MERGEABLE_LABEL_COLOR, AGENT_MERGEABLE_LABEL_DESCRIPTION)
        run_checked(
            ["gh", "issue", "edit", str(linked_issue), "--add-label", AGENT_MERGEABLE_LABEL],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
    else:
        run_optional(
            ["gh", "issue", "edit", str(linked_issue), "--remove-label", AGENT_MERGEABLE_LABEL],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
            default="",
        )


def _write_github_outputs(
    needs_evidence: bool,
    needs_screenshot_evidence: bool,
    branch: str,
    test_commands: list[str],
) -> None:
    output_file = os.environ.get("GITHUB_OUTPUT", "")
    if not output_file:
        log("GITHUB_OUTPUT not set; skipping output emission")
        return
    with open(output_file, "a") as f:
        f.write(f"needs_macos_evidence={str(needs_evidence).lower()}\n")
        f.write(f"needs_screenshot_evidence={str(needs_screenshot_evidence).lower()}\n")
        f.write(f"pr_branch={branch}\n")
        f.write(f"test_commands_json={json.dumps(test_commands, separators=(',', ':'))}\n")
    log(
        "Emitted outputs: "
        f"needs_macos_evidence={needs_evidence}, "
        f"needs_screenshot_evidence={needs_screenshot_evidence}, "
        f"pr_branch={branch}, "
        f"test_commands={test_commands}"
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
        return 1

    own_pr = state.get("own_pr")
    other_pr = state.get("other_pr")
    if require_existing_pr:
        if own_pr is None:
            print(
                f"error: issue #{issue_number} has no open PR owned by {persona_slug(persona)} to advance",
                file=sys.stderr,
            )
            return 1
        if int(data["pr_number"]) != int(own_pr["number"]):
            print(
                f"error: issue #{issue_number} is linked to PR #{own_pr['number']}, not PR #{data['pr_number']}",
                file=sys.stderr,
            )
            return 1

    if own_pr is None and not bool(state.get("approved")):
        print(
            f"error: issue #{issue_number} is not execution-approved ({state.get('approval_reason')})",
            file=sys.stderr,
        )
        return 1
    if own_pr is None and state.get("blockers"):
        print(
            f"error: issue #{issue_number} is still blocked by {state['blockers']}",
            file=sys.stderr,
        )
        return 1

    requested_evidence = list(state.get("requested_evidence", []))
    test_command_errors = validate_requested_test_commands(requested_evidence, env)
    if test_command_errors:
        print(
            "error: requested test evidence is invalid: " + "; ".join(test_command_errors),
            file=sys.stderr,
        )
        return 1
    if other_pr is not None:
        print(
            f"error: issue #{issue_number} already has open PR #{other_pr['number']} by another agent",
            file=sys.stderr,
        )
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
        return 1

    summary_body, summary_errors = build_execution_summary_body(
        data,
        requested_evidence=requested_evidence,
    )
    if summary_errors:
        print(
            "error: PR body evidence accounting is incomplete: "
            + "; ".join(summary_errors),
            file=sys.stderr,
        )
        return 1

    _, evidence_errors = validate_evidence_accounting(summary_body, requested_evidence)
    if evidence_errors:
        print(
            "error: PR body evidence accounting is incomplete: "
            + "; ".join(evidence_errors),
            file=sys.stderr,
        )
        return 1
    pr_body = compose_pr_body(issue_number, persona, summary_body)

    branch = current_branch(env)
    if own_pr is not None:
        expected_branch = str(own_pr.get("headRefName", ""))
        if branch != expected_branch:
            print(
                f"error: issue #{issue_number} already has PR #{own_pr['number']} on "
                f"branch '{expected_branch}'. Check out that branch before editing.",
                file=sys.stderr,
            )
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
        ensure_issue_claimed(
            issue_number,
            persona,
            branch,
            latest_claim if isinstance(latest_claim, dict) else None,
            issue_label_presence(state["issue"]),
            env,
            bot_login=bot_login or "",
        )

    if not working_tree_dirty(env):
        print(
            f"error: {data['action']} selected for #{issue_number} but no file changes were made",
            file=sys.stderr,
        )
        return 1

    set_git_identity(env, persona, bot_login)
    run_checked(["git", "add", "-A"], timeout=GITHUB_API_TIMEOUT, cwd=REPO_ROOT, env=env)
    run_checked(
        ["git", "commit", "-m", str(data["commit_message"]).strip()],
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

    evidence_needed = _needs_macos_evidence(requested_evidence)
    screenshot_evidence_needed = _needs_screenshot_evidence(requested_evidence)
    test_commands = _extract_test_commands(requested_evidence)
    _write_github_outputs(
        evidence_needed,
        screenshot_evidence_needed,
        branch,
        test_commands,
    )

    if own_pr is not None:
        run_checked(
            [
                "gh",
                "pr",
                "edit",
                str(own_pr["number"]),
                "--title",
                str(data["pr_title"]).strip(),
                "--body",
                pr_body,
            ],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
        return 0

    run_checked(
        [
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
        ],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
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

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(body)
        body_file = handle.name

    # Look up through the entrypoint module to allow mock.patch.object patching.
    _mod = sys.modules.get("run_contributor", sys.modules[__name__])

    try:
        if action == "review_pr":
            verdict = str(data.get("verdict", "")).lower()
            pr_number = int(data["pr_number"])
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
    return 1
