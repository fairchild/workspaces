#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Tests for the runner-lane checks in audit-security-posture.py.

Intent: this check exists to notice when the workflows stop matching what the
repo says about them, and it has now failed that job twice — once as a hardcoded
`runs-on: [self-hosted, signing-host]` string that outlived the lane it named,
and once as a line matcher that read `[self-hosted, lume-macos, ARM64]` as
clean. Both were false PASSes. Every case below is a workflow that a previous
version of this check waved through.
"""

from __future__ import annotations

import importlib.util
import sys
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "audit-security-posture.py"

spec = importlib.util.spec_from_file_location("audit_security_posture", SCRIPT_PATH)
assert spec and spec.loader
audit = importlib.util.module_from_spec(spec)
sys.modules["audit_security_posture"] = audit
spec.loader.exec_module(audit)


def workflow_dir(tmp: Path, **files: str) -> Path:
    for name, body in files.items():
        suffix = ".yaml" if name.endswith("_yaml") else ".yml"
        stem = name[: -len("_yaml")] if name.endswith("_yaml") else name
        (tmp / f"{stem.replace('_', '-')}{suffix}").write_text(textwrap.dedent(body))
    return tmp


def job(runs_on: str) -> str:
    return f"""\
        name: T
        on: workflow_dispatch
        jobs:
          probe:
            runs-on: {runs_on}
            steps:
              - run: "true"
        """


class RunsOnParsing(unittest.TestCase):
    """Each shape GitHub accepts must be readable, or the check cannot see it."""

    def targets(self, body: str):
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            return audit.job_targets(workflow_dir(Path(raw), t=body))

    def test_flow_sequence(self) -> None:
        (target,) = self.targets(job("[self-hosted, signing-host]"))
        self.assertTrue(target.self_hosted)
        self.assertEqual(target.lanes, ["signing-host"])

    def test_flow_sequence_with_extra_qualifiers(self) -> None:
        """`[self-hosted, lume-macos, ARM64]` — the shape that slipped past."""
        (target,) = self.targets(job("[self-hosted, lume-macos, ARM64]"))
        self.assertTrue(target.self_hosted)
        self.assertIn("lume-macos", target.lanes)

    def test_trailing_comment(self) -> None:
        (target,) = self.targets(job("[self-hosted, tart-ui] # still here"))
        self.assertTrue(target.self_hosted)
        self.assertIn("tart-ui", target.lanes)

    def test_quoted_labels(self) -> None:
        (target,) = self.targets(job('["self-hosted", "signing-host"]'))
        self.assertTrue(target.self_hosted)

    def test_block_sequence(self) -> None:
        (target,) = self.targets(
            """\
            name: T
            on: workflow_dispatch
            jobs:
              probe:
                runs-on:
                  - self-hosted
                  - lume-macos
                steps:
                  - run: "true"
            """
        )
        self.assertTrue(target.self_hosted)
        self.assertIn("lume-macos", target.lanes)

    def test_group_labels_mapping(self) -> None:
        (target,) = self.targets(
            """\
            name: T
            on: workflow_dispatch
            jobs:
              probe:
                runs-on:
                  group: macos-runners
                  labels: [self-hosted, tart-ui]
                steps:
                  - run: "true"
            """
        )
        self.assertTrue(target.self_hosted)
        self.assertIn("tart-ui", target.lanes)

    def test_bare_scalar_self_hosted_names_no_lane(self) -> None:
        (target,) = self.targets(job("self-hosted"))
        self.assertTrue(target.self_hosted)
        self.assertEqual(target.lanes, ["self-hosted (unqualified)"])

    def test_all_qualifier_labels_still_report_a_lane(self) -> None:
        """Dropping OS/arch qualifiers must not make the target disappear."""
        (target,) = self.targets(job("[self-hosted, macOS, ARM64]"))
        self.assertTrue(target.self_hosted)
        self.assertEqual(target.lanes, ["self-hosted (unqualified)"])

    def test_hosted_runner_is_not_self_hosted(self) -> None:
        (target,) = self.targets(job("macos-15"))
        self.assertFalse(target.self_hosted)

    def test_expression_is_dynamic_not_absent(self) -> None:
        """A `${{ }}` target resolves at run time; it must never read as clean."""
        (target,) = self.targets(job("${{ fromJSON(needs.pick.outputs.runner) }}"))
        self.assertTrue(target.dynamic)

    def test_yaml_extension_is_not_skipped(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            targets = audit.job_targets(
                workflow_dir(Path(raw), probe_yaml=job("[self-hosted, lume-macos]"))
            )
        self.assertEqual(len(targets), 1)

    def test_runs_on_inside_a_shell_block_is_not_a_job(self) -> None:
        """The false-positive direction: a literal in `run:` is not a runner."""
        targets = self.targets(
            """\
            name: T
            on: workflow_dispatch
            jobs:
              probe:
                runs-on: ubuntu-latest
                steps:
                  - run: |
                      echo "runs-on: [self-hosted, lume-macos]"
            """
        )
        self.assertEqual(len(targets), 1)
        self.assertFalse(targets[0].self_hosted)

    def test_reusable_workflow_call_has_no_runner(self) -> None:
        targets = self.targets(
            """\
            name: T
            on: workflow_dispatch
            jobs:
              probe:
                uses: ./.github/workflows/_evidence.yml
            """
        )
        self.assertEqual(targets, [])

    def test_unparseable_workflow_is_flagged_not_skipped(self) -> None:
        targets = self.targets("jobs:\n  probe:\n   - [unbalanced\n")
        self.assertTrue(any(target.dynamic for target in targets))


class ReleaseLane(unittest.TestCase):
    """The repo's actual workflows, checked as shipped."""

    def test_no_release_job_targets_a_self_hosted_runner(self) -> None:
        targets = audit.job_targets(REPO_ROOT / ".github/workflows")
        offenders = [t.job for t in targets if t.workflow == "release.yml" and t.self_hosted]
        self.assertEqual(offenders, [], f"release jobs on self-hosted runners: {offenders}")

    def test_no_workflow_targets_a_retired_lane(self) -> None:
        targets = audit.job_targets(REPO_ROOT / ".github/workflows")
        offenders = [
            f"{t.workflow}:{t.job}"
            for t in targets
            if {label.lower() for label in t.labels} & audit.RETIRED_RUNNER_LABELS
        ]
        self.assertEqual(offenders, [], f"retired lanes targeted: {offenders}")

    def test_partial_revert_of_the_signing_job_is_caught(self) -> None:
        """A whole-file substring check passed this: other jobs stay hosted."""
        import tempfile

        release = """\
            name: Release
            on: workflow_dispatch
            jobs:
              build-sign-notarize-release:
                runs-on: [self-hosted, signing-host]
                environment: release
                steps:
                  - run: "true"
              publish-github-release:
                runs-on: macos-15
                steps:
                  - run: "true"
            """
        with tempfile.TemporaryDirectory() as raw:
            targets = audit.job_targets(workflow_dir(Path(raw), release=release))
        offenders = [t.job for t in targets if t.workflow == "release.yml" and t.self_hosted]
        self.assertEqual(offenders, ["build-sign-notarize-release"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
