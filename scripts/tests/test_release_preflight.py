#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Release-preflight tests for GitHub check-run lookup reliability.

These tests run without network, secrets, UI access, or live GitHub mutation.
They protect the release gate that verifies CI on the exact SHA being
published, especially when GitHub check-runs spill past the first API page.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "release-preflight.sh"
CI_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "ci.yml"


def ci_workflow_script_paths() -> set[str]:
    """The scripts/ entries in ci.yml's push path filter."""
    return set(re.findall(r'^\s+- "(scripts/[^"*]+)"$', CI_WORKFLOW_PATH.read_text(), re.M))


def preflight_relevant_script_paths() -> set[str]:
    """The scripts/ entries in release-preflight.sh's is_ci_relevant_path case."""
    body = SCRIPT_PATH.read_text()
    block = body[body.index("is_ci_relevant_path()") :]
    block = block[: block.index("return 1")]
    return set(re.findall(r"(scripts/[A-Za-z0-9_.-]+)", block))


class CiRelevantPathParityTests(unittest.TestCase):
    """release-preflight.sh hand-duplicates ci.yml's path filter.

    The two lists decide the same thing from opposite ends: which changes oblige
    a build-and-test run. When they disagree, preflight can read a commit as
    having no CI-relevant changes and wave a release through on a file CI was
    watching. Nothing coupled them, so this does.
    """

    def test_every_ci_watched_script_is_release_relevant(self) -> None:
        missing = ci_workflow_script_paths() - preflight_relevant_script_paths()
        self.assertEqual(
            missing,
            set(),
            "ci.yml triggers build-and-test for these scripts but "
            "release-preflight.sh's is_ci_relevant_path does not list them, so a "
            "release can skip waiting for the CI they gate: "
            f"{sorted(missing)}",
        )

    def test_every_release_relevant_script_is_ci_watched(self) -> None:
        missing = preflight_relevant_script_paths() - ci_workflow_script_paths()
        self.assertEqual(
            missing,
            set(),
            "release-preflight.sh waits for build-and-test on these scripts but "
            "ci.yml never runs it for them, so preflight waits for a check that "
            "will not arrive: "
            f"{sorted(missing)}",
        )


class ReleasePreflightTests(unittest.TestCase):
    def test_paginated_check_run_lookup_uses_latest_matching_run(self) -> None:
        with ReleasePreflightFixture() as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("CI (build-and-test): PASS", result.stdout)
        self.assertNotIn("FAIL (failure)", result.stdout)

    def test_absent_required_ci_stays_readable_in_dry_run(self) -> None:
        with ReleasePreflightFixture(no_required_ci=True) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("CI (build-and-test): NOT FOUND (dry-run: continuing)", result.stdout)
        self.assertIn("Preflight passed.", result.stdout)


class ReleasePreflightFixture:
    def __init__(self, *, no_required_ci: bool = False) -> None:
        self.no_required_ci = no_required_ci
        self.root = Path(tempfile.mkdtemp(prefix="ReleasePreflightTests-"))

    def __enter__(self) -> "ReleasePreflightFixture":
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        fake_gh = fake_bin / "gh"
        fake_gh.write_text(
            textwrap.dedent(
                """\
                #!/bin/sh
                args=" $* "

                case "$args" in
                    *"/commits/test-sha/check-runs"* )
                        if [ "${FAKE_RELEASE_PREFLIGHT_NO_REQUIRED_CI:-}" = "1" ]; then
                            printf '%s\\t%s\\t%s\\t%s\\n' "lint" "completed" "success" "2026-06-06T10:00:00Z"
                            exit 0
                        fi

                        case "$args" in
                            *" --paginate "*"per_page=100"* )
                                printf '%s\\t%s\\t%s\\t%s\\n' "build-and-test" "completed" "failure" "2026-06-06T10:00:00Z"
                                printf '%s\\t%s\\t%s\\t%s\\n' "lint" "completed" "success" "2026-06-06T10:01:00Z"
                                printf '%s\\t%s\\t%s\\t%s\\n' "build-and-test" "completed" "success" "2026-06-06T10:02:00Z"
                                printf '%s\\t%s\\t%s\\t%s\\n' "perf-validation" "completed" "success" "2026-06-06T10:03:00Z"
                                ;;
                            * )
                                printf '%s\\t%s\\t%s\\t%s\\n' "build-and-test" "completed" "failure" "2026-06-06T10:00:00Z"
                                ;;
                        esac
                        ;;
                    *"/commits/test-sha "* )
                        printf '%s\\n' "Sources/App.swift"
                        ;;
                    * )
                        printf 'unexpected gh invocation: %s\\n' "$*" >&2
                        exit 64
                        ;;
                esac
                """
            ),
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)
        return self

    def __exit__(self, *args: object) -> None:
        shutil.rmtree(self.root)

    def run(self) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PATH"] = f"{self.root / 'bin'}:{environment['PATH']}"
        environment["FAKE_RELEASE_PREFLIGHT_NO_REQUIRED_CI"] = "1" if self.no_required_ci else ""

        return subprocess.run(
            ["/bin/bash", str(SCRIPT_PATH), "--dry-run", "test-sha", "fairchild/workspaces"],
            check=False,
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )


if __name__ == "__main__":
    unittest.main()
