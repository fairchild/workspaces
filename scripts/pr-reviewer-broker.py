#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run only the production managed PR reviewer broker.

This is the scheduled projection driver for completed managed-review sessions.
It intentionally does not run the ingress canary or the ReviewRun monitor:

- ingress canary proves webhook forwarding still works
- monitor reports queue health and historical attention items
- broker advances completed ReviewRuns into GitHub reviews/statuses

Keeping this script narrow prevents an unrelated monitor failure from blocking
normal GitHub projection reconciliation.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


DEFAULT_BROKER_URL = "https://spaces.cloudcompute.com/api/webhooks/github/pr-reviewer-broker"
EX_TEMPFAIL = 75
SAFE_RESPONSE_KEYS = (
    "ok",
    "repo",
    "checked",
    "applied",
    "completed",
    "failed",
    "skipped",
    "skippedRunning",
    "superseded",
    "retryable",
    "requeued",
    "disabled",
    "error",
)


class BrokerError(RuntimeError):
    """Raised when the broker request fails or reports failed processing."""

    def __init__(self, message: str, *, retryable: bool = False) -> None:
        super().__init__(message)
        self.retryable = retryable


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--broker-url", default=DEFAULT_BROKER_URL)
    parser.add_argument("--repo", default="fairchild/workspaces")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--json", action="store_true", help="Print the full JSON response.")
    return parser.parse_args(argv)


def require_secret() -> str:
    secret = os.environ.get("WORKSPACES_WEBHOOK_CANARY_SECRET", "").strip()
    if not secret:
        raise BrokerError("WORKSPACES_WEBHOOK_CANARY_SECRET is required")
    return secret


def safe_payload(payload: object) -> dict[str, object]:
    if not isinstance(payload, dict):
        return {"error": "non_object_response"}
    return {key: payload[key] for key in SAFE_RESPONSE_KEYS if key in payload}


def payload_for_error(raw: bytes) -> dict[str, object]:
    try:
        return safe_payload(json.loads(raw.decode("utf-8")))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {"error": "non_json_response"}


def broker_url(base_url: str, repo: str, limit: int) -> str:
    parsed = urllib.parse.urlparse(base_url)
    query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    existing = {key for key, _ in query}
    params = {
        "repo": repo,
        "limit": str(limit),
    }
    query.extend((key, value) for key, value in params.items() if key not in existing)
    return urllib.parse.urlunparse(parsed._replace(query=urllib.parse.urlencode(query)))


def request_json(url: str, secret: str, timeout: float) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        method="POST",
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {secret}",
            "User-Agent": "workspaces-pr-reviewer-broker",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(64 * 1024)
    except urllib.error.HTTPError as error:
        raw = error.read(64 * 1024)
        retryable = error.code == 408 or error.code == 429 or 500 <= error.code < 600
        raise BrokerError(
            f"managed reviewer broker returned HTTP {error.code}: "
            f"{json.dumps(payload_for_error(raw), sort_keys=True)}",
            retryable=retryable,
        ) from error
    except urllib.error.URLError as error:
        raise BrokerError(
            f"managed reviewer broker request failed: {error.reason}",
            retryable=True,
        ) from error
    except (TimeoutError, socket.timeout) as error:
        raise BrokerError(
            f"managed reviewer broker request timed out: {error}",
            retryable=True,
        ) from error

    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BrokerError("managed reviewer broker returned a non-JSON response") from error
    if not isinstance(payload, dict):
        raise BrokerError("managed reviewer broker returned a non-object JSON response")
    return payload


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        payload = request_json(
            broker_url(args.broker_url, args.repo, args.limit),
            require_secret(),
            args.timeout,
        )
        if payload.get("ok") is not True:
            raise BrokerError(
                f"managed reviewer broker failed: {json.dumps(safe_payload(payload), sort_keys=True)}"
            )
    except BrokerError as error:
        print(f"::error::{error}", file=sys.stderr)
        return EX_TEMPFAIL if error.retryable else 1

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"managed reviewer broker ok: {json.dumps(safe_payload(payload), sort_keys=True)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
