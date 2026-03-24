#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run a contributor agent from a prompt file."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

# Ensure the scripts directory is importable so domain modules resolve.
_scripts_dir = str(Path(__file__).resolve().parent)
if _scripts_dir not in sys.path:
    sys.path.insert(0, _scripts_dir)

# ---------------------------------------------------------------------------
# Re-export everything from domain modules so existing callers that load this
# file as a module (via importlib.util.spec_from_file_location) still find
# every symbol at the top level.
# ---------------------------------------------------------------------------

from _helpers import (  # noqa: E402, F401
    AGENT_CLAIM_LABEL,
    AGENT_CLAIM_LABEL_COLOR,
    AGENT_CLAIM_LABEL_DESCRIPTION,
    AGENT_MERGEABLE_LABEL,
    AGENT_MERGEABLE_LABEL_COLOR,
    AGENT_MERGEABLE_LABEL_DESCRIPTION,
    AGENT_READY_LABEL,
    AGENT_READY_LABEL_COLOR,
    AGENT_READY_LABEL_DESCRIPTION,
    CLAUDE_TIMEOUT,
    GH_DISCUSS_SCRIPT,
    GITHUB_API_TIMEOUT,
    REPO_ROOT,
    SKILL_ROOT,
    VALIDATION_TIMEOUT,
    VALIDATOR_SCRIPT,
    _normalize_login,
    _parse_timestamp,
    branch_name_for_issue,
    extract_persona,
    has_markdown_section,
    insert_markdown_section,
    issue_label_names,
    issue_label_presence,
    log,
    markdown_section,
    normalize_provider_env,
    persona_slug,
    require_env,
    run_checked,
    run_optional,
    short_persona_name,
    slugify,
    strip_markdown_section,
)

from evidence import (  # noqa: E402, F401
    EVIDENCE_FALLBACK_SENTENCE,
    EVIDENCE_METADATA_RE,
    EVIDENCE_METADATA_VERSION,
    EVIDENCE_STATUS_LINE_RE,
    STRUCTURED_EVIDENCE_UPDATE_RE,
    SWIFT_TEST_NO_MATCH_TEXT,
    _evidence_item_kind,
    _explicit_evidence_contract,
    _extract_evidence_metadata,
    _extract_test_commands,
    _format_uploaded_evidence_links,
    _insert_evidence_metadata,
    _latest_evidence_metadata_match,
    _listed_swift_tests,
    _match_evidence_entry,
    _needs_macos_evidence,
    _needs_screenshot_evidence,
    _normalize_evidence_item,
    _normalize_evidence_key,
    _pending_ci_resolution,
    _selector_matches_test_list,
    _structured_evidence_entries,
    _swift_test_filter_selector,
    _test_output_by_command,
    _test_output_has_no_matching_tests,
    evaluate_evidence_accounting,
    extract_evidence_status_entries,
    extract_requested_evidence,
    format_requested_evidence_numbered,
    parse_structured_evidence_updates,
    reconcile_pending_ci_evidence,
    render_execution_summary_body,
    review_evidence_gate_error,
    summarize_evidence_accounting_by_index,
    summarize_requested_evidence,
    validate_evidence_accounting,
    validate_requested_test_commands,
)

from github_state import (  # noqa: E402, F401
    CLAIM_MARKER_RE,
    CLOSING_REFERENCE_RE,
    EXECUTION_PRIORITY_RE,
    HISTORY_QUERY,
    PETER_PLANNED_MARKER_RE,
    PR_MARKER_RE,
    STALE_CLAIM_HOURS,
    TASK_ISSUE_MARKER_RE,
    WORK_STATE_QUERY,
    claim_is_stale,
    current_branch,
    default_branch,
    detect_bot_login,
    discussion_execution_status,
    extract_blocked_by,
    extract_execution_priority,
    extract_issue_discussion_number,
    extract_pr_issue_reference,
    fetch_issue_state_map,
    fetch_work_state,
    find_issue_execution_state,
    find_pr_review_state,
    latest_issue_claim,
    latest_planned_comment,
    planned_comment_has_owner_approval,
    repo_owner_name,
)

from triage import (  # noqa: E402, F401
    DISCUSSION_WIP_CAP,
    ENGAGEMENT_RECENT_HOURS,
    ISSUE_WIP_CAP,
    LOW_COMMENT_THRESHOLD,
    STALE_DISCUSSION_DAYS,
    _find_agent_threads,
    _has_persona,
    build_engagement_retry_message,
    classify_execution_work,
    compute_wip_state,
    find_discussions_needing_engagement,
    find_prs_awaiting_rereview,
    format_claimed_issues,
    format_engagement_candidates,
    format_issue_list_for_context,
    format_open_discussions,
    format_own_open_prs,
    format_pr_list_for_context,
    format_ready_issues,
    format_review_excerpt,
    format_wip_state,
    gather_agent_history,
    gather_backlog_state,
    gather_context,
    latest_external_review,
    maybe_block_new_proposal,
    runner_platform_note,
)

from execution import (  # noqa: E402, F401
    _update_mergeable_label,
    _write_github_outputs,
    build_body,
    build_execution_summary_body,
    claim_marker,
    compose_claim_comment,
    compose_pr_body,
    ensure_claim_label,
    ensure_issue_claimed,
    ensure_label_exists,
    pr_marker,
    route_action,
    route_execution_action,
    set_git_identity,
    validate_output,
    working_tree_dirty,
)

# ---------------------------------------------------------------------------
# Constants and helpers used only by main()
# ---------------------------------------------------------------------------

CLAUDE_TASK = (
    "Check what needs attention: open PRs to review, then your own open PRs "
    "or claimed issues to advance, then execution-approved issues to pick up, "
    "then discussions to participate in or propose. When you execute an issue or advance your own PR, "
    "reference requested evidence by index in frontmatter and let the runtime render `## Evidence Status`. "
    "When you review a PR, approvals are only allowed if requested evidence is fully accounted for and unblocked. Output your response "
    "using YAML frontmatter as specified in your prompt."
)
CLAUDE_TASK_CLI = (
    "You are running as an automated contributor. FIRST check if any PRs "
    "need your follow-up review (you reviewed but didn't approve, and new "
    "commits were pushed since). Then review other open PRs, then continue "
    "your own open PRs or claimed issues, then claim an execution-approved "
    "ready issue if one exists, then close stale discussions if the WIP cap "
    "is near or reached, then participate in discussions — comment on "
    "an existing one or propose a new idea (but NOT if the discussion WIP "
    "cap is reached). CRITICAL: when you execute an issue or advance your own PR, "
    "use the requested evidence indexes from context in frontmatter and let the runtime render "
    "`## Evidence Status`; reviews must not "
    "approve PRs with missing or blocked requested evidence. Your final output MUST "
    "be valid YAML frontmatter exactly as specified in your prompt — start "
    "with `---` on the very first line, then metadata fields, then closing "
    "`---`, then your markdown body. Do NOT write any text before the "
    "opening `---`."
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prompt-file", required=True, type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--mode", choices=["cli", "print"], default="cli")
    parser.add_argument("--message", type=str, default="",
                        help="Directed task — overrides periodic priority order")
    return parser.parse_args()


def run_claude(
    prompt_file: Path, context: str, env: dict[str, str],
    *, mode: str = "cli", message: str = "",
) -> str:
    log(f"Running Claude Code with {prompt_file} (mode={mode})")
    if message:
        log(f"Directed task: {message[:80]}")
        task = (
            f"DIRECTED TASK (highest priority — do this instead of your normal priority "
            f"order): {message}\n\n"
            f"CRITICAL: Your final output MUST be valid YAML frontmatter exactly as "
            f"specified in your prompt — start with `---` on the very first line, then "
            f"metadata fields, then closing `---`, then your markdown body. Do NOT write "
            f"any text before the opening `---`."
        )
    else:
        task = CLAUDE_TASK_CLI if mode == "cli" else CLAUDE_TASK
    cmd = [
        "npx",
        "--yes",
        "@anthropic-ai/claude-code",
        "--print",
        "--system-prompt",
        prompt_file.read_text(),
        "--append-system-prompt",
        context,
    ]
    timeout = CLAUDE_TIMEOUT
    if mode == "cli":
        cmd.extend([
            "--permission-mode", "bypassPermissions",
            "--tools",
            "Read,Grep,Glob,Edit,Write,MultiEdit,Bash(git:*),Bash(gh:*),Bash(uv:*),Bash(swift:*),Bash(mise:*),Bash(./scripts/*),Bash(xcodebuild:*)",
            "--max-budget-usd", "2.50",
        ])
        timeout = 1200
    cmd.append(task)
    return run_checked(cmd, timeout=timeout, cwd=REPO_ROOT, env=env).stdout


def main() -> int:
    args = parse_args()
    prompt_file = args.prompt_file.resolve()
    if not prompt_file.is_file():
        print(f"error: prompt file not found: {prompt_file}", file=sys.stderr)
        return 1

    require_env("CLAUDE_CODE_OAUTH_TOKEN")
    require_env("GH_TOKEN")
    env = normalize_provider_env(dict(os.environ))

    persona = extract_persona(prompt_file)
    bot_login = detect_bot_login(env)
    if bot_login:
        log(f"Authenticated as {bot_login}")
    context, engagement_candidates, wip_state = gather_context(env, persona=persona, bot_login=bot_login)
    raw_output = run_claude(prompt_file, context, env, mode=args.mode, message=args.message)
    exit_code, validated_json, error_text = validate_output(raw_output, env)

    if exit_code == 2 and error_text.startswith("duplicate:"):
        log("Skipping duplicate proposal")
        return 0
    if exit_code != 0 or validated_json is None:
        print("--- Raw output ---", file=sys.stderr)
        print(raw_output, file=sys.stderr)
        return 1

    if not args.message:
        blocked_candidate = maybe_block_new_proposal(
            validated_json,
            engagement_candidates,
            discussions_at_cap=bool(wip_state.get("discussions_at_cap")),
        )
        if blocked_candidate is not None:
            log(
                "Blocking new proposal because existing discussions need engagement: "
                f"#{blocked_candidate['number']}"
            )
            retry_message = build_engagement_retry_message(blocked_candidate)
            raw_output = run_claude(
                prompt_file,
                context,
                env,
                mode=args.mode,
                message=retry_message,
            )
            exit_code, validated_json, error_text = validate_output(raw_output, env)
            if exit_code != 0 or validated_json is None:
                print("--- Raw output ---", file=sys.stderr)
                print(raw_output, file=sys.stderr)
                return 1
            if json.loads(validated_json).get("action") == "propose":
                print(
                    "error: contributor proposed a new idea despite engagement policy",
                    file=sys.stderr,
                )
                print("--- Raw output ---", file=sys.stderr)
                print(raw_output, file=sys.stderr)
                return 1

    result = route_action(validated_json, args.dry_run, env)
    if result == 0:
        log("Completed successfully")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
