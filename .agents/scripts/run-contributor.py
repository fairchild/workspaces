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
import subprocess
import sys
import tempfile
from pathlib import Path


CLAUDE_TASK = (
    "Check what needs attention first (open PRs, in-progress issues, recent discussion "
    "comments), then propose a new idea only if nothing else needs you. Output your "
    "response using YAML frontmatter as specified in your prompt."
)
CLAUDE_TASK_CLI = (
    "You are running as an automated contributor. Check what needs attention "
    "(open PRs, in-progress issues, recent discussion comments), then act on "
    "the highest-priority item. CRITICAL: Your final output MUST be valid "
    "YAML frontmatter exactly as specified in your prompt — start with `---` "
    "on the very first line, then metadata fields, then closing `---`, then "
    "your markdown body. Do NOT write any text before the opening `---`."
)
REPO_ROOT = Path(__file__).resolve().parents[2]
GH_DISCUSS_SCRIPT = REPO_ROOT / ".agents" / "skills" / "gh-discuss" / "scripts" / "gh-discuss.py"
VALIDATOR_SCRIPT = REPO_ROOT / ".agents" / "scripts" / "validate-agent-output.py"

# Timeouts (seconds) — every external call must declare its budget
GITHUB_API_TIMEOUT = 30
CLAUDE_TIMEOUT = 300
VALIDATION_TIMEOUT = 30


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prompt-file", required=True, type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--mode", choices=["cli", "print"], default="cli")
    return parser.parse_args()


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if value:
        return value
    print(f"error: required environment variable {name} is not set", file=sys.stderr)
    sys.exit(1)


def log(message: str) -> None:
    print(f"[run-contributor] {message}", file=sys.stderr)


def run_checked(
    cmd: list[str],
    *,
    timeout: int,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input: str | None = None,
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
        sys.exit(1)
    if result.returncode != 0:
        command = " ".join(cmd)
        print(f"error: command failed: {command}", file=sys.stderr)
        if result.stderr.strip():
            print(result.stderr.strip(), file=sys.stderr)
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


def repo_owner_name(env: dict[str, str]) -> tuple[str, str]:
    slug = env.get("GITHUB_REPOSITORY", "").strip()
    if slug and "/" in slug:
        owner, name = slug.split("/", 1)
        return owner, name

    result = run_checked(
        ["gh", "repo", "view", "--json", "owner,name"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )
    data = json.loads(result.stdout)
    return data["owner"]["login"], data["name"]


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


def gather_context(env: dict[str, str]) -> str:
    log("Gathering context")
    owner, name = repo_owner_name(env)

    recent_commits = run_checked(
        ["git", "log", "--oneline", "--since=2 weeks ago"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    ).stdout.rstrip()

    discussions_query = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    discussions(first: 30, states: OPEN) {
      nodes {
        number title
        category { name }
        author { login }
        comments(first: 5) {
          nodes { body author { login } }
          totalCount
        }
      }
    }
  }
}
"""
    discussions = run_optional(
        [
            "gh",
            "api",
            "graphql",
            "-f",
            f"query={discussions_query}",
            "-f",
            f"owner={owner}",
            "-f",
            f"name={name}",
            "--jq",
            (
                '.data.repository.discussions.nodes[] | '
                '"#\\(.number) [\\(.category.name)] \\(.title) '
                '(\\(.comments.totalCount) comments)'
                '\\(.comments.nodes[:2] | map("\\n  -> \\(.author.login): '
                '\\(.body[:200] | gsub(\\"\\n\\";\\" \\"))") | join(""))"'
            ),
        ],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    ).rstrip()

    open_issues = run_optional(
        [
            "gh",
            "issue",
            "list",
            "--state",
            "open",
            "--limit",
            "20",
            "--json",
            "number,title,state,labels,assignees",
        ],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="[]\n",
    ).rstrip()

    open_prs = run_optional(
        [
            "gh",
            "pr",
            "list",
            "--state",
            "open",
            "--limit",
            "10",
            "--json",
            "number,title,author,isDraft,reviewDecision",
        ],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="[]\n",
    ).rstrip()

    backlog_state = gather_backlog_state()
    return (
        "Recent commits (last 2 weeks):\n"
        f"{recent_commits}\n\n"
        "Open discussions:\n"
        f"{discussions}\n\n"
        "Open issues:\n"
        f"{open_issues}\n\n"
        "Open PRs:\n"
        f"{open_prs}\n\n"
        "Backlog state:\n"
        f"{backlog_state}"
    )


def run_claude(prompt_file: Path, context: str, env: dict[str, str], *, mode: str = "cli") -> str:
    log(f"Running Claude Code with {prompt_file} (mode={mode})")
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
            "--tools", "Read,Grep,Glob,Bash(git:*),Bash(gh:*),Bash(uv:*)",
            "--max-budget-usd", "1.00",
        ])
        timeout = 600
    cmd.append(task)
    return run_checked(cmd, timeout=timeout, cwd=REPO_ROOT, env=env).stdout


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


def build_body(data: dict[str, object]) -> str:
    persona = str(data.get("persona", ""))
    body = str(data.get("body", ""))
    if data["action"] == "propose":
        return f"*Proposed by {persona}*\n\n{body}"
    return f"*{persona}*\n\n{body}"


def route_action(validated_json: str, dry_run: bool, env: dict[str, str]) -> int:
    data = json.loads(validated_json)
    action = data["action"]

    if dry_run:
        log(f"Dry run; action={action}")
        print(json.dumps(data, indent=2, ensure_ascii=False))
        return 0

    log(f"Routing action {action}")
    body = build_body(data)

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

    try:
        if action == "review_pr":
            run_checked(
                [
                    "gh",
                    "pr",
                    "review",
                    str(data["pr_number"]),
                    "--comment",
                    "--body-file",
                    body_file,
                ],
                timeout=GITHUB_API_TIMEOUT,
                cwd=REPO_ROOT,
                env=env,
            )
            return 0
        if action == "advance_issue":
            run_checked(
                [
                    "gh",
                    "issue",
                    "comment",
                    str(data["issue_number"]),
                    "--body-file",
                    body_file,
                ],
                timeout=GITHUB_API_TIMEOUT,
                cwd=REPO_ROOT,
                env=env,
            )
            return 0
    finally:
        try:
            os.unlink(body_file)
        except OSError:
            pass

    print(f"error: unknown action: {action}", file=sys.stderr)
    return 1


def main() -> int:
    args = parse_args()
    prompt_file = args.prompt_file.resolve()
    if not prompt_file.is_file():
        print(f"error: prompt file not found: {prompt_file}", file=sys.stderr)
        return 1

    require_env("CLAUDE_CODE_OAUTH_TOKEN")
    require_env("GH_TOKEN")
    env = dict(os.environ)

    context = gather_context(env)
    raw_output = run_claude(prompt_file, context, env, mode=args.mode)
    exit_code, validated_json, error_text = validate_output(raw_output, env)

    if exit_code == 2 and error_text.startswith("duplicate:"):
        log("Skipping duplicate proposal")
        return 0
    if exit_code != 0 or validated_json is None:
        print("--- Raw output ---", file=sys.stderr)
        print(raw_output, file=sys.stderr)
        return 1

    result = route_action(validated_json, args.dry_run, env)
    if result == 0:
        log("Completed successfully")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
