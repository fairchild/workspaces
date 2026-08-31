#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Compare two canonical Workspaces performance summaries."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from perf_history import LEGACY_PROTOCOL_EPOCH
from perf_schema import load_contract


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path, help="Path to the baseline summary JSON.")
    parser.add_argument("after", type=Path, help="Path to the candidate summary JSON.")
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable JSON.",
    )
    return parser.parse_args()


def load_summary(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def compare(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    metric_names = sorted(set(before.get("metrics", {})) | set(after.get("metrics", {})))
    comparisons: dict[str, Any] = {}
    # Decided before any arithmetic: a delta across a scenario or epoch boundary is a
    # real subtraction of two numbers that answer different questions, and printing it
    # next to a warning still invites it into a PR description as an improvement.
    incomparable = incomparability_reasons(before, after)

    for metric_name in metric_names:
        before_metric = before.get("metrics", {}).get(metric_name) or {}
        after_metric = after.get("metrics", {}).get(metric_name) or {}
        before_median = before_metric.get("median")
        after_median = after_metric.get("median")
        delta_ms = None
        delta_percent = None
        if not incomparable and before_median is not None and after_median is not None:
            delta_ms = float(after_median) - float(before_median)
            if float(before_median) != 0:
                delta_percent = (delta_ms / float(before_median)) * 100.0

        comparisons[metric_name] = {
            "before": before_metric,
            "after": after_metric,
            "delta_ms": delta_ms,
            "delta_percent": delta_percent,
            "after_budget": after.get("budget_results", {}).get(metric_name),
        }

    return {
        "scenario_before": before.get("scenario"),
        "scenario_after": after.get("scenario"),
        "protocol_epoch_before": protocol_epoch(before),
        "protocol_epoch_after": protocol_epoch(after),
        "incomparable": incomparable,
        "comparisons": comparisons,
        "contract_version": load_contract().get("version"),
    }


def protocol_epoch(summary: dict[str, Any]) -> str:
    return summary.get("metadata", {}).get("protocol_epoch") or LEGACY_PROTOCOL_EPOCH


def incomparability_reasons(before: dict[str, Any], after: dict[str, Any]) -> list[str]:
    """Why these two summaries do not describe the same measurement, if they don't.

    A delta is only an app-side delta within one scenario and one measurement protocol.
    Across either boundary the number is real but means something else — the epoch that
    ended when the wakeup tick stopped running inline (#1251) moved when the launch
    metric closes, so a v1-to-v2 delta reports that change as a regression.
    """
    reasons = []
    if before.get("scenario") != after.get("scenario"):
        reasons.append(
            f"scenario differs: {before.get('scenario')} -> {after.get('scenario')}"
        )
    if protocol_epoch(before) != protocol_epoch(after):
        reasons.append(
            f"protocol epoch differs: {protocol_epoch(before)} -> {protocol_epoch(after)}"
        )
    return reasons


def print_text(payload: dict[str, Any]) -> None:
    print("Workspaces perf comparison")
    print(f"  before: {payload['scenario_before']} ({payload['protocol_epoch_before']})")
    print(f"  after:  {payload['scenario_after']} ({payload['protocol_epoch_after']})")
    if payload["incomparable"]:
        print()
        print("  WARNING: these summaries are not directly comparable —")
        for reason in payload["incomparable"]:
            print(f"    - {reason}")
        print("  Deltas are withheld: subtracting them would answer a question neither run asked.")
    print()

    for metric_name, metric_payload in payload["comparisons"].items():
        before_median = metric_payload["before"].get("median")
        after_median = metric_payload["after"].get("median")
        delta_ms = metric_payload["delta_ms"]
        delta_percent = metric_payload["delta_percent"]
        budget = metric_payload["after_budget"] or {}

        before_text = f"{before_median:.2f}" if before_median is not None else "n/a"
        after_text = f"{after_median:.2f}" if after_median is not None else "n/a"
        if delta_ms is None:
            delta_text = "n/a"
        else:
            delta_text = f"{delta_ms:+.2f} ms"
            if delta_percent is not None:
                delta_text += f" ({delta_percent:+.1f}%)"

        status = budget.get("status", "ungated")
        budget_text = budget.get("gate_budget_ms")
        if budget_text is None:
            budget_suffix = "ungated"
        else:
            budget_suffix = f"gate <= {budget_text} ms [{status}]"
        print(f"- {metric_name}: {before_text} -> {after_text}; {delta_text}; {budget_suffix}")


def main() -> int:
    args = parse_args()
    payload = compare(load_summary(args.before), load_summary(args.after))

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print_text(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
