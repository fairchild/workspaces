#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Contract tests for Agent Factory implementation and review workflows."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
IMPLEMENT_SCRIPT = REPO_ROOT / "scripts" / "factory-implement.py"
IMPLEMENT_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "factory-implement.yml"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


factory_implement = load_module("factory_implement", IMPLEMENT_SCRIPT)


class FactoryImplementTests(unittest.TestCase):
    def issue(
        self,
        *,
        body: str = "Change Sources/Feature.swift",
        labels: tuple[str, ...] = ("agent", "task", "ready"),
    ):
        return {
            "number": 42,
            "state": "open",
            "body": body,
            "labels": [{"name": label} for label in labels],
            "assignees": [{"login": "fairchild"}],
        }

    def test_privileged_scope_matches_contributor_path_policy(self) -> None:
        privileged = (
            ".github/workflows/ci.yml",
            ".agents/memory/april/PROFILE.md",
            "scripts/notarize.sh",
            "Sources/Auth/Session.swift",
            "infra/service/private-key.ts",
        )

        for path in privileged:
            with self.subTest(path=path):
                issue = self.issue(body=f"Change `{path}`")
                self.assertTrue(factory_implement.privileged_scope(issue))

        self.assertFalse(factory_implement.privileged_scope(self.issue()))

    def test_claim_requires_open_released_non_privileged_issue_and_capacity(self) -> None:
        self.assertEqual(factory_implement.evaluate_claim(self.issue(), 0).action, "claim")
        self.assertEqual(
            factory_implement.evaluate_claim(self.issue(), 2).action,
            "wip",
        )
        self.assertEqual(
            factory_implement.evaluate_claim(
                self.issue(body="Change `.github/workflows/ci.yml`"), 0
            ).action,
            "privileged",
        )
        self.assertEqual(
            factory_implement.evaluate_claim(
                self.issue(labels=("agent", "task")), 0
            ).action,
            "skip",
        )

    def test_claim_and_rollback_payloads_preserve_unrelated_state(self) -> None:
        issue = self.issue(labels=("agent", "task", "ready", "quality"))

        claim = factory_implement.claim_payload(issue, "april-clearwater")
        self.assertEqual(claim["labels"], ["agent", "claimed", "quality", "task"])
        self.assertEqual(
            claim["assignees"],
            ["april-clearwater[bot]", "fairchild"],
        )

        claimed_issue = {
            **issue,
            "labels": [{"name": name} for name in claim["labels"]],
            "assignees": [{"login": login} for login in claim["assignees"]],
        }
        rollback = factory_implement.rollback_payload(claimed_issue, "april-clearwater")
        self.assertEqual(rollback["labels"], ["agent", "quality", "ready", "task"])
        self.assertEqual(rollback["assignees"], ["fairchild"])

    def test_workflow_contract_is_event_gated_and_uses_april_identity(self) -> None:
        workflow = IMPLEMENT_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("issues:\n    types: [labeled]", workflow)
        self.assertIn("github.event.label.name == 'ready'", workflow)
        self.assertIn("vars.AGENT_AUTOMATIONS_ENABLED == 'true'", workflow)
        self.assertIn("vars.FACTORY_IMPLEMENT_ENABLED == 'true'", workflow)
        self.assertIn("group: factory-implement-claim", workflow)
        self.assertIn(
            "group: factory-implement-${{ needs.claim.outputs.issue_number }}",
            workflow,
        )
        self.assertIn("secrets.APRIL_APP_ID", workflow)
        self.assertIn("secrets.APRIL_PRIVATE_KEY", workflow)
        self.assertIn("secrets.CLAUDE_CODE_OAUTH_TOKEN", workflow)
        self.assertIn("GH_APP_SLUG: april-clearwater", workflow)
        self.assertIn("scripts/factory-implement.py rollback", workflow)
        self.assertIn("needs.claim.result == 'failure'", workflow)


if __name__ == "__main__":
    unittest.main()
