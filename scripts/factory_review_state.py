#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Typed receipts shared by review preparation, retry admission, and responses.

Receipts record availability and findings without granting approval or branch
access. Only exact-head records from the assigned reviewer can suppress a retry.
"""

from __future__ import annotations

import importlib.util
import json
import re
import secrets
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


def _visible_lines(body: str) -> list[str]:
    name = "factory_responder_for_review_state"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(
            name, Path(__file__).with_name("factory-responder-payload.py")
        )
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]._unquoted_visible_lines(body)


REVIEWER_LOGINS = {"april": "april-clearwater[bot]", "plat": "workspace-agents[bot]"}
PREPARATION_REASONS = frozenset({
    "ready", "missing_image", "disallowed_url", "invalid_image", "image_too_large",
    "unsupported_evidence", "image_reader_unavailable", "stale_head", "stale_base",
    "checks_unavailable", "checks_blocked", "download_failed", "inspection_unverified",
    "invalid_evidence",
})
FINDING_CATEGORIES = frozenset({"code-defect", "missing-evidence", "policy-discrepancy"})
MAX_PREPARATION_ATTEMPTS = 2
SHA_RE = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})")
DIGEST_RE = re.compile(r"[0-9a-f]{64}")


def _text(value: Any, limit: int) -> bool:
    return isinstance(value, str) and bool(value.strip()) and len(value) <= limit


def validate_preparation(payload: Any, *, expected_head: str) -> dict[str, Any]:
    """Validate the public subset. Private artifacts/paths never enter markers."""
    fields = {
        "version", "pr_number", "head_sha", "base_sha", "input_digest", "status",
        "reason_code", "retryable", "attempt_count", "capability_version", "resume_condition",
    }
    if not isinstance(payload, dict) or set(payload) != fields:
        raise ValueError("preparation receipt has unexpected fields")
    if (
        type(payload["version"]) is not int or payload["version"] != 1
        or type(payload["pr_number"]) is not int or payload["pr_number"] <= 0
        or not isinstance(payload["head_sha"], str)
        or SHA_RE.fullmatch(payload["head_sha"]) is None
        or payload["head_sha"] != expected_head
        or not isinstance(payload["base_sha"], str)
        or SHA_RE.fullmatch(payload["base_sha"]) is None
        or not isinstance(payload["input_digest"], str)
        or DIGEST_RE.fullmatch(payload["input_digest"]) is None
        or payload["status"] not in ("ready", "unavailable")
        or not isinstance(payload["reason_code"], str) or payload["reason_code"] not in PREPARATION_REASONS
        or type(payload["retryable"]) is not bool
        or type(payload["attempt_count"]) is not int
        or not 1 <= payload["attempt_count"] <= MAX_PREPARATION_ATTEMPTS
        or not _text(payload["capability_version"], 100)
        or not _text(payload["resume_condition"], 500)
        or (payload["status"] == "ready") != (payload["reason_code"] == "ready")
    ):
        raise ValueError("invalid or stale preparation receipt")
    return dict(payload)


def _marker(kind: str, payload: dict[str, Any]) -> str:
    # JSON escaping prevents author-provided text from terminating an HTML marker.
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    encoded = encoded.replace("<", "\\u003c").replace(">", "\\u003e")
    return f"<!-- factory-review-{kind}:v1\n{encoded}\n-->"


def _payload(body: str, kind: str) -> Any:
    if len(body) > 65536:
        return None
    candidates = list(re.finditer(
        rf"(?m)^<!-- factory-review-{kind}:v1\n([^\n]+)\n-->$", body
    ))
    matches = []
    for candidate in candidates:
        # The canonical visibility reader strips inline code too. Check the
        # marker's position with a placeholder, but parse its original JSON so
        # literal backticks in an ask cannot silently change the receipt.
        token = "FACTORY_REVIEW_RECEIPT_" + secrets.token_hex(16)
        positioned = body[:candidate.start()] + token + body[candidate.end():]
        if token in _visible_lines(positioned):
            matches.append(candidate)
    if len(matches) != 1:
        return None
    try:
        return json.loads(matches[0][1])
    except (ValueError, RecursionError):
        return None


def preparation_marker(payload: dict[str, Any]) -> str:
    return _marker("preparation", validate_preparation(payload, expected_head=payload.get("head_sha", "")))


def preparation_from_comment(
    comment: dict[str, Any], *, expected_head: str, pr_number: int, reviewer: str,
) -> dict[str, Any] | None:
    expected_login = REVIEWER_LOGINS.get(reviewer, "")
    if not expected_login or str((comment.get("user") or {}).get("login") or "").casefold() != expected_login:
        return None
    try:
        payload = validate_preparation(
            _payload(str(comment.get("body") or ""), "preparation"), expected_head=expected_head
        )
    except (ValueError, TypeError):
        return None
    return payload if payload["pr_number"] == pr_number else None


@dataclass(frozen=True)
class RetryDecision:
    action: str
    publish: bool
    comment_id: int | None
    reason: str


def preparation_retry_decision(
    preparation: dict[str, Any], comments: list[dict[str, Any]], *, reviewer: str,
) -> RetryDecision:
    """Bound transient preparation to one retry; never retry the model on failure.

    Call inside the existing per-PR serialized review job, after fresh preparation
    and before invoking the model. A successful delivery still requires inspection.
    """
    current = validate_preparation(preparation, expected_head=preparation.get("head_sha", ""))
    if reviewer not in REVIEWER_LOGINS:
        raise ValueError("unknown assigned reviewer")
    previous: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for comment in comments:
        receipt = preparation_from_comment(
            comment, expected_head=current["head_sha"], pr_number=current["pr_number"], reviewer=reviewer
        )
        if receipt is not None and type(comment.get("id")) is int and comment["id"] > 0:
            previous.append((comment, receipt))
    previous.sort(key=lambda pair: pair[0]["id"])
    comment_id = previous[-1][0]["id"] if previous else None
    latest = previous[-1][1] if previous else None
    input_fields = ("head_sha", "base_sha", "input_digest", "capability_version")
    if (
        latest and latest["status"] == "unavailable" and latest["reason_code"] == "inspection_unverified"
        and all(latest[key] == current[key] for key in input_fields)
    ):
        return RetryDecision("pause", False, comment_id,
                             "delivery alone does not resolve missing inspection; change evidence or reviewer capability")
    if current["status"] == "ready":
        return RetryDecision("review", latest is not None and latest["status"] == "unavailable", comment_id,
                             "evidence available; reviewer inspection is not yet verified")
    identity = (*input_fields, "reason_code")
    if latest and latest["status"] == "unavailable" and all(latest[key] == current[key] for key in identity):
        return RetryDecision("pause", False, comment_id,
                             "unchanged preparation failure; waiting for the recorded resume condition")
    if current["retryable"] and current["attempt_count"] < MAX_PREPARATION_ATTEMPTS:
        return RetryDecision("retry", False, comment_id, "one transient preparation retry remains")
    return RetryDecision("pause", True, comment_id, "review preparation is unavailable")


def preparation_comment(payload: dict[str, Any]) -> str:
    current = validate_preparation(payload, expected_head=payload.get("head_sha", ""))
    if current["status"] == "ready":
        text = "Review evidence is now available. Image inspection and formal review are not yet verified."
    else:
        reason = current["reason_code"].replace("_", " ")
        resume = " ".join(current["resume_condition"].replace("`", "").split())
        resume = resume.replace("<", "").replace(">", "")
        text = (
            f"Factory review preparation is paused: {reason}. "
            "The Factory review runtime owns this blocker. No code-change verdict or approval was submitted. "
            f"Resume condition: `{resume}`. "
            "Repeated requests with unchanged inputs do not run another full review."
        )
    return text + "\n\n" + preparation_marker(current) + "\n"


def validate_findings(payload: Any, *, expected_head: str) -> dict[str, Any]:
    if (
        not isinstance(payload, dict) or set(payload) != {"version", "head_sha", "findings"}
        or type(payload["version"]) is not int or payload["version"] != 1
        or not isinstance(payload["head_sha"], str) or SHA_RE.fullmatch(payload["head_sha"]) is None
        or payload["head_sha"] != expected_head
        or not isinstance(payload["findings"], list) or not 1 <= len(payload["findings"]) <= 10
    ):
        raise ValueError("invalid or stale review findings")
    for finding in payload["findings"]:
        if not isinstance(finding, dict):
            raise ValueError("invalid review finding")
        policy = finding.get("category") == "policy-discrepancy"
        fields = {"category", "target", "requested_change"} | ({"rule", "conflicting_fact"} if policy else set())
        if (
            set(finding) != fields or not isinstance(finding["category"], str)
            or finding["category"] not in FINDING_CATEGORIES
            or not _text(finding["target"], 240) or not _text(finding["requested_change"], 2000)
            or (policy and (not _text(finding["rule"], 500) or not _text(finding["conflicting_fact"], 1000)))
        ):
            raise ValueError("invalid review finding fields")
    return payload


def findings_marker(payload: dict[str, Any]) -> str:
    return _marker("findings", validate_findings(payload, expected_head=payload.get("head_sha", "")))


def findings_from_review(review: dict[str, Any], *, expected_head: str) -> list[dict[str, str]]:
    if (
        str((review.get("user") or {}).get("login") or "").casefold() not in REVIEWER_LOGINS.values()
        or review.get("commit_id") != expected_head
        or str(review.get("state") or "").upper() != "CHANGES_REQUESTED"
    ):
        return []
    try:
        return validate_findings(_payload(str(review.get("body") or ""), "findings"),
                                 expected_head=expected_head)["findings"]
    except (ValueError, TypeError):
        return []
