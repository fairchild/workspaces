#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run the production managed-reviewer ingress canary, broker, and monitor.

The canary proves the deployed Cloudflare relay can forward a signed,
reviewer-eligible webhook to the Vercel route in dry-run mode. The broker then
posts any completed managed-agent review intents, and the monitor checks that
recent eligible production webhook activity has matching managed_pr_review_runs
rows.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


CANARY_HEADER = "X-Workspace-Webhook-Canary"
DEFAULT_CANARY_URL = "https://webhooks.cloudcompute.com/canary/pr-review-ingress"
DEFAULT_MONITOR_URL = "https://spaces.cloudcompute.com/api/webhooks/github/pr-reviewer-monitor"
DEFAULT_BROKER_URL = "https://spaces.cloudcompute.com/api/webhooks/github/pr-reviewer-broker"
DEFAULT_REPO = "fairchild/workspaces"
SAFE_RESPONSE_KEYS = (
    "ok",
    "canary",
    "wouldTrigger",
    "triggerKind",
    "eventType",
    "action",
    "repo",
    "windowMinutes",
    "eligibleEvents",
    "missingRuns",
    "attentionRequired",
    "starting",
    "stuckStarting",
    "executing",
    "needsProjection",
    "terminal",
    "checked",
    "completed",
    "failed",
    "skippedRunning",
    "superseded",
    "requeued",
    "error",
)
SAFE_RUN_KEYS = (
    "prNumber",
    "shortHeadSha",
    "triggerKind",
    "status",
    "agentStatus",
    "projectionStatus",
    "state",
    "ageMinutes",
    "detailsUrl",
    "error",
    "projectionError",
    "githubReviewId",
    "supersededByReviewId",
)
SAFE_MISSING_KEYS = ("eventId", "prNumber", "triggerKind", "headSha")


class CanaryError(RuntimeError):
    """Raised for an unsafe or unexpected canary response."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--canary-url", default=DEFAULT_CANARY_URL)
    parser.add_argument("--monitor-url", default=DEFAULT_MONITOR_URL)
    parser.add_argument("--broker-url", default=DEFAULT_BROKER_URL)
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--window-minutes", type=int, default=90)
    parser.add_argument("--broker-limit", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--skip-canary", action="store_true")
    parser.add_argument("--skip-broker", action="store_true")
    parser.add_argument("--skip-monitor", action="store_true")
    parser.add_argument(
        "--advisory-monitor",
        action="store_true",
        help="Print monitor attention as a warning instead of failing the ingress canary.",
    )
    return parser.parse_args()


def require_secret() -> str:
    secret = os.environ.get("WORKSPACES_WEBHOOK_CANARY_SECRET", "").strip()
    if not secret:
        raise CanaryError("WORKSPACES_WEBHOOK_CANARY_SECRET is required")
    return secret


def url_with_query_defaults(base_url: str, defaults: dict[str, str]) -> str:
    parsed = urllib.parse.urlparse(base_url)
    query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    existing = {key for key, _ in query}
    query.extend(
        (key, value) for key, value in defaults.items() if key not in existing
    )
    return urllib.parse.urlunparse(
        parsed._replace(query=urllib.parse.urlencode(query))
    )


def monitor_url(base_url: str, repo: str, window_minutes: int) -> str:
    return url_with_query_defaults(
        base_url,
        {"repo": repo, "windowMinutes": str(window_minutes)},
    )


def broker_url(base_url: str, repo: str, limit: int) -> str:
    return url_with_query_defaults(base_url, {"repo": repo, "limit": str(limit)})


def safe_run(item: object) -> dict[str, object]:
    if not isinstance(item, dict):
        return {"error": "non_object_run"}
    return {key: item[key] for key in SAFE_RUN_KEYS if key in item}


def safe_runs(value: object) -> object:
    if isinstance(value, list):
        return [safe_run(item) for item in value]
    if isinstance(value, dict):
        return {
            key: [safe_run(item) for item in items]
            for key, items in value.items()
            if isinstance(items, list)
        }
    return {"error": "non_object_runs"}


def safe_missing(item: object) -> dict[str, object]:
    if not isinstance(item, dict):
        return {"error": "non_object_missing"}
    return {key: item[key] for key in SAFE_MISSING_KEYS if key in item}


def safe_missing_list(value: object) -> object:
    if not isinstance(value, list):
        return {"error": "non_list_missing"}
    return [safe_missing(item) for item in value]


def safe_payload(payload: object) -> dict[str, object]:
    if not isinstance(payload, dict):
        return {"error": "non_object_response"}
    safe = {key: payload[key] for key in SAFE_RESPONSE_KEYS if key in payload}
    if "runs" in payload:
        safe["runs"] = safe_runs(payload["runs"])
    if "missing" in payload:
        safe["missing"] = safe_missing_list(payload["missing"])
    return safe


def payload_for_error(raw: bytes) -> dict[str, object]:
    try:
        return safe_payload(json.loads(raw.decode("utf-8")))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {"error": "non_json_response"}


def decode_payload(label: str, raw: bytes) -> dict[str, Any]:
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CanaryError(f"{label} returned a non-JSON response") from error
    if not isinstance(payload, dict):
        raise CanaryError(f"{label} returned a non-object JSON response")
    return payload


def request_json(
    label: str,
    method: str,
    url: str,
    secret: str,
    timeout: float,
    *,
    allow_http_error_json: bool = False,
) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        method=method,
        headers={
            "Accept": "application/json",
            "User-Agent": "workspaces-managed-reviewer-ingress-canary",
            CANARY_HEADER: secret,
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(64 * 1024)
    except urllib.error.HTTPError as error:
        raw = error.read(64 * 1024)
        if allow_http_error_json:
            return decode_payload(label, raw)
        raise CanaryError(
            f"{label} returned HTTP {error.code}: "
            f"{json.dumps(payload_for_error(raw), sort_keys=True)}"
        ) from error
    except urllib.error.URLError as error:
        raise CanaryError(f"{label} request failed: {error.reason}") from error

    return decode_payload(label, raw)


def validate_canary(payload: dict[str, Any]) -> None:
    if (
        payload.get("ok") is not True
        or payload.get("canary") is not True
        or payload.get("wouldTrigger") is not True
        or payload.get("triggerKind") != "opened"
    ):
        raise CanaryError(f"unexpected canary response: {json.dumps(safe_payload(payload), sort_keys=True)}")


def validate_monitor(payload: dict[str, Any]) -> None:
    if payload.get("ok") is not True:
        raise CanaryError(f"reviewer run monitor failed: {json.dumps(safe_payload(payload), sort_keys=True)}")


def main() -> int:
    args = parse_args()

    if args.skip_canary and args.skip_broker and args.skip_monitor:
        print("No managed reviewer ingress checks requested.")
        return 0

    try:
        secret = require_secret()

        if not args.skip_canary:
            payload = request_json(
                "managed reviewer ingress canary",
                "POST",
                args.canary_url,
                secret,
                args.timeout,
            )
            validate_canary(payload)
            print(
                "managed reviewer ingress canary ok: "
                f"{json.dumps(safe_payload(payload), sort_keys=True)}"
            )

        if not args.skip_broker:
            payload = request_json(
                "managed reviewer broker",
                "POST",
                broker_url(args.broker_url, args.repo, args.broker_limit),
                secret,
                args.timeout,
            )
            if payload.get("ok") is not True:
                raise CanaryError(
                    "managed reviewer broker failed: "
                    f"{json.dumps(safe_payload(payload), sort_keys=True)}"
                )
            print(
                "managed reviewer broker ok: "
                f"{json.dumps(safe_payload(payload), sort_keys=True)}"
            )

        if not args.skip_monitor:
            payload = request_json(
                "managed reviewer run monitor",
                "GET",
                monitor_url(args.monitor_url, args.repo, args.window_minutes),
                secret,
                args.timeout,
                allow_http_error_json=args.advisory_monitor,
            )
            try:
                validate_monitor(payload)
            except CanaryError as error:
                if not args.advisory_monitor:
                    raise
                print(f"::warning::{error}", file=sys.stderr)
            else:
                print(
                    "managed reviewer run monitor ok: "
                    f"{json.dumps(safe_payload(payload), sort_keys=True)}"
                )
    except CanaryError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
