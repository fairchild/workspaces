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
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "release-preflight.sh"


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
