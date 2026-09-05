#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "pyjwt[crypto]>=2.8",
# ]
# ///
"""Fetch Xcode Cloud build logs and issues for a commit via the App Store Connect API.

GitHub check-runs only carry Xcode Cloud's one-line failure summary; the real
script stdout/stderr lives in ASC LOG_BUNDLE artifacts. Requires a Team API key
with App Manager role: APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, and
APPLE_API_KEY_BASE64 (or APPLE_API_KEY_PATH).
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import time
import uuid
import zipfile
from pathlib import Path
from typing import Any, Iterator
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

import jwt

API_BASE = "https://api.appstoreconnect.apple.com"
INTERESTING_LOG = re.compile(r"post[_-]?clone|pre[_-]?xcodebuild|RunScript|ghosttykit", re.I)
FAILURE_LINE = re.compile(r"error|failed|fatal|No such file|command not found|sudo", re.I)
RUNTIME_FAILURE_LINE = re.compile(r"env:\s*uv:|command not found|No such file(?: or directory)?", re.I)
PRIMARY_FAILURE_LINE = re.compile(
    r"env:\s*uv:|command not found|No such file(?: or directory)?|fatal(?: error)?|error:|"
    r"recorded an issue|^.*✘ .*failed|^.*✘ Suite|^.*✘ Test run",
    re.I,
)
TAIL_LINES = 200
MAX_LINE_CHARS = 400
FAILURE_CONTEXT_LINES = 3
MAX_FAILURE_CONTEXTS = 20
SENSITIVE_VALUE = re.compile(
    r"(?i)\b(authorization\s*:\s*bearer|(?:api[_-]?key|token|password|secret)\s*[=:])\s*\S+"
)
DIAGNOSTIC_SCHEMA = 1
DIAGNOSTIC_REPOSITORY = "fairchild/workspaces"
DIAGNOSTIC_REPORT_NAME = "diagnostic-handoff.json"
MAX_DIAGNOSTIC_BYTES = 8 * 1024
MAX_DIAGNOSTIC_OBSERVATIONS = 20
MAX_GITHUB_RUN_ID = (1 << 53) - 1
MISSING_UV = re.compile(
    r"(?:env:\s*)?uv:\s*(?:No such file or directory|command not found)|"
    r"Required command not found:\s*uv",
    re.I,
)


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"error: {name} environment variable is required")
    return value


def mint_token() -> str:
    key_id = require_env("APPLE_API_KEY_ID")
    issuer = require_env("APPLE_API_ISSUER_ID")
    if key_b64 := os.environ.get("APPLE_API_KEY_BASE64"):
        key = base64.b64decode(key_b64)
    elif key_path := os.environ.get("APPLE_API_KEY_PATH"):
        key = Path(key_path).read_bytes()
    else:
        sys.exit("error: set APPLE_API_KEY_BASE64 or APPLE_API_KEY_PATH")
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def api_get(token: str, url: str) -> dict[str, Any]:
    req = Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urlopen(req) as resp:
            return json.load(resp)
    except HTTPError as err:
        body = err.read().decode("utf-8", "replace")[:2000]
        hint = ""
        if err.code == 401:
            hint = "\nhint: Xcode Cloud endpoints need a Team API key with the App Manager role (ASC > Users and Access > Integrations > Team Keys, issuer ID from that page)"
        sys.exit(f"error: GET {url} -> HTTP {err.code}\n{body}{hint}")


def paged(token: str, path: str, max_pages: int = 5, **params: str) -> Iterator[dict[str, Any]]:
    url = f"{API_BASE}{path}"
    if params:
        url += "?" + urlencode(params)
    for _ in range(max_pages):
        page = api_get(token, url)
        yield from page.get("data", [])
        url = page.get("links", {}).get("next")
        if not url:
            return
    print(f"note: stopped after {max_pages} pages of {path}; older entries were not searched", file=sys.stderr)


def commit_sha(run: dict[str, Any]) -> str:
    source = run.get("attributes", {}).get("sourceCommit") or {}
    return source.get("commitSha") or source.get("sha") or ""


def diagnostic_run_id(raw: str | None = None) -> int | None:
    """Return a safe Actions run ID, or None for ordinary local retrieval."""
    value = raw if raw is not None else os.environ.get("GITHUB_RUN_ID")
    if value is None or not value:
        return None
    if not value.isdecimal() or not 0 < int(value) <= MAX_GITHUB_RUN_ID:
        raise ValueError("diagnostic run ID must be a positive integer no larger than 2^53-1")
    return int(value)


def validate_callback_url(value: str) -> str:
    """Accept only a configured HTTPS origin with the fixed diagnostics path."""
    parsed = urlsplit(value)
    try:
        port = parsed.port
    except ValueError as err:
        raise ValueError("callback URL must not use an invalid port") from err
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or port is not None
        or parsed.path != "/api/diagnostics"
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("callback URL must be HTTPS without credentials, port, query, or fragment at /api/diagnostics")
    return value


def diagnostic_observation(build_id: str, action_id: str, sha: str, log: Path) -> dict[str, str] | None:
    """Return a trusted missing-uv observation for the exact downloaded log."""
    if log.name != "ci_pre_xcodebuild.log":
        return None
    try:
        canonical_build_id = str(uuid.UUID(build_id))
        canonical_action_id = str(uuid.UUID(action_id))
        contents = log.read_text(errors="replace")
    except (OSError, ValueError):
        return None
    if not re.fullmatch(r"[0-9a-f]{40}", sha, re.I) or not MISSING_UV.search(contents):
        return None
    return {
        "buildId": canonical_build_id,
        "actionId": canonical_action_id,
        "sha": sha.lower(),
        "signature": "missing-uv",
        "stage": "ci_pre_xcodebuild",
    }


def write_diagnostic_report(output_dir: Path, observations: list[dict[str, str]], run_id: int) -> Path:
    """Write the bounded, raw-log-free handoff used by a trusted collector."""
    report = {
        "schema": DIAGNOSTIC_SCHEMA,
        "repository": DIAGNOSTIC_REPOSITORY,
        "runId": run_id,
        "observations": observations[:MAX_DIAGNOSTIC_OBSERVATIONS],
    }
    encoded = json.dumps(report, sort_keys=True, separators=(",", ":")).encode()
    if len(encoded) > MAX_DIAGNOSTIC_BYTES:
        raise RuntimeError("diagnostic handoff exceeds its 8 KiB bound")
    output_dir.mkdir(parents=True, exist_ok=True)
    report_path = output_dir / DIAGNOSTIC_REPORT_NAME
    report_path.write_bytes(encoded + b"\n")
    return report_path


def find_build_runs(token: str, sha: str) -> list[dict[str, Any]]:
    sha = sha.lower()
    matches = []
    for product in paged(token, "/v1/ciProducts"):
        for run in paged(token, f"/v1/ciProducts/{product['id']}/buildRuns", limit="200"):
            if commit_sha(run).lower().startswith(sha) or sha in json.dumps(run).lower():
                matches.append(run)
    return matches


def slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-") or "unnamed"


def print_issues(token: str, action_id: str) -> None:
    for issue in paged(token, f"/v1/ciBuildActions/{action_id}/issues"):
        attrs = issue.get("attributes", {})
        source = attrs.get("fileSource") or {}
        location = f" [{source.get('path')}:{source.get('lineNumber')}]" if source.get("path") else ""
        print(f"    issue [{attrs.get('issueType')}/{attrs.get('category')}]{location}: {attrs.get('message')}")


def clip(line: str) -> str:
    line = SENSITIVE_VALUE.sub(r"\1 <redacted>", line)
    return line if len(line) <= MAX_LINE_CHARS else line[:MAX_LINE_CHARS] + " …[truncated]"


def failure_contexts(lines: list[str], *, before: int | None = None) -> list[tuple[int, int]]:
    """Return merged, bounded failure spans outside an optional trailing excerpt."""
    search_lines = lines if before is None else lines[:before]

    # Test names routinely contain words such as "error" and "failed". Prefer
    # runtime/tool failures first, then concrete failure records, and use broad
    # matching only when neither signal exists.
    runtime = [index for index, line in enumerate(search_lines) if RUNTIME_FAILURE_LINE.search(line)]
    primary = [index for index, line in enumerate(search_lines) if PRIMARY_FAILURE_LINE.search(line)]
    if runtime or primary:
        selected = runtime + [index for index in primary if index not in runtime]
    else:
        selected = [index for index, line in enumerate(search_lines) if FAILURE_LINE.search(line)]

    spans: list[tuple[int, int]] = []
    for index in sorted(selected):
        start = max(0, index - FAILURE_CONTEXT_LINES)
        end = min(len(lines), index + FAILURE_CONTEXT_LINES + 1)
        if spans and start <= spans[-1][1]:
            spans[-1] = (spans[-1][0], max(spans[-1][1], end))
            continue
        spans.append((start, end))
        if len(spans) == MAX_FAILURE_CONTEXTS:
            break
    return spans


def print_failure_contexts(path: Path, lines: list[str], *, before: int | None = None) -> None:
    contexts = failure_contexts(lines, before=before)
    if not contexts:
        return
    print(f"    ---- failure context (up to {MAX_FAILURE_CONTEXTS}) {path.name} ----")
    for start, end in contexts:
        for line_number, line in enumerate(lines[start:end], start=start + 1):
            print(f"    {path.name}:{line_number}: {clip(line)}")


def excerpt(path: Path) -> None:
    try:
        raw = path.read_bytes()
    except OSError as err:
        print(f"    (unreadable: {err})")
        return
    if b"\x00" in raw[:8192]:
        print(f"    (binary file skipped: {path.name})")
        return
    lines = raw.decode("utf-8", "replace").splitlines()
    interesting = path.name and INTERESTING_LOG.search(str(path))
    if interesting:
        # Xcode script logs can emit a decisive failure long before their final
        # diagnostic footer. Preserve a bounded context for those earlier hits
        # without duplicating the final tail or dumping the entire log.
        print_failure_contexts(path, lines, before=max(0, len(lines) - TAIL_LINES))
        print(f"    ---- tail -{TAIL_LINES} {path.name} ----")
        for line in lines[-TAIL_LINES:]:
            print(f"    {clip(line)}")
    else:
        hits = [line for line in lines if FAILURE_LINE.search(line)][:40]
        for line in hits:
            print(f"    {path.name}: {clip(line)}")


def download_artifacts(
    token: str,
    action_id: str,
    dest: Path,
    *,
    build_id: str,
    sha: str,
    observations: list[dict[str, str]],
) -> None:
    for artifact in paged(token, f"/v1/ciBuildActions/{action_id}/artifacts"):
        attrs = artifact.get("attributes", {})
        file_type, file_name = attrs.get("fileType", ""), attrs.get("fileName", "artifact")
        print(f"    artifact: {file_type} {file_name} ({attrs.get('fileSize')} bytes)")
        if "LOG" not in file_type.upper():
            continue
        url = attrs.get("downloadUrl")
        if not url:
            print("      (no downloadUrl)")
            continue
        dest.mkdir(parents=True, exist_ok=True)
        target = dest / slug(file_name)
        with urlopen(Request(url)) as resp:
            target.write_bytes(resp.read())
        if zipfile.is_zipfile(target):
            # A distinct suffix, not with_suffix(""): a suffixless fileName
            # would otherwise collide with the downloaded archive itself.
            extract_dir = target.with_name(target.name + ".extracted")
            with zipfile.ZipFile(target) as bundle:
                bundle.extractall(extract_dir)
            for member in sorted(extract_dir.rglob("*")):
                if member.is_file():
                    print(f"      extracted: {member.relative_to(dest)}")
                    excerpt(member)
                    observation = diagnostic_observation(build_id, action_id, sha, member)
                    if observation and observation not in observations:
                        observations.append(observation)
        else:
            excerpt(target)
            observation = diagnostic_observation(build_id, action_id, sha, target)
            if observation and observation not in observations:
                observations.append(observation)


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch Xcode Cloud logs for a commit")
    parser.add_argument("--sha", help="Commit SHA (prefix ok) to look up")
    parser.add_argument("--out", type=Path, default=Path("xcode-cloud-logs"), help="Download directory")
    parser.add_argument("--diagnostic-run-id", help="Positive GitHub Actions run ID for local diagnostic handoff")
    parser.add_argument("--validate-callback-url", help="Validate a configured diagnostics callback URL and exit")
    args = parser.parse_args()

    if args.validate_callback_url:
        try:
            print(validate_callback_url(args.validate_callback_url))
        except ValueError as err:
            parser.error(str(err))
        return 0
    if not args.sha:
        parser.error("--sha is required unless --validate-callback-url is used")

    token = mint_token()
    runs = find_build_runs(token, args.sha)
    if not runs:
        print(f"no Xcode Cloud build runs found for {args.sha}", file=sys.stderr)
        return 2

    observations: list[dict[str, str]] = []
    for run in runs:
        attrs = run.get("attributes", {})
        print(
            f"build run #{attrs.get('number')} ({run['id']}): "
            f"{attrs.get('executionProgress')}/{attrs.get('completionStatus')} "
            f"commit={commit_sha(run)[:12]} started={attrs.get('startedDate')}"
        )
        for action in paged(token, f"/v1/ciBuildRuns/{run['id']}/actions"):
            a_attrs = action.get("attributes", {})
            name = a_attrs.get("name", "action")
            print(f"  action {name} [{a_attrs.get('actionType')}]: {a_attrs.get('completionStatus')}")
            print_issues(token, action["id"])
            download_artifacts(
                token,
                action["id"],
                args.out / f"run-{attrs.get('number')}" / slug(name),
                build_id=run["id"],
                sha=commit_sha(run),
                observations=observations,
            )
    try:
        run_id = diagnostic_run_id(args.diagnostic_run_id)
    except ValueError as err:
        parser.error(str(err))
    if run_id is None:
        print("note: no GITHUB_RUN_ID or --diagnostic-run-id; diagnostic handoff not emitted", file=sys.stderr)
        return 0
    report_path = write_diagnostic_report(args.out, observations, run_id)
    print(f"diagnostic handoff: {report_path} ({len(observations)} observations)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
