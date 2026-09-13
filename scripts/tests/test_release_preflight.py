#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Release-preflight tests for the gate that previews a signing decision.

These tests run without network, secrets, UI access, or live GitHub mutation.
They protect the release gate that verifies CI on the exact SHA being
published, and the parity between the paths ci.yml watches and the paths
preflight reports on.
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


def normalize(path: str) -> str:
    """Collapse a subtree pattern to the subtree it names.

    ci.yml writes `Sources/**`; the shell writes `Sources/*`, because `*` in a
    bash `[[ == ]]` pattern already spans `/`. They mean the same subtree.
    """
    return re.sub(r"/\*\*?$", "", path)


def ci_workflow_paths() -> set[str]:
    """Every entry in ci.yml's push path filter."""
    body = CI_WORKFLOW_PATH.read_text()
    push_block = body[body.index("  push:") : body.index("  pull_request:")]
    return {normalize(p) for p in re.findall(r'^\s+- "([^"]+)"$', push_block, re.M)}


def preflight_relevant_paths() -> set[str]:
    """Every entry in release-preflight.sh's CI_RELEVANT_PATH_PATTERNS array."""
    body = SCRIPT_PATH.read_text()
    block = body[body.index("CI_RELEVANT_PATH_PATTERNS=(") :]
    block = block[: block.index("\n)")]
    return {normalize(p) for p in re.findall(r'^\s+"([^"]+)"$', block, re.M)}


class CiRelevantPathParityTests(unittest.TestCase):
    """release-preflight.sh hand-duplicates ci.yml's path filter.

    The two lists decide the same thing from opposite ends: which changes
    oblige a build-and-test run. Preflight no longer waives the gate on that
    answer, but it still reports "build inputs changed since the last green
    build" from it, and a list that has drifted makes that report reassure in
    the wrong direction. Nothing coupled them, so this does.

    The earlier version of this test compared only the `scripts/` entries, and
    the five that are not — .mise.toml, mise.lock, the xcodeproj, ci_scripts
    and XcodeCloudHarness — had drifted out of the shell list unnoticed.
    """

    def test_every_ci_watched_path_is_release_relevant(self) -> None:
        missing = ci_workflow_paths() - preflight_relevant_paths()
        self.assertEqual(
            missing,
            set(),
            "ci.yml triggers build-and-test for these paths but "
            "release-preflight.sh does not list them, so preflight reports a "
            "commit as touching no build inputs when CI was watching them: "
            f"{sorted(missing)}",
        )

    def test_every_release_relevant_path_is_ci_watched(self) -> None:
        missing = preflight_relevant_paths() - ci_workflow_paths()
        self.assertEqual(
            missing,
            set(),
            "release-preflight.sh treats these paths as build inputs but "
            "ci.yml never runs build-and-test for them, so preflight reports "
            "a build input that no build covers: "
            f"{sorted(missing)}",
        )


class RequiredGateTests(unittest.TestCase):
    def test_newest_trusted_run_decides(self) -> None:
        with PreflightFixture(
            ci_runs=[(100, "completed", "failure"), (200, "completed", "success")]
        ) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("CI (build-and-test): PASS", result.stdout)
        self.assertIn("Preflight passed.", result.stdout)

    def test_failed_run_fails_the_gate(self) -> None:
        with PreflightFixture(ci_runs=[(100, "completed", "failure")]) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("CI (build-and-test): FAIL (failure)", result.stdout)

    def test_cancelled_run_fails_the_gate(self) -> None:
        with PreflightFixture(ci_runs=[(100, "completed", "cancelled")]) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("CI (build-and-test): FAIL (cancelled)", result.stdout)

    def test_absent_run_fails_and_names_the_dispatch(self) -> None:
        with PreflightFixture(ci_runs=[]) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("CI (build-and-test): NOT FOUND", result.stdout)
        self.assertIn("gh workflow run ci.yml --ref main", result.stdout)

    def test_fallback_check_run_does_not_satisfy_the_gate(self) -> None:
        """The defect this script was rewritten for.

        `build-and-test-fallback` runs a weaker build, and under `workflow_run`
        GitHub attaches its check-run to the default branch head rather than to
        the commit CI ran on. A green one on the SHA is not a build of the SHA.
        """
        with PreflightFixture(
            ci_runs=[],
            check_runs=[
                ("build-and-test-fallback", "completed", "success", "2026-06-06T10:00:00Z")
            ],
        ) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("CI (build-and-test): NOT FOUND", result.stdout)

    def test_absent_required_ci_stays_readable_in_dry_run(self) -> None:
        with PreflightFixture(ci_runs=[]) as fixture:
            result = fixture.run(dry_run=True)

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("CI (build-and-test): NOT FOUND (dry-run: continuing)", result.stdout)
        self.assertIn("Preflight passed.", result.stdout)


class OperatorContextTests(unittest.TestCase):
    def test_reports_build_inputs_changed_since_the_last_green_ancestor(self) -> None:
        with PreflightFixture(
            ci_runs=[],
            green_ancestor="a" * 40,
            compare_files=["docs/notes.md", "Sources/App.swift"],
        ) as fixture:
            result = fixture.run()

        self.assertIn(f"Last green CI ancestor: {'a' * 12}", result.stdout)
        self.assertIn("Build inputs changed since it: 1", result.stdout)
        self.assertIn("Sources/App.swift", result.stdout)
        self.assertNotIn("docs/notes.md", result.stdout)

    def test_reports_no_build_inputs_when_only_unwatched_files_changed(self) -> None:
        with PreflightFixture(
            ci_runs=[],
            green_ancestor="b" * 40,
            compare_files=["docs/notes.md", "scripts/factory-implement.py"],
        ) as fixture:
            result = fixture.run()

        self.assertIn("Build inputs changed since it: none", result.stdout)

    def test_context_does_not_waive_the_gate(self) -> None:
        """No build inputs changed, and the release is still refused."""
        with PreflightFixture(
            ci_runs=[], green_ancestor="c" * 40, compare_files=["CHANGELOG.md"]
        ) as fixture:
            result = fixture.run()

        self.assertIn("Build inputs changed since it: none", result.stdout)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Preflight FAILED", result.stdout)


class AdvisoryPerfTests(unittest.TestCase):
    def test_newest_matching_check_run_wins(self) -> None:
        with PreflightFixture(
            ci_runs=[(200, "completed", "success")],
            check_runs=[
                ("perf-validation", "completed", "failure", "2026-06-06T10:00:00Z"),
                ("perf-validation", "completed", "success", "2026-06-06T10:02:00Z"),
            ],
        ) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Perf validation: PASS", result.stdout)

    def test_perf_regression_warns_without_blocking(self) -> None:
        with PreflightFixture(
            ci_runs=[(200, "completed", "success")],
            check_runs=[
                ("perf-validation", "completed", "failure", "2026-06-06T10:00:00Z")
            ],
        ) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("WARN (failure)", result.stdout)


class PreflightFixture:
    """A fake `gh` that answers only the calls release-preflight.sh makes."""

    def __init__(
        self,
        *,
        ci_runs: list[tuple[int, str, str]] | None = None,
        check_runs: list[tuple[str, str, str, str]] | None = None,
        green_ancestor: str | None = None,
        compare_files: list[str] | None = None,
    ) -> None:
        self.ci_runs = ci_runs or []
        self.check_runs = check_runs or []
        self.green_ancestor = green_ancestor
        self.compare_files = compare_files or []
        self.root = Path(tempfile.mkdtemp(prefix="ReleasePreflightTests-"))

    def __enter__(self) -> "PreflightFixture":
        canned = self.root / "canned"
        canned.mkdir()
        (canned / "ci_runs_head").write_text(
            "".join(f"{i}\t{s}\t{c}\n" for i, s, c in self.ci_runs), encoding="utf-8"
        )
        (canned / "ci_runs_success").write_text(
            f"{self.green_ancestor}\n" if self.green_ancestor else "", encoding="utf-8"
        )
        (canned / "compare_status").write_text(
            "ahead\n" if self.green_ancestor else "", encoding="utf-8"
        )
        (canned / "compare_files").write_text(
            "".join(f"{f}\n" for f in self.compare_files), encoding="utf-8"
        )
        (canned / "check_runs").write_text(
            "".join(f"{n}\t{s}\t{c}\t{t}\n" for n, s, c, t in self.check_runs),
            encoding="utf-8",
        )

        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        fake_gh = fake_bin / "gh"
        fake_gh.write_text(
            textwrap.dedent(
                """\
                #!/bin/sh
                # The script passes --jq filters; this stub answers with the
                # already-filtered shape each call site expects.
                args=" $* "
                canned="$FAKE_GH_CANNED"

                case "$args" in
                    *"/actions/workflows/ci.yml/runs?head_sha="* )
                        cat "$canned/ci_runs_head" ;;
                    *"/actions/workflows/ci.yml/runs?branch=main&status=success"* )
                        cat "$canned/ci_runs_success" ;;
                    *"/compare/"*".status"* )
                        cat "$canned/compare_status" ;;
                    *"/compare/"* )
                        cat "$canned/compare_files" ;;
                    *"/check-runs"* )
                        cat "$canned/check_runs" ;;
                    * )
                        printf 'unexpected gh invocation: %s\\n' "$*" >&2
                        exit 64 ;;
                esac
                """
            ),
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)
        return self

    def __exit__(self, *args: object) -> None:
        shutil.rmtree(self.root)

    def run(self, *, dry_run: bool = False) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PATH"] = f"{self.root / 'bin'}:{environment['PATH']}"
        environment["FAKE_GH_CANNED"] = str(self.root / "canned")

        argv = ["/bin/bash", str(SCRIPT_PATH)]
        if dry_run:
            argv.append("--dry-run")
        argv += ["test-sha", "fairchild/workspaces"]

        return subprocess.run(
            argv,
            check=False,
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )


if __name__ == "__main__":
    unittest.main()
