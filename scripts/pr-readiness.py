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

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from release_policy import RELEASE_PATHS


DEFAULT_SURFACE = "desktop / web / agent-runtime / infra / docs"

# Accepted spellings per required Mergeability field, canonical first. The
# gate's job is to prove the readiness *questions* were answered, not to
# enforce one label string — near-miss labels ("Residual risk:", "Scope:")
# kept failing substantively-complete PRs, so each field accepts the
# variants agents actually write.
FIELD_LABELS: dict[str, tuple[str, ...]] = {
    "Surface": ("Surface", "Scope"),
    "User-facing behavior changed": (
        "User-facing behavior changed",
        "User-facing behavior change",
        "User-facing behavior",
        "User-facing changes",
        "Behavior changed",
    ),
    "Non-happy paths considered": (
        "Non-happy paths considered",
        "Non-happy paths",
        "Edge cases",
        "Failure modes",
        "Error paths",
    ),
    "Residual risk or follow-up": (
        "Residual risk or follow-up",
        "Residual risks",
        "Residual risk",
        "Follow-ups",
        "Follow-up",
        "Risks",
        "Risk",
    ),
    "Release/ops preconditions": (
        "Release/ops preconditions",
        "Release preconditions",
        "Ops preconditions",
    ),
}

MERGEABILITY_TEMPLATE = """## Mergeability

- Surface: <desktop / web / agent-runtime / infra / docs — plus what part>
- User-facing behavior changed: <what changed, or "No">
- Non-happy paths considered: <error paths / edge cases, or "n/a" with why>
- Residual risk or follow-up: <what could still break or is deferred, or "None">"""
DOC_EVIDENCE_EXEMPT_SUFFIXES = (".md", ".mdx", ".markdown", ".txt")
DOC_EVIDENCE_EXEMPT_PREFIXES = ("docs/", "backlog/")


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
    """Value of a labeled line, tolerant of how the label is actually written.

    Accepts any registered synonym for the field, an optional list bullet,
    bold markers around the label, and ':' or '—' as the separator.
    """
    plain = section.replace("**", "")
    for variant in FIELD_LABELS.get(label, (label,)):
        pattern = re.compile(
            rf"(?im)^[ \t]*(?:[-*][ \t]*)?{re.escape(variant)}[ \t]*[:—][ \t]*(?P<value>.*)$"
        )
        if match := pattern.search(plain):
            return match.group("value").strip()
    return None


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


def is_docs_only(files: list[str]) -> bool:
    return bool(files) and all(
        path.endswith(DOC_EVIDENCE_EXEMPT_SUFFIXES)
        or path.startswith(DOC_EVIDENCE_EXEMPT_PREFIXES)
        for path in files
    )


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

    evidence_status = extract_section(body, "Evidence Status")
    if re.search(r"(?im)^\s*-\s*\[(?:blocked|pending-ci)\]\s+", evidence_status):
        failures.append("Requested evidence is blocked or still pending CI.")

    if re.search(r"(?i)\bdo not merge(?:\s+this\s+pr|\s+until|\b)", f"{title}\n{body}"):
        failures.append("PR text contains a merge-stop instruction.")

    if not has_any_evidence(body) and not is_docs_only(files):
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


COMMENT_MARKER = "<!-- pr-readiness-gate -->"

EVIDENCE_HINT = (
    "an uploaded evidence link (`evidence.cloudcompute.com`), an embedded image, "
    'a test summary containing "N passed", or a checked `- [x] Not a testable change` box'
)


def comment_markdown(result: Result) -> str:
    """The sticky PR comment: what failed, and exactly what to paste to fix it.

    The gate's failures used to surface only in the Actions log, so every
    author rediscovered the expected format by archaeology. This turns a
    failure into a self-correcting loop — agents and humans both see the
    missing pieces on the PR itself.
    """
    if result.ok:
        return f"{COMMENT_MARKER}\n✅ **PR readiness gate passed.**\n"
    lines = [COMMENT_MARKER, "⚠️ **PR readiness gate failed** — this PR body is missing readiness signals:", ""]
    lines += [f"- {failure}" for failure in result.failures]
    if any("Mergeability" in failure for failure in result.failures):
        lines += [
            "",
            "Paste and fill this block (labels are matched tolerantly — common synonyms,",
            "bold, and `—` separators are accepted; answers must not be blank/n-a-only):",
            "",
            "```markdown",
            MERGEABILITY_TEMPLATE,
            "```",
        ]
    if any("evidence signal" in failure for failure in result.failures):
        lines += ["", f"Evidence is satisfied by {EVIDENCE_HINT}."]
    lines += [
        "",
        "_Full template: `.github/pull_request_template.md` · gate: `scripts/pr-readiness.py` — "
        "this comment updates automatically on the next push or body edit._",
    ]
    return "\n".join(lines) + "\n"


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

    # The workflow posts this as a sticky PR comment (see pr-readiness.yml).
    if comment_path := os.environ.get("READINESS_COMMENT_PATH"):
        Path(comment_path).write_text(comment_markdown(result), encoding="utf-8")


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
