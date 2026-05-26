#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Migration tests for GitHub agent label cleanup.

Intent: keep one-off label migration helpers deterministic and reviewable.
These tests exercise API payload handling without calling the live GitHub API.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


migrate_agent_labels = load_module(
    "migrate_agent_labels",
    REPO_ROOT / "scripts" / "migrate-agent-labels.py",
)


class MigrateAgentLabelsTests(unittest.TestCase):
    def test_dry_run_reports_metadata_drift_without_editing(self) -> None:
        existing = [{"name": "claimed", "color": "fbca04", "description": "Old description"}]

        with (
            mock.patch.object(migrate_agent_labels, "run_json", return_value=existing),
            mock.patch.object(migrate_agent_labels, "run_checked") as run_checked,
        ):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                migrate_agent_labels.ensure_labels(
                    {item["name"]: item for item in existing},
                    apply=False,
                )

        self.assertIn("update label: claimed", output.getvalue())
        run_checked.assert_not_called()

    def test_apply_reconciles_existing_label_metadata(self) -> None:
        existing = [
            {"name": spec.name, "color": spec.color, "description": spec.description}
            for spec in migrate_agent_labels.LABELS
        ]
        for item in existing:
            if item["name"] == "claimed":
                item["color"] = "fbca04"
                item["description"] = "Old description"
            if item["name"] == "needs-human":
                item["description"] = ""

        with (
            mock.patch.object(migrate_agent_labels, "run_json", return_value=existing),
            mock.patch.object(migrate_agent_labels, "run_checked") as run_checked,
        ):
            migrate_agent_labels.ensure_labels(
                {item["name"]: item for item in existing},
                apply=True,
            )

        commands = [call.args[0] for call in run_checked.call_args_list]
        self.assertIn(
            [
                "gh",
                "label",
                "edit",
                "claimed",
                "--color",
                "1d76db",
                "--description",
                "Actively owned and in progress",
            ],
            commands,
        )
        self.assertIn(
            [
                "gh",
                "label",
                "edit",
                "needs-human",
                "--color",
                "ededed",
                "--description",
                "Needs human intervention before continuing",
            ],
            commands,
        )

    def test_webhook_simulation_uses_composable_agent_labels(self) -> None:
        content = (REPO_ROOT / "web" / "scripts" / "simulate-webhooks.ts").read_text(encoding="utf-8")

        self.assertNotIn("agent:ready", content)
        self.assertNotIn("agent:claimed", content)
        self.assertNotIn("agent:review", content)
        self.assertIn('"agent"', content)
        self.assertIn('"ready"', content)

    def test_migration_skips_deleted_legacy_labels(self) -> None:
        with mock.patch.object(migrate_agent_labels, "run_json") as run_json:
            seen = migrate_agent_labels.migrate_issues(set(), apply=False)

        self.assertEqual(seen, set())
        run_json.assert_not_called()


if __name__ == "__main__":
    unittest.main()
