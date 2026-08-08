#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Drift gate for milestone legibility.

Every OPEN GitHub milestone must be self-describing from inspection alone, so a
cold session can read relative priority and roadmap order straight from the
milestone list without opening the roadmap doc:

  1. the title carries a lane/order prefix — ``[D1]``, ``[W3]`` (D = desktop,
     W = web-next) — so execution order is visible on sight, and
  2. the description leads with a ``[LANE: …]`` posture tag (lane + active/queued).

The convention and its rationale live in ``docs/agents/issue-tracker.md`` §
"Milestone Operating Contract"; this check keeps the live milestones honest to it.
Read-only — it never edits milestones. Exit 0 when every open milestone conforms,
1 (with a per-milestone reason) otherwise.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

# Title must open with a lane/order tag then real text: "[D1] v0.23 — …".
TITLE_RE = re.compile(r"^\[[A-Za-z]+\d+\]\s+\S")
# Description's first non-empty line must carry a lane posture tag.
POSTURE_RE = re.compile(r"\[LANE:\s*[A-Za-z]", re.IGNORECASE)


def fetch_open_milestones(repo: str) -> list[dict]:
    # Open milestones are few (one active + a short queue per lane); a single
    # per_page=100 page is always enough, which keeps parsing to one json.loads.
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/milestones?state=open&per_page=100"],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        raise SystemExit(f"error: failed to fetch milestones for {repo}:\n{result.stderr.strip()}")
    return json.loads(result.stdout or "[]")


def first_nonempty_line(text: str | None) -> str:
    for line in (text or "").splitlines():
        if line.strip():
            return line.strip()
    return ""


def check(milestones: list[dict]) -> list[str]:
    failures: list[str] = []
    for ms in milestones:
        title = str(ms.get("title", ""))
        num = ms.get("number")
        if not TITLE_RE.match(title):
            failures.append(
                f"#{num} {title!r}: title is missing a lane/order prefix "
                f"(expected e.g. '[D1] …' or '[W3] …')."
            )
        if not POSTURE_RE.search(first_nonempty_line(ms.get("description"))):
            failures.append(
                f"#{num} {title!r}: description does not lead with a '[LANE: …]' "
                f"posture tag (lane + active/queued)."
            )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo",
        default=os.environ.get("GITHUB_REPOSITORY", "fairchild/workspaces"),
        help="owner/name (default: $GITHUB_REPOSITORY or fairchild/workspaces)",
    )
    args = parser.parse_args()

    milestones = fetch_open_milestones(args.repo)
    if not milestones:
        print(f"No open milestones on {args.repo}; nothing to check.")
        return 0

    failures = check(milestones)
    if failures:
        print(f"Milestone legibility drift on {args.repo} ({len(failures)} issue(s)):\n")
        for line in failures:
            print(f"  - {line}")
        print(
            "\nFix: give each open milestone a '[<lane><order>]' title prefix and a "
            "'[LANE: …]' posture header (see docs/agents/issue-tracker.md § 'Milestone Operating Contract')."
        )
        return 1

    print(f"All {len(milestones)} open milestone(s) on {args.repo} are legible (title prefix + posture tag).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
