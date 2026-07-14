"""Shared privileged-path and issue-scope policy for contributor dispatches."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path
from pathlib import PurePosixPath


REPO_ROOT = Path(__file__).resolve().parents[4]
REPO_SCRIPTS = REPO_ROOT / "scripts"
if str(REPO_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(REPO_SCRIPTS))

from release_policy import RELEASE_PATHS  # noqa: E402


SENSITIVE_PATH_PREFIXES = (
    ".github/",
    ".agents/",
)
SENSITIVE_RELEASE_SCRIPT_PATHS = RELEASE_PATHS | {
    "scripts/signing-config.sh.template",
    "scripts/validate-release-changes.py",
}
SENSITIVE_NAME_MARKERS = (
    "auth",
    "credential",
    "entitlement",
    "keychain",
    "secret",
    "sandbox",
    "signing",
    "token",
)
MARKDOWN_DESTINATION_RE = re.compile(r"\]\((?P<path>[^)\s]+)\)")
CODE_SPAN_RE = re.compile(r"`(?P<path>[^`\n]+)`")
PLAIN_PATH_RE = re.compile(
    r"(?<![A-Za-z0-9_.-])"
    r"(?P<path>(?:\.{0,2}/)?(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.[A-Za-z0-9_.-]+)"
)


def _normal_patch_path(path: str) -> str | None:
    normalized = path.strip().replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    candidate = PurePosixPath(normalized)
    if not normalized or candidate.is_absolute() or ".." in candidate.parts:
        return None
    return candidate.as_posix()


def sensitive_agent_patch_paths(changed_files: list[str]) -> list[str]:
    sensitive: list[str] = []
    for raw_path in changed_files:
        rel_path = _normal_patch_path(raw_path)
        if rel_path is None:
            sensitive.append(raw_path)
            continue
        lower_path = rel_path.casefold()
        lower_parts = PurePosixPath(lower_path).parts

        if lower_path.endswith(".entitlements"):
            sensitive.append(rel_path)
            continue
        if lower_path in SENSITIVE_RELEASE_SCRIPT_PATHS:
            sensitive.append(rel_path)
            continue
        if any(
            lower_path == prefix.rstrip("/") or lower_path.startswith(prefix)
            for prefix in SENSITIVE_PATH_PREFIXES
        ):
            sensitive.append(rel_path)
            continue
        if any(marker in part for part in lower_parts for marker in SENSITIVE_NAME_MARKERS):
            sensitive.append(rel_path)
            continue
        if lower_path.startswith("infra/") and any(
            marker in part
            for part in lower_parts
            for marker in ("credential", "secret", "token", "key")
        ):
            sensitive.append(rel_path)
    return sensitive


def issue_body_path_candidates(body: str) -> list[str]:
    """Extract path-shaped issue text without trusting Markdown punctuation."""

    candidates: list[str] = []
    for pattern in (MARKDOWN_DESTINATION_RE, CODE_SPAN_RE, PLAIN_PATH_RE):
        for match in pattern.finditer(body):
            raw_path = match.group("path").strip("'\"()[]{}<>,:;!?")
            normalized = _normal_patch_path(raw_path)
            if normalized is not None and normalized not in candidates:
                candidates.append(normalized)
    return candidates


def issue_scope_digest(issue: dict[str, object]) -> str:
    payload = {
        "body": str(issue.get("body") or ""),
        "number": int(issue.get("number") or 0),
        "title": str(issue.get("title") or ""),
    }
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()
