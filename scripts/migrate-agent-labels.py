#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Migrate agent lifecycle labels to lane + state labels.

Dry-run by default. Use --apply after the code that understands the new labels
has landed on the default branch.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
GITHUB_TIMEOUT = 30


@dataclass(frozen=True)
class LabelSpec:
    name: str
    color: str
    description: str


LABELS = [
    LabelSpec("agent", "5319e7", "Work owned by the agent execution lane"),
    LabelSpec("human", "ededed", "Work explicitly owned by a human"),
    LabelSpec("task", "0E8A16", "Planned work item"),
    LabelSpec("ready", "5319e7", "Ready for the owning lane to act"),
    LabelSpec("claimed", "1d76db", "Actively owned and in progress"),
    LabelSpec("review", "fbca04", "PR opened and awaiting review"),
    LabelSpec("mergeable", "0e8a16", "Agent-approved, ready for owner merge"),
    LabelSpec("decision", "D93F0B", "Needs a scoped decision before continuing"),
    LabelSpec("blocked", "d93f0b", "Blocked by a dependency or unresolved condition"),
    LabelSpec("needs-human", "ededed", "Needs human intervention before continuing"),
    LabelSpec("needs-info", "D876E3", "Waiting on the reporter for more information"),
    LabelSpec("needs-triage", "FFD33D", "Maintainer needs to evaluate the issue"),
    LabelSpec("safe-to-run-agent", "0e8a16", "Maintainer approval for mention-triggered agent execution"),
    LabelSpec("privileged-agent-patch", "b60205", "Break-glass approval for privileged agent patch scope"),
]

LEGACY_LABELS: dict[str, tuple[str, ...]] = {
    "agent:task": ("agent", "task"),
    "agent:ready": ("agent", "ready"),
    "agent:claimed": ("agent", "claimed"),
    "agent:review": ("agent", "review"),
    "agent:mergeable": ("agent", "mergeable"),
    "agent:decision": ("agent", "decision"),
}


def run_json(cmd: list[str]) -> object:
    result = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=GITHUB_TIMEOUT,
    )
    if result.returncode != 0:
        print(result.stderr.strip() or result.stdout.strip(), file=sys.stderr)
        raise SystemExit(result.returncode or 1)
    return json.loads(result.stdout or "null")


def run_checked(cmd: list[str]) -> None:
    result = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=GITHUB_TIMEOUT,
    )
    if result.returncode != 0:
        print(result.stderr.strip() or result.stdout.strip(), file=sys.stderr)
        raise SystemExit(result.returncode or 1)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="perform GitHub label and issue updates")
    parser.add_argument(
        "--delete-legacy",
        action="store_true",
        help="delete old agent:* labels after issues have been migrated",
    )
    return parser.parse_args()


def fetch_labels() -> dict[str, dict[str, object]]:
    return {
        item["name"]: item
        for item in run_json(["gh", "label", "list", "--limit", "300", "--json", "name,color,description"])
    }


def ensure_labels(existing: dict[str, dict[str, object]], *, apply: bool) -> None:
    for spec in LABELS:
        current = existing.get(spec.name)
        if current is None:
            print(f"create label: {spec.name}")
            if apply:
                run_checked([
                    "gh",
                    "label",
                    "create",
                    spec.name,
                    "--color",
                    spec.color,
                    "--description",
                    spec.description,
                ])
            continue

        current_color = str(current.get("color", ""))
        current_description = str(current.get("description", ""))
        if current_color.lower() == spec.color.lower() and current_description == spec.description:
            print(f"label exists: {spec.name}")
            continue

        print(f"update label: {spec.name}")
        if apply:
            run_checked([
                "gh",
                "label",
                "edit",
                spec.name,
                "--color",
                spec.color,
                "--description",
                spec.description,
            ])


def migrate_issues(existing_labels: set[str], *, apply: bool) -> set[str]:
    legacy_seen: set[str] = set()
    for old_label, new_labels in LEGACY_LABELS.items():
        if old_label not in existing_labels:
            continue
        issues = run_json([
            "gh",
            "issue",
            "list",
            "--state",
            "all",
            "--label",
            old_label,
            "--limit",
            "1000",
            "--json",
            "number,title,labels",
        ])
        if not issues:
            continue
        legacy_seen.add(old_label)
        for issue in issues:
            current = {
                label["name"]
                for label in issue.get("labels", [])
                if isinstance(label, dict) and label.get("name")
            }
            missing = [label for label in new_labels if label not in current]
            print(f"issue #{issue['number']}: {old_label} -> {', '.join(new_labels)}")
            if apply and missing:
                cmd = ["gh", "issue", "edit", str(issue["number"])]
                for label in missing:
                    cmd.extend(["--add-label", label])
                run_checked(cmd)
    return legacy_seen


def delete_legacy_labels(labels: set[str], *, apply: bool) -> None:
    for label in sorted(labels):
        print(f"delete legacy label: {label}")
        if apply:
            run_checked(["gh", "label", "delete", label, "--yes"])


def main() -> int:
    args = parse_args()
    if not args.apply:
        print("dry run: pass --apply to update GitHub")
    existing = fetch_labels()
    ensure_labels(existing, apply=args.apply)
    legacy_seen = migrate_issues(set(existing), apply=args.apply)
    if args.delete_legacy:
        delete_legacy_labels(legacy_seen, apply=args.apply)
    elif legacy_seen:
        print("legacy labels still present; rerun with --apply --delete-legacy after reviewing the dry run")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
