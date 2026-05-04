#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Validate PR readiness signals from the GitHub pull_request event."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_SURFACE = "desktop / web / agent-runtime / infra / docs"
RELEASE_PATHS = {
    ".github/workflows/release.yml",
    "scripts/build-release.sh",
    "scripts/generate-sparkle-appcast.sh",
    "scripts/install-local.sh",
    "scripts/notarize.sh",
    "scripts/prepare-release.sh",
    "scripts/release-preflight.sh",
    "scripts/release-version.sh",
    "scripts/setup-release-secrets.sh",
    "scripts/verify-app-keychain-signing.sh",
    "scripts/verify-installed-perf.sh",
    "scripts/verify-p12.sh",
    "scripts/verify-release-bundle.sh",
}


@dataclass(frozen=True)
class Result:
    failures: list[str]
    notices: list[str]

    @property
    def ok(self) -> bool:
        return not self.failures


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def load_json(path: str | None, default: Any) -> Any:
    if not path:
        return default
    with Path(path).open(encoding="utf-8") as file:
        return json.load(file)


def extract_section(body: str, heading: str) -> str:
    pattern = re.compile(
        rf"(?ims)^##+\s+{re.escape(heading)}\s*$\n(?P<section>.*?)(?=^##+\s+\S|\Z)"
    )
    match = pattern.search(body)
    return match.group("section").strip() if match else ""


def field_value(section: str, label: str) -> str | None:
    pattern = re.compile(rf"(?im)^[ \t]*[-*][ \t]*{re.escape(label)}[ \t]*:[ \t]*(?P<value>.*)$")
    match = pattern.search(section)
    if not match:
        return None
    return match.group("value").strip()


def is_blank_value(value: str | None, *, default: str | None = None) -> bool:
    if value is None:
        return True
    normalized = normalize(value)
    if not normalized or normalized in {"-", "n/a", "tbd", "todo", "pending"}:
        return True
    return default is not None and normalized == normalize(default)


def label_names(pr: dict[str, Any]) -> list[str]:
    return [item.get("name", "") for item in pr.get("labels", []) if isinstance(item, dict)]


def has_checked_box(body: str, label: str) -> bool:
    return bool(re.search(rf"(?im)^\s*[-*]\s*\[x\]\s*{re.escape(label)}\b", body))


def has_any_evidence(body: str) -> bool:
    lowered = body.lower()
    return any(
        (
            "evidence.cloudcompute.com" in lowered,
            bool(re.search(r"!\[.*\]\(https?://", body)),
            bool(re.search(r"(?i)(test|tests).*(pass|passed)|\d+\s+passed", body)),
            has_checked_box(body, "Not a testable change"),
        )
    )


def changed_release_files(files: list[str]) -> list[str]:
    return [path for path in files if path in RELEASE_PATHS]


def evaluate(pr: dict[str, Any], files: list[str]) -> Result:
    body = pr.get("body") or ""
    title = pr.get("title") or ""
    labels = label_names(pr)
    failures: list[str] = []
    notices: list[str] = []

    if pr.get("draft"):
        notices.append("Draft PR: readiness gate is advisory until the PR is ready for review.")
        return Result(failures, notices)

    mergeability = extract_section(body, "Mergeability")
    if not mergeability:
        failures.append("Missing ## Mergeability section from the PR body.")
    else:
        required = {
            "Surface": DEFAULT_SURFACE,
            "User-facing behavior changed": None,
            "Non-happy paths considered": None,
            "Residual risk or follow-up": None,
        }
        for field, default in required.items():
            value = field_value(mergeability, field)
            if is_blank_value(value, default=default):
                failures.append(f"Mergeability field is empty or still default: {field}.")

    blocking_labels = sorted(label for label in labels if label.startswith("blocked:"))
    if blocking_labels:
        failures.append(f"Blocking label present: {', '.join(blocking_labels)}.")

    if has_checked_box(body, "Blocked on evidence"):
        failures.append("PR is checked as blocked on evidence.")

    if re.search(r"(?i)\bdo not merge(?:\s+this\s+pr|\s+until|\b)", f"{title}\n{body}"):
        failures.append("PR text contains a merge-stop instruction.")

    if not has_any_evidence(body):
        failures.append("No test/evidence signal found in PR body.")

    release_files = changed_release_files(files)
    if release_files:
        release_preconditions = field_value(mergeability, "Release/ops preconditions")
        if is_blank_value(release_preconditions):
            failures.append(
                "Release-sensitive files changed; fill 'Release/ops preconditions' in the PR body."
            )

        if re.search(r"(?i)(secret|credential).{0,80}(must|need|required).{0,80}before merging", body):
            failures.append(
                "Release PR says secrets/credentials must be added before merging; use blocked:secrets until complete."
            )

        validation = extract_section(body, "Validation")
        if not re.search(r"(?i)(validate-release-changes|bash -n|actionlint|workflow syntax)", validation):
            failures.append(
                "Release-sensitive files changed; validation should include validate-release-changes, bash -n, actionlint, or workflow syntax proof."
            )

    return Result(failures, notices)


def emit(result: Result) -> None:
    for notice in result.notices:
        print(f"::notice::{notice}" if os.environ.get("GITHUB_ACTIONS") else f"NOTICE: {notice}")

    if result.failures:
        print("PR readiness failed:")
        for failure in result.failures:
            prefix = "::error::" if os.environ.get("GITHUB_ACTIONS") else "ERROR:"
            print(f"{prefix}{failure}")
    else:
        print("PR readiness passed.")

    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary_path).open("a", encoding="utf-8") as summary:
            summary.write("## PR Readiness\n\n")
            if result.ok:
                summary.write("- Status: pass\n")
            else:
                summary.write("- Status: fail\n")
                for failure in result.failures:
                    summary.write(f"- {failure}\n")
            for notice in result.notices:
                summary.write(f"- Notice: {notice}\n")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--changed-files", help="JSON file containing a list of changed file paths.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    event = load_json(args.event, {})
    pr = event.get("pull_request") or event
    files = load_json(args.changed_files, [])
    result = evaluate(pr, files)
    emit(result)
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
