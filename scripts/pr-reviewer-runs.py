#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Show the ReviewRun-centered managed PR reviewer operator report.

This is the first command to run when the managed PR reviewer looks stuck. It
asks the protected production monitor route for the ReviewRun database view and
prints the current queue in operator terms:

- ``missingRuns``: a reviewer-eligible webhook exists, but no ReviewRun row was
  created. Investigate trigger/ingress.
- ``starting``: a ReviewRun row exists, but the managed-agent session id has not
  been recorded yet. Briefly normal immediately after pickup.
- ``stuckStarting``: a starting row is old enough to need attention.
- ``executing``: a managed-agent session exists and its GitHub projection is
  still inside the normal window.
- ``needsProjection``: the agent run is old enough that the broker should have
  posted a GitHub review or failure status by now.
- ``failed``: either the agent lifecycle or GitHub projection failed and stored
  a reason.
- ``terminal``: completed or superseded rows. These are counted, but omitted
  from the terse text output unless ``--json`` is used.

The script is read-only. It does not run the broker, create sessions, or post
GitHub statuses. Exit code 0 means the monitor reported healthy, 1 means the
monitor returned attention-needed state, and 2 means the report could not be
fetched or parsed.
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
DEFAULT_MONITOR_URL = "https://spaces.cloudcompute.com/api/webhooks/github/pr-reviewer-monitor"


class ReportError(RuntimeError):
    """Raised when the report cannot be fetched or parsed."""


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=DEFAULT_MONITOR_URL)
    parser.add_argument("--repo", default="fairchild/workspaces")
    parser.add_argument("--window-minutes", type=int, default=90)
    parser.add_argument("--starting-timeout-minutes", type=int, default=5)
    parser.add_argument("--projection-timeout-minutes", type=int, default=30)
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--json", action="store_true", help="Print the raw JSON response.")
    return parser.parse_args(argv)


def require_secret() -> str:
    secret = os.environ.get("WORKSPACES_WEBHOOK_CANARY_SECRET", "").strip()
    if not secret:
        raise ReportError("WORKSPACES_WEBHOOK_CANARY_SECRET is required")
    return secret


def report_url(args: argparse.Namespace) -> str:
    parsed = urllib.parse.urlparse(args.url)
    query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    existing = {key for key, _ in query}
    params = {
        "repo": args.repo,
        "windowMinutes": str(args.window_minutes),
        "startingTimeoutMinutes": str(args.starting_timeout_minutes),
        "projectionTimeoutMinutes": str(args.projection_timeout_minutes),
    }
    # Preserve explicit query parameters in --url so operators can paste a
    # precise monitor URL and still use CLI defaults for anything omitted.
    query.extend((key, value) for key, value in params.items() if key not in existing)
    return urllib.parse.urlunparse(parsed._replace(query=urllib.parse.urlencode(query)))


def decode_json_response(raw: bytes) -> dict[str, Any]:
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReportError("monitor returned a non-JSON response") from error
    if not isinstance(payload, dict):
        raise ReportError("monitor returned a non-object JSON response")
    return payload


def fetch_report(url: str, secret: str, timeout: float) -> tuple[int, dict[str, Any]]:
    request = urllib.request.Request(
        url,
        method="GET",
        headers={
            "Accept": "application/json",
            "User-Agent": "workspaces-pr-reviewer-runs",
            CANARY_HEADER: secret,
        },
    )

    # The monitor intentionally returns 503 with useful JSON when a queue needs
    # attention. Treat that as report data, not a transport failure.
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, decode_json_response(response.read(256 * 1024))
    except urllib.error.HTTPError as error:
        return error.code, decode_json_response(error.read(256 * 1024))
    except urllib.error.URLError as error:
        raise ReportError(f"monitor request failed: {error.reason}") from error


def as_int(payload: dict[str, Any], key: str) -> int:
    value = payload.get(key, 0)
    return value if isinstance(value, int) else 0


def run_buckets(payload: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    runs = payload.get("runs")
    if not isinstance(runs, dict):
        return {}
    buckets: dict[str, list[dict[str, Any]]] = {}
    # This payload crosses a deployed API boundary, so keep the renderer
    # defensive even though the server type is stricter.
    for key, value in runs.items():
        if isinstance(key, str) and isinstance(value, list):
            buckets[key] = [item for item in value if isinstance(item, dict)]
    return buckets


def print_run_bucket(label: str, runs: list[dict[str, Any]]) -> None:
    if not runs:
        return
    print(f"\n{label}:")
    for run in runs:
        pr_number = run.get("prNumber", "?")
        short_sha = run.get("shortHeadSha", "-")
        age = run.get("ageMinutes", "?")
        agent_status = run.get("agentStatus", run.get("status", "-"))
        projection_status = run.get("projectionStatus", "-")
        state = run.get("state", "-")
        session_id = run.get("sessionId")
        details_url = run.get("detailsUrl")
        print(
            f"  - PR #{pr_number} {short_sha} {state} "
            f"(agent={agent_status}, projection={projection_status}), age {age}m"
        )
        if session_id:
            print(f"    session: {session_id}")
        if run.get("githubReviewId"):
            print(f"    github review: {run['githubReviewId']}")
        if details_url:
            print(f"    details: {details_url}")
        if run.get("projectionError") and run.get("projectionError") != run.get("error"):
            print(f"    projection error: {run['projectionError']}")
        if run.get("error"):
            print(f"    error: {run['error']}")


def print_report(status: int, payload: dict[str, Any]) -> None:
    health = "healthy" if payload.get("ok") is True else "attention needed"
    repo = payload.get("repo", "unknown repo")
    window = payload.get("windowMinutes", "?")
    print(f"ReviewRun report for {repo} over {window}m: {health} (HTTP {status})")
    print(
        "events "
        f"eligible={as_int(payload, 'eligibleEvents')} "
        f"missing={as_int(payload, 'missingRuns')} "
        f"attention={as_int(payload, 'attentionRequired')}"
    )
    print(
        "runs "
        f"starting={as_int(payload, 'starting')} "
        f"stuckStarting={as_int(payload, 'stuckStarting')} "
        f"executing={as_int(payload, 'executing')} "
        f"needsProjection={as_int(payload, 'needsProjection')} "
        f"failed={as_int(payload, 'failed')} "
        f"terminal={as_int(payload, 'terminal')}"
    )

    missing = payload.get("missing")
    if isinstance(missing, list) and missing:
        print("\nMissing run rows:")
        for item in missing:
            if not isinstance(item, dict):
                continue
            print(
                "  - "
                f"event={item.get('eventId', '?')} "
                f"PR #{item.get('prNumber', '?')} "
                f"{item.get('triggerKind', '?')} "
                f"{str(item.get('headSha', ''))[:7] or '-'}"
            )

    buckets = run_buckets(payload)
    # Print attention buckets before normal progress buckets; terminal rows stay
    # available in --json without making the default report noisy.
    print_run_bucket("Stuck starting", buckets.get("stuckStarting", []))
    print_run_bucket("Needs projection", buckets.get("needsProjection", []))
    print_run_bucket("Failed", buckets.get("failed", []))
    print_run_bucket("Executing", buckets.get("executing", []))
    print_run_bucket("Starting", buckets.get("starting", []))


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        status, payload = fetch_report(report_url(args), require_secret(), args.timeout)
    except ReportError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print_report(status, payload)

    return 0 if payload.get("ok") is True else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
