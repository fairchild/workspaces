#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for the release performance-benchmark evidence gate.

Intent: the gate replaced a check that measured perf during release and failed on
a display-less runner. What matters now is that it grades staleness correctly and
never treats missing evidence as good news — #1238's rule that a skipped
measurement must not be indistinguishable from a passing one.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "check-perf-benchmarks.py"

spec = importlib.util.spec_from_file_location("check_perf_benchmarks", SCRIPT_PATH)
assert spec and spec.loader
gate = importlib.util.module_from_spec(spec)
sys.modules["check_perf_benchmarks"] = gate
spec.loader.exec_module(gate)

HEADER = "release_tag,commit,timestamp,scenario,build_kind,protocol_epoch,notes\n"


def write_csv(path: Path, tags: list[str]) -> None:
    rows = "".join(f"{tag},abc1234,2026-01-01T00:00:00Z,installed_clean_shell,installed,e1,\n" for tag in tags)
    path.write_text(HEADER + rows)


class StalenessTests(unittest.TestCase):
    """Distance is counted in releases, not commits or days."""

    TAGS = ["v0.21.0", "v0.22.0", "v0.23.0", "v0.24.0"]

    def test_release_with_its_own_row_is_current(self) -> None:
        self.assertEqual(gate.releases_since(self.TAGS, {"v0.24.0"}, "v0.24.0"), 0)

    def test_one_release_since_the_last_benchmark(self) -> None:
        self.assertEqual(gate.releases_since(self.TAGS, {"v0.23.0"}, "v0.24.0"), 1)

    def test_two_releases_since_the_last_benchmark(self) -> None:
        self.assertEqual(gate.releases_since(self.TAGS, {"v0.22.0"}, "v0.24.0"), 2)

    def test_unreleased_tag_still_counts_against_the_newest_benchmark(self) -> None:
        # Cutting v0.25.0, which has no tag yet, with only v0.23.0 measured.
        self.assertEqual(gate.releases_since(self.TAGS, {"v0.23.0"}, "v0.25.0"), 2)

    def test_benchmark_referencing_an_unknown_tag_is_maximally_stale(self) -> None:
        # A row naming a tag that never shipped proves nothing about freshness.
        self.assertEqual(gate.releases_since(self.TAGS, {"v0.01.0"}, "v0.24.0"), 4)

    def test_unknown_tag_blocks_even_when_history_is_shorter_than_the_threshold(self) -> None:
        # Short history must not make "cannot verify" look like "nearly current".
        self.assertGreaterEqual(gate.releases_since([], {"v0.23.0"}, "v0.25.0"), gate.BLOCK_AFTER)


class GateFixture:
    """A throwaway git repo with real release tags, plus a CSV to point at."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.csv = self.root / "performance_benchmarks.csv"
        run = lambda *args: subprocess.run(args, cwd=self.root, check=True, timeout=30, capture_output=True)
        run("git", "init", "-q")
        run("git", "config", "user.email", "t@example.com")
        run("git", "config", "user.name", "t")
        # Real tags: the gate measures distance in releases, so a repo without
        # them exercises only the degenerate "cannot verify" path.
        for tag in ("v0.23.0", "v0.24.0", "v0.25.0"):
            (self.root / "f").write_text(tag)
            run("git", "add", "f")
            run("git", "commit", "-qm", tag)
            run("git", "tag", tag)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def gate_result(self, tag: str, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--tag",
                tag,
                "--csv",
                str(self.csv),
                "--repo-root",
                str(self.root),
                *extra,
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )

    def run_gate(self, tag: str) -> int:
        return self.gate_result(tag).returncode


class ExitCodeTests(GateFixture, unittest.TestCase):
    """The gate's contract with the release workflow is its exit code."""

    def test_missing_file_blocks_rather_than_passes(self) -> None:
        # The whole point: no evidence must not read as good evidence.
        self.assertEqual(self.run_gate("v0.25.0"), 1)

    def test_header_only_file_blocks(self) -> None:
        self.csv.write_text(HEADER)
        self.assertEqual(self.run_gate("v0.25.0"), 1)

    def test_blank_release_tag_does_not_count_as_evidence(self) -> None:
        self.csv.write_text(HEADER + ",abc1234,2026-01-01T00:00:00Z,s,installed,e1,\n")
        self.assertEqual(self.run_gate("v0.25.0"), 1)

    def test_current_release_passes(self) -> None:
        write_csv(self.csv, ["v0.25.0"])
        self.assertEqual(self.run_gate("v0.25.0"), 0)

    def test_one_release_stale_warns_but_does_not_block(self) -> None:
        write_csv(self.csv, ["v0.24.0"])
        self.assertEqual(self.run_gate("v0.25.0"), 0)

    def test_two_releases_stale_blocks(self) -> None:
        # No tags exist in this fresh repo, so v0.23.0 sits 2 behind v0.25.0.
        write_csv(self.csv, ["v0.23.0"])
        self.assertEqual(self.run_gate("v0.25.0"), 1)


class GithubAnnotationTests(GateFixture, unittest.TestCase):
    """`--format github` is reachable only from release.yml.

    CI runs the gate in plain format, so without these the annotation branch in
    emit() executes for the first time during a release — and a typo confined to
    that branch fails the release rather than the PR that wrote it.
    """

    def test_blocking_gate_annotates_as_an_error(self) -> None:
        result = self.gate_result("v0.25.0", "--format", "github")
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error::", result.stdout)

    def test_one_release_stale_annotates_as_a_warning_without_blocking(self) -> None:
        write_csv(self.csv, ["v0.24.0"])
        result = self.gate_result("v0.25.0", "--format", "github")
        self.assertEqual(result.returncode, 0)
        self.assertIn("::warning::", result.stdout)

    def test_plain_format_stays_free_of_annotations(self) -> None:
        write_csv(self.csv, ["v0.24.0"])
        result = self.gate_result("v0.25.0")
        self.assertEqual(result.returncode, 0)
        self.assertNotIn("::warning::", result.stdout)
        self.assertNotIn("::error::", result.stdout)


class CommittedDataTests(unittest.TestCase):
    """The real CSV must stay readable by the gate that depends on it."""

    def test_committed_csv_parses_and_has_release_tags(self) -> None:
        tags = gate.benchmarked_tags(REPO_ROOT / "docs" / "performance_benchmarks.csv")
        self.assertTrue(tags, "committed benchmarks CSV yields no release tags")
        for tag in tags:
            self.assertTrue(tag.startswith("v"), f"release_tag should be a v* tag: {tag}")

    def test_explainer_exists_alongside_the_data(self) -> None:
        self.assertTrue((REPO_ROOT / "docs" / "performance_benchmarks.md").is_file())


if __name__ == "__main__":
    unittest.main()
