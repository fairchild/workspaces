#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Validate PR readiness signals: the body contract every non-draft PR owes.

Two entry points, one `evaluate()`: CI feeds it the GitHub `pull_request`
event, and `--body-file` feeds it a body an author has not published yet, so
the same failures and the same wording arrive before `gh pr create` instead of
one CI round trip later.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from release_policy import RELEASE_PATHS


DEFAULT_SURFACE = "desktop / web / agent-runtime / infra / docs"

# The authored PR body skeleton. Producers derive their sections from this
# file rather than from copied strings, so adding a field to the template
# reaches every generated body without a second edit.
PR_TEMPLATE_PATH = REPO_ROOT / ".github" / "pull_request_template.md"
GIT_TIMEOUT_SECONDS = 20

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

# Hint text per Mergeability field, keyed by the canonical label. This is the
# only place a field's example wording is hardcoded; which fields appear, and
# in what order, comes from `mergeability_field_labels()` reading the template
# — so a field added to the template shows up here with a generic fallback
# hint instead of silently vanishing from the paste-ready block.
FIELD_HINTS: dict[str, str] = {
    "Surface": f"<{DEFAULT_SURFACE} — plus what part>",
    "User-facing behavior changed": '<what changed, or "No">',
    "Non-happy paths considered": '<error paths / edge cases, or "n/a" with why>',
    "Release/ops preconditions": '<what must happen before/at release, or "None">',
    "Residual risk or follow-up": '<what could still break or is deferred, or "None">',
}
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
        rf"(?ms)^## {re.escape(heading)}\n(?P<section>.*?)(?=^## |\n---\n|\Z)"
    )
    match = pattern.search(body)
    return match.group("section").strip() if match else ""


def template_body(path: Path | None = None) -> str:
    try:
        return (path or PR_TEMPLATE_PATH).read_text(encoding="utf-8")
    except OSError:
        return ""


def mergeability_field_labels(path: Path | None = None) -> list[str]:
    """Field labels the PR template declares under `## Mergeability`, in order.

    Producers that seed a Mergeability block read the contract from here, so
    the template stays the one place a required field is added or renamed.
    """
    section = extract_section(template_body(path), "Mergeability")
    return [
        match.group("label").strip()
        for match in re.finditer(r"(?m)^[ \t]*[-*][ \t]*(?P<label>[^:\n]+):", section)
    ]


def mergeability_paste_block(path: Path | None = None) -> str:
    """The paste-ready Mergeability block CI and preflight hand out on failure.

    Built by walking the template-derived field list rather than a second
    hardcoded copy, so a field the template declares can never go missing
    from the block the gate itself tells people to paste — the bug that let
    this gate demand an answer its own guidance never asked for.
    """
    lines = ["## Mergeability", ""]
    for label in mergeability_field_labels(path):
        hint = FIELD_HINTS.get(label, "<fill in>")
        lines.append(f"- {label}: {hint}")
    return "\n".join(lines)


def evidence_status_heading_failure(body: str) -> str | None:
    headings = re.findall(
        r"(?im)^#+[ \t]+Evidence[ \t]+Status(?:[ \t]+#+)?[ \t]*$",
        body,
    )
    exact_count = sum(heading == "## Evidence Status" for heading in headings)
    variant_count = len(headings) - exact_count
    if exact_count > 1 or variant_count:
        return (
            "Ambiguous Evidence Status headings; use at most one exact "
            "'## Evidence Status' heading and no variants."
        )
    return None


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

    if heading_failure := evidence_status_heading_failure(body):
        failures.append(heading_failure)
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


def guidance_markdown(result: Result) -> str:
    """What failed, and exactly what to paste to fix it.

    The gate's failures used to surface only in the Actions log, so every
    author rediscovered the expected format by archaeology. This turns a
    failure into a self-correcting loop — agents and humans both see the
    missing pieces, on the PR itself in CI and on stdout in preflight.
    """
    if result.ok:
        return "✅ **PR readiness gate passed.**\n"
    lines = ["⚠️ **PR readiness gate failed** — this PR body is missing readiness signals:", ""]
    lines += [f"- {failure}" for failure in result.failures]
    if any("Mergeability" in failure for failure in result.failures):
        lines += [
            "",
            "Paste and fill this block (labels are matched tolerantly — common synonyms,",
            "bold, and `—` separators are accepted; answers must not be blank/n-a-only):",
            "",
            "```markdown",
            mergeability_paste_block(),
            "```",
        ]
    if any("evidence signal" in failure for failure in result.failures):
        lines += ["", f"Evidence is satisfied by {EVIDENCE_HINT}."]
    lines += [
        "",
        "_Full template: `.github/pull_request_template.md` — check a body before you push it with "
        "`uv run --script scripts/pr-readiness.py --body-file <path>`. In CI this comment updates "
        "automatically on the next push or body edit._",
    ]
    return "\n".join(lines) + "\n"


def comment_markdown(result: Result) -> str:
    """The sticky PR comment: the same guidance, keyed by an upsert marker."""
    return f"{COMMENT_MARKER}\n{guidance_markdown(result)}"


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


def git_changed_files(base: str) -> list[str]:
    """Paths this branch would put in the PR: committed against `base`, plus
    anything still dirty in the working tree."""
    files: list[str] = []

    def collect(args: list[str]) -> str:
        try:
            done = subprocess.run(
                ["git", *args],
                capture_output=True,
                text=True,
                cwd=REPO_ROOT,
                timeout=GIT_TIMEOUT_SECONDS,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return ""
        return done.stdout if done.returncode == 0 else ""

    def add(path: str) -> None:
        path = path.strip().strip('"')
        if path and path not in files:
            files.append(path)

    for line in collect(["status", "--porcelain"]).splitlines():
        if len(line) > 3:
            path = line[3:]
            add(path.split(" -> ", 1)[1] if " -> " in path else path)
    for ref in (f"origin/{base}", base):
        committed = collect(["diff", "--name-only", f"{ref}...HEAD"])
        if committed.strip():
            for line in committed.splitlines():
                add(line)
            break
    return files


def body_file_pr(path: Path, *, title: str, labels: list[str]) -> dict[str, Any]:
    return {
        "title": title,
        "body": path.read_text(encoding="utf-8"),
        "draft": False,
        "labels": [{"name": name} for name in labels],
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--changed-files", help="JSON file containing a list of changed file paths.")
    parser.add_argument(
        "--body-file",
        help=(
            "Preflight a PR body from a local file, before `gh pr create`. Runs the "
            "same checks CI runs and reports the same failures. Start from "
            ".github/pull_request_template.md."
        ),
    )
    parser.add_argument("--title", default="", help="PR title to check alongside --body-file.")
    parser.add_argument(
        "--label",
        action="append",
        default=[],
        metavar="NAME",
        help="Label the PR will carry; repeatable. Only meaningful with --body-file.",
    )
    parser.add_argument(
        "--base",
        default="main",
        help="Base branch --body-file diffs against to infer changed files (default: main).",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.body_file:
        body_path = Path(args.body_file)
        if not body_path.is_file():
            print(f"ERROR:No such body file: {body_path}")
            return 2
        pr = body_file_pr(body_path, title=args.title, labels=args.label)
        files = load_json(args.changed_files, None)
        if files is None:
            files = git_changed_files(args.base)
            print(f"Preflight: {body_path} against {len(files)} changed file(s) vs {args.base}.")
    else:
        event = load_json(args.event, {})
        pr = event.get("pull_request") or event
        files = load_json(args.changed_files, [])
    result = evaluate(pr, files)
    emit(result)
    if args.body_file and not result.ok:
        print()
        print(guidance_markdown(result), end="")
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
