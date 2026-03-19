#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Stdlib tests for run-contributor evidence reconciliation."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "run-contributor.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


run_contributor = load_module("run_contributor", SCRIPT_PATH)


class RunContributorEvidenceTests(unittest.TestCase):
    maxDiff = None

    def test_reconcile_pending_ci_evidence_includes_uploaded_screenshot_links(self) -> None:
        body = "\n".join(
            [
                "## Evidence Status",
                "- [pending-ci] Post-setup screenshot -- CI evidence job will capture screenshot",
                "",
                "## Validation",
                "- blocked on evidence",
            ]
        )

        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            screenshot_upload_succeeded=True,
            screenshot_urls=[
                ("01-launch", "https://evidence.example/workspaces/pr-42/01-launch.png"),
                ("02-final", "https://evidence.example/workspaces/pr-42/02-final.png"),
            ],
        )

        self.assertIn(
            "- [complete] Post-setup screenshot -- captured on self-hosted macOS CI: "
            "[01-launch](https://evidence.example/workspaces/pr-42/01-launch.png), "
            "[02-final](https://evidence.example/workspaces/pr-42/02-final.png)",
            reconciled,
        )

    def test_reconcile_pending_ci_evidence_blocks_missing_screenshot_upload(self) -> None:
        body = "## Evidence Status\n- [pending-ci] Final screenshot -- CI evidence job will capture screenshot\n"

        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            screenshot_upload_succeeded=False,
            screenshot_urls=[],
        )

        self.assertEqual(
            reconciled,
            "## Evidence Status\n"
            "- [blocked] Final screenshot -- self-hosted macOS CI captured screenshots but R2 upload failed; "
            "see workflow artifacts\n",
        )

    def test_reconcile_pending_ci_evidence_blocks_missing_uploaded_urls(self) -> None:
        body = "## Evidence Status\n- [pending-ci] Final screenshot -- CI evidence job will capture screenshot\n"

        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            screenshot_upload_succeeded=True,
            screenshot_urls=[],
        )

        self.assertEqual(
            reconciled,
            "## Evidence Status\n"
            "- [blocked] Final screenshot -- self-hosted macOS CI captured screenshots but no R2 URLs were recorded; "
            "see workflow artifacts\n",
        )


if __name__ == "__main__":
    unittest.main()
