#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Stdlib tests for Peter Planner runtime helpers."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


run_planner = load_module("run_planner", REPO_ROOT / ".agents" / "scripts" / "run-planner.py")
validator = load_module(
    "validate_agent_output",
    REPO_ROOT / ".agents" / "scripts" / "validate-agent-output.py",
)
CATALOG = run_planner.load_label_catalog(REPO_ROOT / ".agents" / "config" / "peter-planner.toml")


class ValidateAgentOutputTests(unittest.TestCase):
    def test_plan_requires_non_empty_issue_list(self) -> None:
        with self.assertRaises(validator.ValidationError):
            validator.validate_data(
                {
                    "action": "plan",
                    "discussion_number": 43,
                    "milestone_name": None,
                    "issues": [],
                }
            )

    def test_extract_structured_skips_preamble_before_frontmatter(self) -> None:
        text = (
            "Now I have enough context. Let me write up a review.\n"
            "\n"
            "---\n"
            "action: review_pr\n"
            "persona: April Clearwater, Application Lead\n"
            "pr_number: 94\n"
            "---\n"
            "\n"
            "## Great PR\n"
            "Looks good to me."
        )
        data = validator.extract_structured(text)
        self.assertEqual(data["action"], "review_pr")
        self.assertEqual(data["pr_number"], 94)
        self.assertIn("Looks good to me", data["body"])

    def test_plan_rejects_duplicate_issue_titles(self) -> None:
        with self.assertRaises(validator.ValidationError):
            validator.validate_data(
                {
                    "action": "plan",
                    "discussion_number": 43,
                    "milestone_name": None,
                    "issues": [
                        {"title": "One", "body": "A", "labels": ["enhancement"]},
                        {"title": "one", "body": "B", "labels": ["enhancement"]},
                    ],
                }
            )


class RunPlannerTests(unittest.TestCase):
    def make_discussion(self, number: int = 43, title: str | None = None, comments=None):
        return {
            "id": "DISCUSSION_1",
            "number": number,
            "url": f"https://github.com/fairchild/workspaces/discussions/{number}",
            "title": title or "[task] [idea] Isolate intrusive CI jobs onto a Tart VM runner lane",
            "body": "Body",
            "comments": {"nodes": comments or []},
        }

    def make_plan(self, issue_titles: list[str], discussion=None):
        discussion = discussion or self.make_discussion()
        return run_planner.normalize_plan(
            {
                "action": "plan",
                "discussion_number": discussion["number"],
                "milestone_name": None,
                "issues": [
                    {
                        "title": title,
                        "body": f"## Context\n{title}",
                        "labels": ["ci"] if index == 0 else ["ui"],
                        "priority": index + 1,
                    }
                    for index, title in enumerate(issue_titles)
                ],
            },
            discussion,
            CATALOG,
        )

    def test_normalize_labels_maps_aliases_and_defaults(self) -> None:
        labels = run_planner.normalize_labels(["ci", "ui"], CATALOG)
        self.assertEqual(
            labels,
            ["enhancement", "agent:task", "area: platform", "area: ui"],
        )

    def test_normalize_plan_derives_milestone_from_discussion_title(self) -> None:
        discussion = self.make_discussion()
        plan = self.make_plan(["One", "Two", "Three"], discussion=discussion)
        self.assertEqual(
            plan.milestone_name,
            "Isolate intrusive CI jobs onto a Tart VM runner lane",
        )

    def test_build_execution_state_reuses_marked_issue_and_milestone(self) -> None:
        discussion = self.make_discussion(
            comments=[
                {
                    "id": "C1",
                    "createdAt": "2026-03-12T02:00:00Z",
                    "body": run_planner.comment_marker(43, "ack"),
                },
                {
                    "id": "C2",
                    "createdAt": "2026-03-12T02:10:00Z",
                    "body": run_planner.comment_marker(43, "planned"),
                },
            ]
        )
        plan = self.make_plan(["Audit runners", "Move perf", "Document lane"], discussion=discussion)
        existing_issues = [
            {
                "number": 101,
                "title": plan.issues[0].title,
                "body": plan.issues[0].body_with_marker,
                "url": "https://github.com/fairchild/workspaces/issues/101",
                "labels": [],
            },
            {
                "number": 102,
                "title": plan.issues[1].title,
                "body": plan.issues[1].body_with_marker,
                "url": "https://github.com/fairchild/workspaces/issues/102",
                "labels": [],
            },
            {
                "number": 103,
                "title": plan.issues[2].title,
                "body": plan.issues[2].body_with_marker,
                "url": "https://github.com/fairchild/workspaces/issues/103",
                "labels": [],
            },
        ]
        milestones = [
            {
                "number": 9,
                "title": plan.milestone_name,
                "description": plan.milestone_description,
                "open_issues": 3,
                "creator": {"login": "github-actions[bot]"},
                "html_url": "https://github.com/fairchild/workspaces/milestone/9",
            }
        ]

        execution = run_planner.build_execution_state(discussion, plan, existing_issues, milestones)
        self.assertTrue(execution.already_planned)
        self.assertEqual(execution.existing_milestone["number"], 9)
        self.assertTrue(all(item.existing_issue is not None for item in execution.issues))

    def test_build_execution_state_reuses_issue_when_title_drifts(self) -> None:
        discussion = self.make_discussion(
            comments=[
                {
                    "id": "C1",
                    "createdAt": "2026-03-12T02:10:00Z",
                    "body": run_planner.comment_marker(43, "planned"),
                }
            ]
        )
        plan = self.make_plan(
            [
                "Replace bare self-hosted runner label",
                "Stand up tart-ui runner",
                "Move `perf-validation` job to `tart-ui` runner and make it manual/scheduled",
            ],
            discussion=discussion,
        )
        prior_title = (
            "Move `perf-validation` job to `tart-ui` runner and make it "
            "manual/scheduled instead of push-triggered"
        )
        existing_issues = [
            {
                "number": 103,
                "title": prior_title,
                "body": run_planner.compose_issue_body(
                    "## Context\nBody",
                    discussion["url"],
                    discussion["number"],
                    run_planner.issue_slug(prior_title),
                ),
                "url": "https://github.com/fairchild/workspaces/issues/103",
                "labels": [],
            }
        ]

        execution = run_planner.build_execution_state(discussion, plan, existing_issues, [])
        self.assertEqual(execution.issues[2].existing_issue["number"], 103)

    def test_retry_partial_state_keeps_marked_ack_and_orphan_cleanup(self) -> None:
        discussion = self.make_discussion(
            comments=[
                {
                    "id": "legacy-ack",
                    "createdAt": "2026-03-12T01:00:00Z",
                    "body": "**Agent**: `workspaces` | **Branch**: `main`\n\n*Peter Planner*\n\nWorking on it — I'll break this into issues shortly.",
                },
                {
                    "id": "marked-ack",
                    "createdAt": "2026-03-12T02:00:00Z",
                    "body": run_planner.comment_marker(43, "ack"),
                },
            ]
        )
        plan = self.make_plan(["Audit runners", "Move perf", "Document lane"], discussion=discussion)
        existing_issues = [
            {
                "number": 101,
                "title": plan.issues[0].title,
                "body": plan.issues[0].body_with_marker,
                "url": "https://github.com/fairchild/workspaces/issues/101",
                "labels": [],
            }
        ]
        milestones = [
            {
                "number": 2,
                "title": "CI Runner Lane Isolation",
                "description": None,
                "open_issues": 0,
                "creator": {"login": "github-actions[bot]"},
                "html_url": "https://github.com/fairchild/workspaces/milestone/2",
            }
        ]

        execution = run_planner.build_execution_state(discussion, plan, existing_issues, milestones)
        self.assertFalse(execution.already_planned)
        self.assertEqual(execution.ack_comment["id"], "marked-ack")
        self.assertEqual(execution.stale_ack_comment_ids, ["legacy-ack"])
        self.assertEqual(execution.orphan_milestone_numbers, [2])
        self.assertIsNotNone(execution.issues[0].existing_issue)
        self.assertIsNone(execution.issues[1].existing_issue)
        self.assertIsNone(execution.issues[2].existing_issue)

    def test_discussion_has_completed_plan_requires_summary_and_issue_marker(self) -> None:
        comments = [{"id": "planned", "body": run_planner.comment_marker(43, "planned")}]
        issues = [{"body": run_planner.issue_marker(43, "audit-runners")}]
        self.assertTrue(run_planner.discussion_has_completed_plan(43, comments, issues))
        self.assertFalse(run_planner.discussion_has_completed_plan(43, comments, []))

    def test_has_summary_issue_set_reads_issue_numbers_from_summary_comment(self) -> None:
        comments = [
            {
                "id": "planned",
                "body": "\n".join(
                    [
                        run_planner.comment_marker(43, "planned"),
                        "",
                        "- #61 — Audit runners",
                        "- #62 — Provision tart-ui runner",
                        "- #63 — Move perf-validation workflow",
                    ]
                ),
            }
        ]
        issues = [
            {"number": 61, "body": run_planner.issue_marker(43, "audit-runners")},
            {"number": 62, "body": run_planner.issue_marker(43, "provision-tart-ui-runner")},
            {"number": 63, "body": run_planner.issue_marker(43, "move-perf-validation")},
        ]
        self.assertTrue(run_planner.has_summary_issue_set(43, comments, issues))

    def test_titles_loosely_match_minor_suffix_change(self) -> None:
        self.assertTrue(
            run_planner.titles_loosely_match(
                "Move `perf-validation` job to `tart-ui` runner and make it manual/scheduled",
                (
                    "Move `perf-validation` job to `tart-ui` runner and make it "
                    "manual/scheduled instead of push-triggered"
                ),
            )
        )

    def test_run_checked_surfaces_timeout_as_planner_error(self) -> None:
        with mock.patch.object(
            run_planner.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(cmd=["npx"], timeout=7),
        ):
            with self.assertRaises(run_planner.PlannerError) as context:
                run_planner.run_checked(["npx", "claude"], timeout=7)
        self.assertIn("timed out after 7s", str(context.exception))

    def test_load_plan_output_uses_fixture_file_without_claude(self) -> None:
        discussion = self.make_discussion()
        fixture = (
            "---\n"
            "action: plan\n"
            "discussion_number: 43\n"
            "milestone_name: null\n"
            "---\n"
            "\n"
            "---\n"
            "title: Audit runners\n"
            "labels: [ci]\n"
            "priority: 1\n"
            "---\n"
            "\n"
            "## Context\n"
            "Body"
        )
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            handle.write(fixture)
            fixture_path = Path(handle.name)
        args = run_planner.argparse.Namespace(
            discussion_number=43,
            dry_run=True,
            plan_file=fixture_path,
            mode="cli",
        )
        try:
            with mock.patch.object(run_planner, "run_claude", side_effect=AssertionError("should not run")):
                raw_output = run_planner.load_plan_output(args, discussion, CATALOG, {})
            self.assertEqual(raw_output, fixture)
        finally:
            fixture_path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
