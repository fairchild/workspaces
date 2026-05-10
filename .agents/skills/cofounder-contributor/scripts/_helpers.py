"""Shared helpers for contributor runtime modules."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
SKILL_ROOT = Path(__file__).resolve().parents[1]
GH_DISCUSS_SCRIPT = REPO_ROOT / ".agents" / "skills" / "gh-discuss" / "scripts" / "gh-discuss.py"
VALIDATOR_SCRIPT = SKILL_ROOT / "scripts" / "validate-agent-output.py"

GITHUB_API_TIMEOUT = 30
CLAUDE_TIMEOUT = 300
VALIDATION_TIMEOUT = 30

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


def markdown_section(body: str, heading: str) -> str:
    pattern = rf"(?ms)^## {re.escape(heading)}\n(.*?)(?=^## |\n---\n|\Z)"
    match = re.search(pattern, body)
    if not match:
        return ""
    return match.group(1).strip()


def has_markdown_section(body: str, heading: str) -> bool:
    return re.search(rf"(?m)^## {re.escape(heading)}\s*$", body) is not None


def strip_markdown_section(body: str, heading: str) -> str:
    pattern = rf"(?ms)^## {re.escape(heading)}\n.*?(?=^## |\n---\n|\Z)"
    stripped = re.sub(pattern, "", body).strip()
    return re.sub(r"\n{3,}", "\n\n", stripped)


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
        pattern = rf"(?m)^## {re.escape(before_heading)}\s*$"
        return re.sub(pattern, f"{section}\n\n## {before_heading}", cleaned, count=1)
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
