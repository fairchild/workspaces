#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Guard the ordering and artifact boundary of the one-approval release flow."""

import unittest
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = yaml.load((ROOT / ".github/workflows/release.yml").read_text(), Loader=yaml.BaseLoader)
JOBS = WORKFLOW["jobs"]


class ReleaseWorkflowTests(unittest.TestCase):
    def test_only_main_ci_completion_and_explicit_dispatch_start_candidates(self):
        self.assertEqual(set(WORKFLOW["on"]), {"workflow_run", "workflow_dispatch"})
        self.assertEqual(WORKFLOW["on"]["workflow_run"], {"workflows": ["CI"], "types": ["completed"], "branches": ["main"]})
        self.assertIn("github.ref == 'refs/heads/main'", JOBS["qualify"]["if"])
        self.assertNotIn("environment", JOBS["qualify"])
        self.assertEqual(JOBS["qualify"]["runs-on"], "ubuntu-latest")
        self.assertEqual(JOBS["build-sign-notarize-release"]["needs"], "qualify")
        self.assertIn("eligible == 'true'", JOBS["build-sign-notarize-release"]["if"])

    def test_ordinary_main_runs_do_not_share_stable_release_concurrency(self):
        group = WORKFLOW["concurrency"]["group"]
        self.assertIn("startsWith(github.event.workflow_run.head_commit.message, 'release: v')", group)
        self.assertIn("|| github.event.workflow_run.head_sha", group)
        self.assertEqual(WORKFLOW["concurrency"]["cancel-in-progress"], "false")

    def test_validation_precedes_the_only_publication_gate(self):
        self.assertEqual(JOBS["build-sign-notarize-release"]["environment"], "release")
        self.assertNotIn("environment", JOBS["validate-candidate"])
        publish = JOBS["publish-github-release"]
        self.assertEqual(publish["environment"]["name"], "release-publication")
        self.assertIn("validate-candidate", publish["needs"])
        self.assertIn("build-sign-notarize-release", JOBS["validate-candidate"]["needs"])
        for name, job in JOBS.items():
            self.assertEqual(job["permissions"]["contents"], "write" if name == "publish-github-release" else "read")
            if name != "build-sign-notarize-release":
                self.assertNotIn("secrets.", str(job))

    def test_publisher_downloads_the_validated_immutable_artifact(self):
        downloads = []
        for name in ("validate-candidate", "publish-github-release"):
            job = JOBS[name]
            step = next(s for s in job["steps"] if s.get("uses", "").startswith("actions/download-artifact@"))
            self.assertEqual(step["with"]["digest-mismatch"], "error")
            self.assertNotIn("name", step["with"])
            downloads.append(step["with"]["artifact-ids"])
            checkout = job["steps"][0]
            self.assertEqual(checkout["with"]["ref"], "${{ needs.qualify.outputs.source }}")
        self.assertEqual(downloads[0], downloads[1])
        self.assertIn("outputs.artifact_id", downloads[0])
        publisher = str(JOBS["publish-github-release"]["steps"])
        self.assertNotIn("build-release.sh", publisher)
        self.assertNotIn("notarize.sh", publisher)
        self.assertIn("release-candidate.py publish", publisher)

    def test_readiness_and_public_stable_route_have_explicit_checks(self):
        steps = JOBS["validate-candidate"]["steps"]
        commands = [s.get("run", "") for s in steps]
        self.assertLess(next(i for i, s in enumerate(commands) if "verify-release-candidate.sh" in s), next(i for i, s in enumerate(commands) if "release-candidate.py summary" in s))
        public = JOBS["validate-published-release-assets"]
        self.assertIn("publish-github-release", public["needs"])
        final = public["steps"][-1]
        self.assertEqual(final["if"], "needs.qualify.outputs.channel == 'stable'")
        self.assertIn("/releases/latest/download/appcast.xml", final["run"])
        self.assertIn("cmp release-downloads/appcast.xml release-downloads/stable-appcast.xml", final["run"])

    def test_perf_gate_grades_the_candidate_version_without_measuring(self):
        step = next(s for s in JOBS["build-sign-notarize-release"]["steps"] if s.get("name") == "Verify release performance benchmarks are current")
        self.assertIn('--tag "$(./scripts/release-version.sh print-tag)"', step["run"])
        self.assertIn("pipefail", step["run"])
        self.assertNotIn("verify-installed-perf", str(JOBS))


if __name__ == "__main__":
    unittest.main()
