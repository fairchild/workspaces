#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run the production managed-reviewer ingress canary.

The canary proves the deployed Cloudflare relay can forward a signed,
reviewer-eligible webhook to the Vercel route in dry-run mode. It does not run
the broker or monitor; those are separate managed-reviewer surfaces.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any


CANARY_HEADER = "X-Workspace-Webhook-Canary"
DEFAULT_CANARY_URL = "https://webhooks.cloudcompute.com/canary/pr-review-ingress"
SAFE_RESPONSE_KEYS = (
    "ok",
    "canary",
    "wouldTrigger",
    "triggerKind",
    "eventType",
    "action",
    "repo",
    "error",
)


class CanaryError(RuntimeError):
    """Raised for an unsafe or unexpected canary response."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--canary-url", default=DEFAULT_CANARY_URL)
    parser.add_argument("--timeout", type=float, default=20)
    return parser.parse_args()


def require_secret() -> str:
    secret = os.environ.get("WORKSPACES_WEBHOOK_CANARY_SECRET", "").strip()
    if not secret:
        raise CanaryError("WORKSPACES_WEBHOOK_CANARY_SECRET is required")
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
        raise CanaryError(
            f"unexpected canary response: "
            f"{json.dumps(safe_payload(payload), sort_keys=True)}"
        )


def main() -> int:
    args = parse_args()

    try:
        secret = require_secret()
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
    except CanaryError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
