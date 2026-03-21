#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Create a Codespace, upload a Claude request, and run the Claude worker."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib import error, request


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REQUEST_ROOT = ".context/codespaces-claude-worker"
DEFAULT_API_URL = "https://api.github.com"


class CodespacesClaudeLaunchError(RuntimeError):
    """Raised when the launcher cannot complete."""


@dataclass(frozen=True)
class LaunchOptions:
    repo: str
    ref: str
    prompt: str | None
    prompt_file: Path | None
    machine: str | None
    keep_running: bool
    max_turns: int
    idle_timeout_minutes: int
    retention_minutes: int
    run_id: str
    display_name_prefix: str
    request_root: str
    output_json: Path | None
    api_url: str
    ready_timeout_seconds: int
    poll_interval_seconds: int


@dataclass(frozen=True)
class RemotePaths:
    repo_root: str
    request_dir: str
    request_file: str
    worker_script: str


def parse_args() -> LaunchOptions:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "").strip())
    parser.add_argument(
        "--ref",
        default=os.environ.get("GITHUB_REF_NAME", "").strip() or "main",
    )
    parser.add_argument("--prompt")
    parser.add_argument("--prompt-file", type=Path)
    parser.add_argument("--machine")
    parser.add_argument("--keep-running", action="store_true")
    parser.add_argument("--max-turns", type=int, default=20)
    parser.add_argument("--idle-timeout-minutes", type=int, default=30)
    parser.add_argument("--retention-minutes", type=int, default=60 * 24)
    parser.add_argument(
        "--run-id",
        default=os.environ.get("GITHUB_RUN_ID", "").strip() or default_run_id(),
    )
    parser.add_argument("--display-name-prefix", default="claude-worker")
    parser.add_argument("--request-root", default=DEFAULT_REQUEST_ROOT)
    parser.add_argument("--output-json", type=Path)
    parser.add_argument("--api-url", default=os.environ.get("GITHUB_API_URL", DEFAULT_API_URL))
    parser.add_argument("--ready-timeout-seconds", type=int, default=15 * 60)
    parser.add_argument("--poll-interval-seconds", type=int, default=5)
    args = parser.parse_args()
    return validate_args(
        LaunchOptions(
            repo=args.repo,
            ref=args.ref,
            prompt=args.prompt,
            prompt_file=args.prompt_file,
            machine=args.machine,
            keep_running=args.keep_running,
            max_turns=args.max_turns,
            idle_timeout_minutes=args.idle_timeout_minutes,
            retention_minutes=args.retention_minutes,
            run_id=args.run_id,
            display_name_prefix=args.display_name_prefix,
            request_root=args.request_root,
            output_json=args.output_json,
            api_url=args.api_url,
            ready_timeout_seconds=args.ready_timeout_seconds,
            poll_interval_seconds=args.poll_interval_seconds,
        )
    )


def default_run_id() -> str:
    timestamp = datetime.now(tz=UTC).strftime("%Y%m%d%H%M%S")
    return f"manual-{timestamp}"


def validate_args(options: LaunchOptions) -> LaunchOptions:
    if not options.repo or "/" not in options.repo:
        raise CodespacesClaudeLaunchError("--repo must be set to owner/name")
    if not options.ref.strip():
        raise CodespacesClaudeLaunchError("--ref must not be empty")
    if options.prompt_file is None and not (options.prompt or "").strip():
        raise CodespacesClaudeLaunchError("provide --prompt, --prompt-file, or both")
    if options.prompt_file is not None and not options.prompt_file.is_file():
        raise CodespacesClaudeLaunchError(f"prompt file does not exist: {options.prompt_file}")
    if options.max_turns <= 0:
        raise CodespacesClaudeLaunchError("--max-turns must be a positive integer")
    if options.idle_timeout_minutes <= 0:
        raise CodespacesClaudeLaunchError("--idle-timeout-minutes must be positive")
    if options.retention_minutes <= 0:
        raise CodespacesClaudeLaunchError("--retention-minutes must be positive")
    if options.ready_timeout_seconds <= 0:
        raise CodespacesClaudeLaunchError("--ready-timeout-seconds must be positive")
    if options.poll_interval_seconds <= 0:
        raise CodespacesClaudeLaunchError("--poll-interval-seconds must be positive")
    return options


def log(message: str) -> None:
    print(f"[codespaces-claude-launch] {message}", file=sys.stderr)


def require_command(name: str) -> None:
    if shutil.which(name) is None:
        raise CodespacesClaudeLaunchError(f"missing required command: {name}")


def resolve_github_token(env: dict[str, str]) -> str:
    token = env.get("CODESPACES_WORKER_GITHUB_TOKEN", "").strip() or env.get("GH_TOKEN", "").strip()
    if not token:
        raise CodespacesClaudeLaunchError(
            "missing GitHub token; set CODESPACES_WORKER_GITHUB_TOKEN or GH_TOKEN"
        )
    return token


def build_request_markdown(prompt: str | None, prompt_file: Path | None) -> str:
    sections: list[str] = []
    if prompt and prompt.strip():
        sections.append(prompt.strip())
    if prompt_file is not None:
        sections.append(prompt_file.read_text(encoding="utf-8").strip())
    text = "\n\n".join(section for section in sections if section)
    if not text:
        raise CodespacesClaudeLaunchError("request content resolved to an empty string")
    return text.rstrip() + "\n"


def sanitize_display_name(value: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9-]+", "-", value).strip("-")
    return normalized.lower() or "claude-worker"


def build_display_name(prefix: str, run_id: str) -> str:
    return sanitize_display_name(f"{prefix}-{run_id}")[:64]


def build_create_payload(options: LaunchOptions) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "ref": options.ref,
        "display_name": build_display_name(options.display_name_prefix, options.run_id),
        "retention_period_minutes": options.retention_minutes,
        "idle_timeout_minutes": options.idle_timeout_minutes,
        "devcontainer_path": ".devcontainer/devcontainer.json",
    }
    if options.machine:
        payload["machine"] = options.machine
    return payload


def remote_paths(repo: str, request_root: str, run_id: str) -> RemotePaths:
    repo_name = repo.split("/", 1)[1]
    repo_root = f"/workspaces/{repo_name}"
    request_dir = f"{repo_root}/{request_root}/{run_id}"
    return RemotePaths(
        repo_root=repo_root,
        request_dir=request_dir,
        request_file=f"{request_dir}/request.md",
        worker_script=f"{repo_root}/scripts/codespaces-claude-worker.sh",
    )


def build_remote_launch_command(paths: RemotePaths, run_id: str, max_turns: int) -> str:
    return " ".join(
        [
            f"cd {shlex.quote(paths.repo_root)}",
            "&&",
            shlex.quote(paths.worker_script),
            "--run-id",
            shlex.quote(run_id),
            "--request-file",
            shlex.quote(paths.request_file),
            "--max-turns",
            str(max_turns),
        ]
    )


def github_api_request(
    method: str,
    api_url: str,
    path: str,
    token: str,
    *,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    body = None
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "User-Agent": "workspaces-codespaces-claude-launch",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = request.Request(f"{api_url.rstrip('/')}{path}", data=body, headers=headers, method=method)
    try:
        with request.urlopen(req) as response:
            raw = response.read().decode("utf-8")
    except error.HTTPError as exc:
        message = exc.read().decode("utf-8", errors="replace")
        raise CodespacesClaudeLaunchError(
            f"GitHub API {method} {path} failed with {exc.code}: {message}"
        ) from exc
    except error.URLError as exc:
        raise CodespacesClaudeLaunchError(f"GitHub API {method} {path} failed: {exc}") from exc
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise CodespacesClaudeLaunchError(f"GitHub API returned invalid JSON for {path}") from exc


def create_codespace(options: LaunchOptions, token: str) -> dict[str, Any]:
    owner, repo_name = options.repo.split("/", 1)
    return github_api_request(
        "POST",
        options.api_url,
        f"/repos/{owner}/{repo_name}/codespaces",
        token,
        payload=build_create_payload(options),
    )


def get_codespace(options: LaunchOptions, token: str, codespace_name: str) -> dict[str, Any]:
    return github_api_request(
        "GET",
        options.api_url,
        f"/user/codespaces/{codespace_name}",
        token,
    )


def wait_for_codespace(options: LaunchOptions, token: str, codespace_name: str) -> dict[str, Any]:
    deadline = time.time() + options.ready_timeout_seconds
    last_state = "unknown"
    while time.time() < deadline:
        details = get_codespace(options, token, codespace_name)
        state = str(details.get("state", "unknown"))
        if state != last_state:
            log(f"codespace {codespace_name} state={state}")
            last_state = state
        if state.lower() == "available":
            return details
        time.sleep(options.poll_interval_seconds)
    raise CodespacesClaudeLaunchError(
        f"timed out waiting for codespace {codespace_name} to become Available (last state={last_state})"
    )


def run_checked(
    cmd: list[str],
    *,
    env: dict[str, str],
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        env=env,
        input=input_text,
    )
    if result.returncode != 0:
        rendered = shlex.join(cmd)
        details = (result.stderr or result.stdout).strip() or "unknown error"
        raise CodespacesClaudeLaunchError(f"command failed ({rendered}): {details}")
    return result


def gh_env(token: str) -> dict[str, str]:
    env = os.environ.copy()
    env["GH_TOKEN"] = token
    return env


def ensure_remote_request_dir(codespace_name: str, paths: RemotePaths, token: str) -> None:
    run_checked(
        [
            "gh",
            "codespace",
            "ssh",
            "-c",
            codespace_name,
            "--",
            "bash",
            "-lc",
            f"mkdir -p {shlex.quote(paths.request_dir)}",
        ],
        env=gh_env(token),
    )


def upload_request(codespace_name: str, remote_request_path: str, request_text: str, token: str) -> None:
    with tempfile.TemporaryDirectory(prefix="codespaces-claude-request-") as temp_dir:
        local_request = Path(temp_dir) / "request.md"
        local_request.write_text(request_text, encoding="utf-8")
        run_checked(
            [
                "gh",
                "codespace",
                "cp",
                "-c",
                codespace_name,
                "-e",
                str(local_request),
                f"remote:{remote_request_path}",
            ],
            env=gh_env(token),
        )


def launch_remote_worker(
    codespace_name: str,
    paths: RemotePaths,
    run_id: str,
    max_turns: int,
    token: str,
) -> None:
    command = build_remote_launch_command(paths, run_id, max_turns)
    run_checked(
        [
            "gh",
            "codespace",
            "ssh",
            "-c",
            codespace_name,
            "--",
            "bash",
            "-lc",
            command,
        ],
        env=gh_env(token),
    )


def stop_codespace(codespace_name: str, token: str) -> None:
    run_checked(
        ["gh", "codespace", "stop", "-c", codespace_name],
        env=gh_env(token),
    )


def write_output(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def summarize_result(codespace: dict[str, Any], *, stopped: bool, paths: RemotePaths, run_id: str) -> dict[str, Any]:
    return {
        "codespace_name": codespace.get("name"),
        "codespace_state": codespace.get("state"),
        "codespace_url": codespace.get("web_url"),
        "run_id": run_id,
        "request_file": paths.request_file,
        "result_dir": f"{paths.request_dir}",
        "stopped_after_run": stopped,
    }


def main() -> int:
    try:
        options = parse_args()
        require_command("gh")
        token = resolve_github_token(os.environ)
        request_text = build_request_markdown(options.prompt, options.prompt_file)

        log(f"creating codespace for {options.repo}@{options.ref}")
        created = create_codespace(options, token)
        codespace_name = str(created.get("name", "")).strip()
        if not codespace_name:
            raise CodespacesClaudeLaunchError("GitHub create codespace response did not include a name")

        codespace = wait_for_codespace(options, token, codespace_name)
        paths = remote_paths(options.repo, options.request_root, options.run_id)

        ensure_remote_request_dir(codespace_name, paths, token)
        upload_request(codespace_name, paths.request_file, request_text, token)
        launch_remote_worker(codespace_name, paths, options.run_id, options.max_turns, token)

        stopped = False
        if not options.keep_running:
            log(f"stopping codespace {codespace_name}")
            stop_codespace(codespace_name, token)
            stopped = True

        summary = summarize_result(codespace, stopped=stopped, paths=paths, run_id=options.run_id)
        if options.output_json is not None:
            write_output(options.output_json, summary)
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 0
    except CodespacesClaudeLaunchError as exc:
        log(str(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
