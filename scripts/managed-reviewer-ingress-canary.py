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


class CanaryError(RuntimeError):
    """Raised for an unsafe or unexpected canary response."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--canary-url", default=DEFAULT_CANARY_URL)
    parser.add_argument("--monitor-url", default=DEFAULT_MONITOR_URL)
    parser.add_argument("--broker-url", default=DEFAULT_BROKER_URL)
    parser.add_argument("--window-minutes", type=int, default=90)
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--skip-canary", action="store_true")
    parser.add_argument("--skip-broker", action="store_true")
    parser.add_argument("--skip-monitor", action="store_true")
    return parser.parse_args()


def require_secret() -> str:
    secret = os.environ.get("WORKSPACES_WEBHOOK_CANARY_SECRET", "").strip()
    if not secret:
        raise CanaryError("WORKSPACES_WEBHOOK_CANARY_SECRET is required")
    return secret


def monitor_url(base_url: str, window_minutes: int) -> str:
    parsed = urllib.parse.urlparse(base_url)
    query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    if not any(key == "windowMinutes" for key, _ in query):
        query.append(("windowMinutes", str(window_minutes)))
    return urllib.parse.urlunparse(parsed._replace(query=urllib.parse.urlencode(query)))


def safe_payload(payload: object) -> dict[str, object]:
    if not isinstance(payload, dict):
        return {"error": "non_object_response"}
    return {key: payload[key] for key in SAFE_RESPONSE_KEYS if key in payload}


def payload_for_error(raw: bytes) -> dict[str, object]:
    try:
        return safe_payload(json.loads(raw.decode("utf-8")))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {"error": "non_json_response"}


def request_json(label: str, method: str, url: str, secret: str, timeout: float) -> dict[str, Any]:
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
        raise CanaryError(
            f"{label} returned HTTP {error.code}: {json.dumps(payload_for_error(raw), sort_keys=True)}"
        ) from error
    except urllib.error.URLError as error:
        raise CanaryError(f"{label} request failed: {error.reason}") from error

    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CanaryError(f"{label} returned a non-JSON response") from error
    if not isinstance(payload, dict):
        raise CanaryError(f"{label} returned a non-object JSON response")
    return payload


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
            payload = request_json("managed reviewer ingress canary", "POST", args.canary_url, secret, args.timeout)
            validate_canary(payload)
            print(f"managed reviewer ingress canary ok: {json.dumps(safe_payload(payload), sort_keys=True)}")

        if not args.skip_broker:
            payload = request_json("managed reviewer broker", "POST", args.broker_url, secret, args.timeout)
            if payload.get("ok") is not True:
                raise CanaryError(f"managed reviewer broker failed: {json.dumps(safe_payload(payload), sort_keys=True)}")
            print(f"managed reviewer broker ok: {json.dumps(safe_payload(payload), sort_keys=True)}")

        if not args.skip_monitor:
            payload = request_json(
                "managed reviewer run monitor",
                "GET",
                monitor_url(args.monitor_url, args.window_minutes),
                secret,
                args.timeout,
            )
            validate_monitor(payload)
            print(f"managed reviewer run monitor ok: {json.dumps(safe_payload(payload), sort_keys=True)}")
    except CanaryError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
