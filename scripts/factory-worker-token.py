#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "pyjwt[crypto]>=2.8",
# ]
# ///
"""Mint a GitHub App installation token for the `workspaces-factory` worker
identity (issue #1180), so an Orca-dispatched worker can push commits and
open PRs as `workspaces-factory[bot]` instead of the owner's personal
account — the property that lets the owner formally approve the PR.

Reads FACTORY_WORKER_APP_ID and FACTORY_WORKER_APP_KEY (a filesystem path to
the App's PEM private key) from the environment. Prints the minted token
(valid ~1 hour, GitHub's fixed installation-token lifetime) to stdout and
diagnostic detail to stderr; wire it up with `GH_TOKEN=$(uv run --script
scripts/factory-worker-token.py)`.

`--check` reports readiness without minting anything, distinguishing three
states: not-configured (env unset or unreadable), configured-but-app-not-
installed (valid App credentials, but no installation on this repo), and
working.
"""

from __future__ import annotations

import argparse
import enum
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import jwt

API_BASE = "https://api.github.com"
JWT_CLOCK_DRIFT_SECONDS = 60
JWT_TTL_SECONDS = 480  # GitHub caps App JWTs at 600s; stay comfortably under it


class WorkerTokenState(enum.Enum):
    NOT_CONFIGURED = "not-configured"
    APP_NOT_INSTALLED = "configured-but-app-not-installed"
    WORKING = "working"


EXIT_CODES = {
    WorkerTokenState.WORKING: 0,
    WorkerTokenState.NOT_CONFIGURED: 1,
    WorkerTokenState.APP_NOT_INSTALLED: 2,
}


class WorkerTokenError(RuntimeError):
    def __init__(self, state: WorkerTokenState, message: str):
        super().__init__(message)
        self.state = state


@dataclass
class WorkerTokenResult:
    state: WorkerTokenState
    detail: str
    token: str | None = None
    expires_at: str | None = None
    installation_id: int | None = None


def mint_jwt(app_id: str, private_key_pem: bytes, *, now: int | None = None) -> str:
    """Build a GitHub App JWT (RS256), signed with the App's private key."""
    current = now if now is not None else int(time.time())
    issued_at = current - JWT_CLOCK_DRIFT_SECONDS
    try:
        return jwt.encode(
            {"iss": app_id, "iat": issued_at, "exp": issued_at + JWT_TTL_SECONDS},
            private_key_pem,
            algorithm="RS256",
        )
    # PyJWT/cryptography don't raise a single exception type for bad key
    # material: ValueError/InvalidKeyError for unparseable bytes, TypeError
    # for an encrypted PEM given without a password, AttributeError for a
    # public (not private) key PEM — verified empirically against the
    # versions this script pins, not guessed.
    except (ValueError, TypeError, AttributeError, jwt.InvalidKeyError) as err:
        raise WorkerTokenError(
            WorkerTokenState.NOT_CONFIGURED,
            f"FACTORY_WORKER_APP_KEY is not a valid RSA private key: {err}",
        ) from err


def repo_from_env_or_git(explicit: str | None) -> str:
    if explicit:
        return explicit
    env_repo = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if env_repo:
        return env_repo
    try:
        result = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        )
    except (subprocess.CalledProcessError, OSError) as err:
        raise RuntimeError(f"could not determine target repo from 'git remote get-url origin': {err}") from err
    match = re.search(r"github\.com[:/]+([^/]+/[^/]+?)(?:\.git)?$", result.stdout.strip())
    if not match:
        raise RuntimeError(f"could not parse owner/repo from git remote 'origin' ({result.stdout.strip()!r})")
    return match.group(1)


def _api_call(method: str, path: str, bearer_token: str, *, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    headers = {
        "Authorization": f"Bearer {bearer_token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = Request(f"{API_BASE}{path}", data=data, method=method, headers=headers)
    with urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


def find_installation_id(app_jwt: str, repo: str) -> int:
    try:
        data = _api_call("GET", f"/repos/{repo}/installation", app_jwt)
    except HTTPError as err:
        if err.code == 404:
            raise WorkerTokenError(
                WorkerTokenState.APP_NOT_INSTALLED,
                f"workspaces-factory is not installed on {repo} (404 from /repos/{repo}/installation)",
            ) from err
        if err.code in (401, 403):
            raise WorkerTokenError(
                WorkerTokenState.NOT_CONFIGURED,
                f"GitHub rejected the App JWT ({err.code}) — FACTORY_WORKER_APP_ID or FACTORY_WORKER_APP_KEY is likely wrong",
            ) from err
        raise
    return data["id"]


def mint_installation_token(app_jwt: str, installation_id: int, repo: str) -> dict:
    # Scope the minted token to just this repo, even though the installation
    # itself is expected to be repo-scoped at install time (belt and
    # suspenders: an installation later widened to more repositories must
    # not silently widen every token this script mints).
    repo_name = repo.rsplit("/", 1)[-1]
    try:
        return _api_call(
            "POST",
            f"/app/installations/{installation_id}/access_tokens",
            app_jwt,
            body={"repositories": [repo_name]},
        )
    except HTTPError as err:
        body = err.read().decode("utf-8", "replace")[:300]
        if err.code in (401, 403):
            raise WorkerTokenError(
                WorkerTokenState.NOT_CONFIGURED,
                f"GitHub rejected the installation-token request ({err.code}): {body}",
            ) from err
        if err.code == 404:
            raise WorkerTokenError(
                WorkerTokenState.APP_NOT_INSTALLED,
                f"installation {installation_id} was not found when minting a token ({err.code}): {body}",
            ) from err
        raise


def resolve(repo: str, *, mint: bool = True) -> WorkerTokenResult:
    """Resolve readiness. `mint=False` (used by --check) stops after proving
    the App is installed on `repo` — it never calls the access_tokens
    endpoint, so a readiness check never creates a real 1-hour credential."""
    app_id = os.environ.get("FACTORY_WORKER_APP_ID", "").strip()
    key_path = os.environ.get("FACTORY_WORKER_APP_KEY", "").strip()
    missing = [name for name, value in (("FACTORY_WORKER_APP_ID", app_id), ("FACTORY_WORKER_APP_KEY", key_path)) if not value]
    if missing:
        return WorkerTokenResult(WorkerTokenState.NOT_CONFIGURED, f"missing env var(s): {', '.join(missing)}")

    key_file = Path(key_path)
    if not key_file.is_file():
        return WorkerTokenResult(WorkerTokenState.NOT_CONFIGURED, f"FACTORY_WORKER_APP_KEY={key_path} does not exist")

    try:
        try:
            key_bytes = key_file.read_bytes()
        except OSError as err:
            raise WorkerTokenError(WorkerTokenState.NOT_CONFIGURED, f"could not read FACTORY_WORKER_APP_KEY={key_path}: {err}") from err
        app_jwt = mint_jwt(app_id, key_bytes)
        installation_id = find_installation_id(app_jwt, repo)
        if not mint:
            return WorkerTokenResult(
                WorkerTokenState.WORKING,
                f"workspaces-factory is installed on {repo} (installation {installation_id}); not minting a token for --check",
                installation_id=installation_id,
            )
        token_data = mint_installation_token(app_jwt, installation_id, repo)
    except WorkerTokenError as err:
        return WorkerTokenResult(err.state, str(err))

    return WorkerTokenResult(
        WorkerTokenState.WORKING,
        f"minted installation token for {repo}, expires {token_data.get('expires_at')}",
        token=token_data["token"],
        expires_at=token_data.get("expires_at"),
        installation_id=installation_id,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Mint a workspaces-factory GitHub App installation token")
    parser.add_argument("--check", action="store_true", help="report readiness (not-configured / app-not-installed / working) without minting a token")
    parser.add_argument("--repo", help="owner/repo (default: $GITHUB_REPOSITORY, else 'git remote get-url origin')")
    args = parser.parse_args()

    try:
        repo = repo_from_env_or_git(args.repo)
    except RuntimeError as err:
        sys.exit(f"error: {err}")

    try:
        result = resolve(repo, mint=not args.check)
    except URLError as err:
        sys.exit(f"error: could not reach GitHub API: {err}")

    if args.check:
        print(f"{result.state.value}: {result.detail}")
        return EXIT_CODES[result.state]

    if result.state != WorkerTokenState.WORKING:
        sys.exit(f"error: {result.state.value}: {result.detail}")

    print(f"installation={result.installation_id} expires={result.expires_at} repo={repo}", file=sys.stderr)
    print(result.token)
    return 0


if __name__ == "__main__":
    sys.exit(main())
