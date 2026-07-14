#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Contract tests for Agent Factory counterpart-review admission."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-review.py"
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "factory-review.yml"
EXECUTOR_PATH = REPO_ROOT / ".github" / "workflows" / "factory-review-execute.yml"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


factory_review = load_module("factory_review", SCRIPT_PATH)


class FactoryReviewTests(unittest.TestCase):
    def pull_request(
        self,
        *,
        label: str = "author:codex",
        draft: bool = False,
        head_sha: str = "abc123",
    ):
        return {
            "state": "open",
            "draft": draft,
            "labels": [{"name": label}],
            "head": {"sha": head_sha},
        }

    def test_fixed_persona_pairs_route_to_counterpart(self) -> None:
        files = [{"filename": "Sources/Feature.swift"}]
        self.assertEqual(factory_review.counterpart_reviewer("author:april", files), "plat")
        self.assertEqual(factory_review.counterpart_reviewer("author:plat", files), "april")

    def test_generalist_authors_route_by_file_majority(self) -> None:
        application_files = [
            {"filename": "Sources/Feature.swift"},
            {"filename": "Tests/FeatureTests.swift"},
            {"filename": ".github/workflows/ci.yml"},
        ]
        platform_files = [
            {"filename": ".github/workflows/ci.yml"},
            {"filename": "infra/worker/index.ts"},
            {"filename": "scripts/helper.py"},
        ]

        for label in ("author:claude-code", "author:codex", "author:fable-orchestrator"):
            with self.subTest(label=label):
                self.assertEqual(
                    factory_review.counterpart_reviewer(label, application_files),
                    "april",
                )
                self.assertEqual(
                    factory_review.counterpart_reviewer(label, platform_files),
                    "plat",
                )

    def test_app_cannot_review_its_own_mislabeled_pull_request(self) -> None:
        pull_request = {
            **self.pull_request(label="author:codex"),
            "user": {"login": "april-clearwater[bot]"},
        }

        decision = factory_review.evaluate_review(
            pull_request,
            [{"filename": "Sources/Feature.swift"}],
            [],
            force=False,
        )

        self.assertEqual(decision.action, "skip")
        self.assertIn("cannot review its own", decision.reason)

    def test_linked_issue_is_derived_from_closing_reference(self) -> None:
        self.assertEqual(
            factory_review.linked_issue_number({"body": "Summary\n\nCloses #1091"}),
            1091,
        )
        self.assertIsNone(factory_review.linked_issue_number({"body": "Related to #1091"}))

    def test_automatic_review_deduplicates_reviewer_and_head_sha(self) -> None:
        reviews = [
            {
                "user": {"login": "april-clearwater[bot]"},
                "commit_id": "abc123",
                "state": "APPROVED",
            }
        ]
        pull_request = self.pull_request()
        files = [{"filename": "Sources/Feature.swift"}]

        automatic = factory_review.evaluate_review(
            pull_request,
            files,
            reviews,
            force=False,
        )
        requested = factory_review.evaluate_review(
            pull_request,
            files,
            reviews,
            force=True,
        )

        self.assertEqual(automatic.action, "skip")
        self.assertEqual(requested.action, "review")
        self.assertEqual(requested.reviewer, "april")

    def test_human_or_draft_pull_request_does_not_enter_review_lane(self) -> None:
        files = [{"filename": "Sources/Feature.swift"}]
        human = self.pull_request(label="quality")
        draft = self.pull_request(draft=True)

        self.assertEqual(
            factory_review.evaluate_review(human, files, [], force=False).action,
            "skip",
        )
        self.assertEqual(
            factory_review.evaluate_review(draft, files, [], force=False).action,
            "skip",
        )

    def test_workflow_uses_isolated_apps_kill_switches_and_no_review_trigger(self) -> None:
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        executor = EXECUTOR_PATH.read_text(encoding="utf-8")

        self.assertIn("types: [opened, ready_for_review, synchronize]", workflow)
        self.assertNotIn("pull_request_review:", workflow)
        self.assertIn("vars.AGENT_AUTOMATIONS_ENABLED == 'true'", workflow)
        self.assertIn("vars.FACTORY_REVIEW_ENABLED == 'true'", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertIn("workflow_run:", executor)
        self.assertIn("secrets.APRIL_APP_ID", executor)
        self.assertIn("secrets.APRIL_PRIVATE_KEY", executor)
        self.assertIn("secrets.WORKSPACE_AGENTS_APP_ID", executor)
        self.assertIn("secrets.WORKSPACE_AGENTS_PRIVATE_KEY", executor)
        self.assertIn("GH_APP_SLUG: april-clearwater", executor)
        self.assertIn("GH_APP_SLUG: workspace-agents", executor)
        self.assertIn("mentioned you in PR #${PR_NUMBER}", executor)
        self.assertIn("ref: ${{ needs.admit.outputs.head_sha }}", executor)
        self.assertIn("--expected-head", executor)
        self.assertIn("FACTORY_EXPECTED_PR_HEAD_SHA", executor)


if __name__ == "__main__":
    unittest.main()
