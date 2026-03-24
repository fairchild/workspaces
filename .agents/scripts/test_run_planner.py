#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Stdlib tests for Peter Planner runtime helpers."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
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


run_planner = load_module(
    "run_planner",
    REPO_ROOT / ".agents" / "skills" / "peter-planner" / "scripts" / "run-planner.py",
)
validator = load_module(
    "validate_agent_output",
    REPO_ROOT / ".agents" / "skills" / "peter-planner" / "scripts" / "validate-agent-output.py",
)
contributor_validator = load_module(
    "cofounder_validate_agent_output",
    REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "validate-agent-output.py",
)
run_contributor = load_module(
    "run_contributor",
    REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "run-contributor.py",
)
sync_execution_state = load_module(
    "sync_execution_state",
    REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "sync-execution-state.py",
)
CATALOG = run_planner.load_label_catalog(
    REPO_ROOT / ".agents" / "skills" / "peter-planner" / "config" / "peter-planner.toml"
)


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
                        {
                            "title": "One",
                            "body": "A",
                            "labels": ["enhancement"],
                            "priority": 1,
                            "blocked_by": [],
                            "requested_evidence": ["swift test"],
                        },
                        {
                            "title": "one",
                            "body": "B",
                            "labels": ["enhancement"],
                            "priority": 2,
                            "blocked_by": [],
                            "requested_evidence": ["swift test"],
                        },
                    ],
                }
            )

    def test_plan_requires_requested_evidence(self) -> None:
        with self.assertRaises(validator.ValidationError):
            validator.validate_data(
                {
                    "action": "plan",
                    "discussion_number": 43,
                    "milestone_name": None,
                    "issues": [
                        {
                            "title": "One",
                            "body": "A",
                            "labels": ["enhancement"],
                            "priority": 1,
                            "blocked_by": [],
                        }
                    ],
                }
            )

    def test_plan_rejects_duplicate_priorities(self) -> None:
        with self.assertRaises(validator.ValidationError):
            validator.validate_data(
                {
                    "action": "plan",
                    "discussion_number": 43,
                    "milestone_name": None,
                    "issues": [
                        {
                            "title": "One",
                            "body": "A",
                            "labels": ["enhancement"],
                            "priority": 1,
                            "blocked_by": [],
                            "requested_evidence": ["swift test"],
                        },
                        {
                            "title": "Two",
                            "body": "B",
                            "labels": ["enhancement"],
                            "priority": 1,
                            "blocked_by": [],
                            "requested_evidence": ["swift test"],
                        },
                    ],
                }
            )

    def test_contributor_execute_issue_requires_positive_issue_number(self) -> None:
        with self.assertRaises(contributor_validator.ValidationError):
            contributor_validator.validate_data(
                {
                    "action": "execute_issue",
                    "persona": "April Clearwater, Application Lead",
                    "issue_number": 0,
                    "pr_title": "Fix issue",
                    "commit_message": "Fix issue",
                    "body": "## Summary\n- Updated code",
                }
            )

    def test_contributor_advance_pr_requires_positive_pr_number(self) -> None:
        with self.assertRaises(contributor_validator.ValidationError):
            contributor_validator.validate_data(
                {
                    "action": "advance_pr",
                    "persona": "April Clearwater, Application Lead",
                    "pr_number": 0,
                    "issue_number": 116,
                    "pr_title": "Fix issue",
                    "commit_message": "Fix issue",
                    "body": "## Summary\n- Updated code",
                    "evidence_complete": ["1 -- proof"],
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

    def make_plan(self, issue_titles: list[str], discussion=None, blocked_by_map=None):
        discussion = discussion or self.make_discussion()
        blocked_by_map = blocked_by_map or {}
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
                        "blocked_by": blocked_by_map.get(index + 1, []),
                        "requested_evidence": [f"Evidence for {title}"],
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

    def test_normalize_plan_preserves_blocked_by_and_requested_evidence(self) -> None:
        discussion = self.make_discussion()
        plan = self.make_plan(
            ["One", "Two"],
            discussion=discussion,
            blocked_by_map={2: [1]},
        )
        self.assertEqual(plan.issues[1].blocked_by, [1])
        self.assertEqual(plan.issues[1].requested_evidence, ["Evidence for Two"])

    def test_resolve_blocked_by_numbers_maps_plan_priorities(self) -> None:
        discussion = self.make_discussion()
        plan = self.make_plan(
            ["One", "Two"],
            discussion=discussion,
            blocked_by_map={2: [1]},
        )
        blocked = run_planner.resolve_blocked_by_numbers(
            plan.issues[1],
            resolved_by_priority={1: 101},
            plan_priorities={1, 2},
        )
        self.assertEqual(blocked, [101])

    def test_normalize_plan_rejects_same_or_later_plan_blockers(self) -> None:
        discussion = self.make_discussion()
        with self.assertRaises(run_planner.PlannerError):
            self.make_plan(
                ["One", "Two"],
                discussion=discussion,
                blocked_by_map={1: [2]},
            )

    def test_compose_issue_body_renders_blocked_by_and_requested_evidence(self) -> None:
        body = run_planner.compose_issue_body_with_metadata(
            "## Context\nBody",
            "https://github.com/fairchild/workspaces/discussions/43",
            43,
            "audit-runners",
            priority=1,
            blocked_by=[101],
            requested_evidence=["swift test --filter WorkspaceManagerTests.WorkspaceProviderTests"],
        )
        self.assertIn("- Priority: 1", body)
        self.assertIn("- Ship this issue as one PR.", body)
        self.assertIn("## Blocked By", body)
        self.assertIn("- #101", body)
        self.assertIn("## Requested Evidence", body)
        self.assertIn("swift test --filter WorkspaceManagerTests.WorkspaceProviderTests", body)

    def test_compose_summary_comment_invites_execution_reaction(self) -> None:
        comment = run_planner.compose_summary_comment(
            43,
            [{"number": 101, "title": "Audit runners"}],
            None,
            {"GITHUB_REPOSITORY": "fairchild/workspaces"},
        )
        self.assertIn("React with 👍 on this comment", comment)

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
                "body": run_planner.compose_issue_body_with_metadata(
                    plan.issues[0].body,
                    discussion["url"],
                    discussion["number"],
                    plan.issues[0].slug,
                    priority=plan.issues[0].priority,
                    blocked_by=plan.issues[0].blocked_by,
                    requested_evidence=plan.issues[0].requested_evidence,
                ),
                "url": "https://github.com/fairchild/workspaces/issues/101",
                "labels": [],
            },
            {
                "number": 102,
                "title": plan.issues[1].title,
                "body": run_planner.compose_issue_body_with_metadata(
                    plan.issues[1].body,
                    discussion["url"],
                    discussion["number"],
                    plan.issues[1].slug,
                    priority=plan.issues[1].priority,
                    blocked_by=plan.issues[1].blocked_by,
                    requested_evidence=plan.issues[1].requested_evidence,
                ),
                "url": "https://github.com/fairchild/workspaces/issues/102",
                "labels": [],
            },
            {
                "number": 103,
                "title": plan.issues[2].title,
                "body": run_planner.compose_issue_body_with_metadata(
                    plan.issues[2].body,
                    discussion["url"],
                    discussion["number"],
                    plan.issues[2].slug,
                    priority=plan.issues[2].priority,
                    blocked_by=plan.issues[2].blocked_by,
                    requested_evidence=plan.issues[2].requested_evidence,
                ),
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
                "body": run_planner.compose_issue_body_with_metadata(
                    plan.issues[0].body,
                    discussion["url"],
                    discussion["number"],
                    plan.issues[0].slug,
                    priority=plan.issues[0].priority,
                    blocked_by=plan.issues[0].blocked_by,
                    requested_evidence=plan.issues[0].requested_evidence,
                ),
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


class RunContributorTests(unittest.TestCase):
    def test_normalize_provider_env_prefers_openai_api_key(self) -> None:
        env = run_contributor.normalize_provider_env(
            {
                "OPENAI_API_KEY": "primary-key",
                "GITHUB_CODESPACES_OPENAI_API_KEY": "fallback-key",
            }
        )
        self.assertEqual(env["OPENAI_API_KEY"], "primary-key")

    def test_normalize_provider_env_falls_back_to_codespaces_key(self) -> None:
        env = run_contributor.normalize_provider_env(
            {
                "GITHUB_CODESPACES_OPENAI_API_KEY": "fallback-key",
            }
        )
        self.assertEqual(env["OPENAI_API_KEY"], "fallback-key")

    def test_planner_normalize_provider_env_falls_back_to_codespaces_key(self) -> None:
        env = run_planner.normalize_provider_env(
            {
                "GITHUB_CODESPACES_OPENAI_API_KEY": "fallback-key",
            }
        )
        self.assertEqual(env["OPENAI_API_KEY"], "fallback-key")

    def test_extract_persona_from_april_prompt(self) -> None:
        prompt = (
            REPO_ROOT
            / ".agents"
            / "skills"
            / "cofounder-contributor"
            / "references"
            / "april-clearwater.md"
        )
        self.assertEqual(run_contributor.extract_persona(prompt), "April Clearwater")

    def test_extract_persona_from_plat_prompt(self) -> None:
        prompt = (
            REPO_ROOT
            / ".agents"
            / "skills"
            / "cofounder-contributor"
            / "references"
            / "plat-ironwood.md"
        )
        self.assertEqual(run_contributor.extract_persona(prompt), "Plat Ironwood")

    def test_find_agent_threads_pr_review(self) -> None:
        data = {
            "data": {
                "repository": {
                    "pullRequests": {
                        "nodes": [
                            {
                                "number": 94,
                                "title": "Fix startup slowness",
                                "reviews": {
                                    "nodes": [
                                        {
                                            "body": "*April Clearwater, Application Lead*\n\nLooks good.",
                                            "author": {"login": "github-actions[bot]"},
                                            "submittedAt": "2026-03-13T06:19:00Z",
                                        },
                                        {
                                            "body": "Thanks for the review!",
                                            "author": {"login": "fairchild"},
                                            "submittedAt": "2026-03-13T07:00:00Z",
                                        },
                                    ]
                                },
                                "comments": {"nodes": []},
                            }
                        ]
                    },
                    "issues": {"nodes": []},
                    "discussions": {"nodes": []},
                }
            }
        }
        threads = run_contributor._find_agent_threads(data, ["*April Clearwater", "*Proposed by April Clearwater"])
        self.assertEqual(len(threads), 1)
        self.assertEqual(threads[0]["kind"], "PR")
        self.assertEqual(threads[0]["number"], 94)
        self.assertEqual(len(threads[0]["replies"]), 1)
        self.assertEqual(threads[0]["replies"][0]["author"], "fairchild")

    def test_find_agent_threads_discussion_proposed(self) -> None:
        data = {
            "data": {
                "repository": {
                    "pullRequests": {"nodes": []},
                    "issues": {"nodes": []},
                    "discussions": {
                        "nodes": [
                            {
                                "number": 42,
                                "title": "[idea] Quick switcher",
                                "body": "*Proposed by April Clearwater, Application Lead*\n\nWe should add...",
                                "createdAt": "2026-03-12T10:00:00Z",
                                "comments": {
                                    "nodes": [
                                        {
                                            "body": "Great idea, +1",
                                            "author": {"login": "fairchild"},
                                            "createdAt": "2026-03-12T12:00:00Z",
                                        }
                                    ]
                                },
                            }
                        ]
                    },
                }
            }
        }
        threads = run_contributor._find_agent_threads(data, ["*April Clearwater", "*Proposed by April Clearwater"])
        self.assertEqual(len(threads), 1)
        self.assertEqual(threads[0]["kind"], "Discussion (proposed)")
        self.assertEqual(len(threads[0]["replies"]), 1)

    def test_find_agent_threads_empty_when_no_activity(self) -> None:
        data = {
            "data": {
                "repository": {
                    "pullRequests": {"nodes": []},
                    "issues": {"nodes": []},
                    "discussions": {"nodes": []},
                }
            }
        }
        threads = run_contributor._find_agent_threads(data, ["*April Clearwater", "*Proposed by April Clearwater"])
        self.assertEqual(threads, [])

    def test_find_agent_threads_only_last_action_per_thread(self) -> None:
        data = {
            "data": {
                "repository": {
                    "pullRequests": {"nodes": []},
                    "issues": {
                        "nodes": [
                            {
                                "number": 10,
                                "title": "Some issue",
                                "comments": {
                                    "nodes": [
                                        {
                                            "body": "*Plat Ironwood*\n\nFirst take.",
                                            "author": {"login": "github-actions[bot]"},
                                            "createdAt": "2026-03-11T10:00:00Z",
                                        },
                                        {
                                            "body": "I disagree.",
                                            "author": {"login": "fairchild"},
                                            "createdAt": "2026-03-11T12:00:00Z",
                                        },
                                        {
                                            "body": "*Plat Ironwood*\n\nRevised take.",
                                            "author": {"login": "github-actions[bot]"},
                                            "createdAt": "2026-03-12T10:00:00Z",
                                        },
                                        {
                                            "body": "Looks good now.",
                                            "author": {"login": "fairchild"},
                                            "createdAt": "2026-03-12T12:00:00Z",
                                        },
                                    ]
                                },
                            }
                        ]
                    },
                    "discussions": {"nodes": []},
                }
            }
        }
        threads = run_contributor._find_agent_threads(data, ["*Plat Ironwood", "*Proposed by Plat Ironwood"])
        self.assertEqual(len(threads), 1)
        self.assertIn("Revised take", threads[0]["agent_item"]["body"])
        self.assertEqual(len(threads[0]["replies"]), 1)
        self.assertIn("Looks good now", threads[0]["replies"][0]["body"])

    def test_find_discussions_needing_engagement_prefers_recent_other_agent_thread(self) -> None:
        now = datetime(2026, 3, 16, 0, 0, tzinfo=timezone.utc)
        discussions = [
            {
                "number": 111,
                "title": "[idea] Split release workflow",
                "body": "*Proposed by Plat Ironwood, Platform Lead*\n\nIdea body",
                "createdAt": "2026-03-15T20:46:59Z",
                "comments": {
                    "nodes": [],
                    "totalCount": 0,
                },
            },
            {
                "number": 109,
                "title": "[idea] Fix remote workspace identity",
                "body": "*Proposed by April Clearwater, Application Lead*\n\nIdea body",
                "createdAt": "2026-03-15T16:25:01Z",
                "comments": {
                    "nodes": [],
                    "totalCount": 0,
                },
            },
        ]
        candidates = run_contributor.find_discussions_needing_engagement(
            discussions,
            owner_login="fairchild",
            persona="April Clearwater",
            now=now,
        )
        self.assertEqual(candidates[0]["number"], 111)
        self.assertIn("Plat Ironwood opened this", candidates[0]["reasons"][0])

    def test_find_discussions_needing_engagement_marks_low_comment_and_missing_owner_reply(self) -> None:
        now = datetime(2026, 3, 16, 0, 0, tzinfo=timezone.utc)
        discussions = [
            {
                "number": 110,
                "title": "[idea] Fix environment status color semantics",
                "body": "*Proposed by April Clearwater, Application Lead*\n\nIdea body",
                "createdAt": "2026-03-15T16:49:20Z",
                "comments": {
                    "nodes": [
                        {
                            "body": "One comment",
                            "author": {"login": "workspace-agents"},
                            "createdAt": "2026-03-15T18:00:00Z",
                        }
                    ],
                    "totalCount": 1,
                },
            }
        ]
        candidates = run_contributor.find_discussions_needing_engagement(
            discussions,
            owner_login="fairchild",
            persona="April Clearwater",
            now=now,
        )
        self.assertEqual(candidates[0]["number"], 110)
        self.assertIn("only 1 comment", candidates[0]["reasons"])
        self.assertIn("no owner reply yet", candidates[0]["reasons"])

    def test_maybe_block_new_proposal_returns_top_candidate(self) -> None:
        validated_json = '{"action":"propose","title":"[idea] New thread"}'
        candidates = [
            {
                "number": 111,
                "title": "[idea] Split release workflow",
                "reasons": ["0 comments", "no owner reply yet"],
            }
        ]
        blocked = run_contributor.maybe_block_new_proposal(validated_json, candidates)
        self.assertEqual(blocked["number"], 111)

    def test_maybe_block_new_proposal_ignores_comment_action(self) -> None:
        validated_json = '{"action":"comment","discussion_number":111}'
        blocked = run_contributor.maybe_block_new_proposal(validated_json, [{"number": 111}])
        self.assertIsNone(blocked)

    def test_discussion_execution_status_requires_owner_thumbs_up(self) -> None:
        discussion = {
            "number": 110,
            "comments": {
                "nodes": [
                    {
                        "id": "planned",
                        "body": run_planner.comment_marker(110, "planned"),
                        "createdAt": "2026-03-16T08:00:00Z",
                        "reactionGroups": [
                            {
                                "content": "THUMBS_UP",
                                "users": {"nodes": [{"login": "fairchild"}]},
                            }
                        ],
                    }
                ]
            },
        }
        approved, reason = run_contributor.discussion_execution_status(discussion, 110, "fairchild")
        self.assertTrue(approved)
        self.assertIn("owner reacted 👍", reason)

    def test_classify_execution_work_surfaces_ready_issue(self) -> None:
        issue_body = run_planner.compose_issue_body_with_metadata(
            "## Context\nBody",
            "https://github.com/fairchild/workspaces/discussions/110",
            110,
            "fix-status-color",
            priority=1,
            blocked_by=[],
            requested_evidence=["swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests"],
        )
        issues = [
            {
                "number": 116,
                "title": "Fix environment status color semantics in NewWorkspaceSheet",
                "url": "https://github.com/fairchild/workspaces/issues/116",
                "body": issue_body,
                "labels": {"nodes": [{"name": "agent:task"}, {"name": "agent:ready"}]},
                "comments": {"nodes": []},
            }
        ]
        pull_requests: list[dict[str, object]] = []
        discussions: list[dict[str, object]] = []
        classified = run_contributor.classify_execution_work(
            issues,
            pull_requests,
            discussions,
            issue_states={116: "OPEN"},
            owner_login="fairchild",
            persona="April Clearwater",
            bot_login="april-clearwater[bot]",
        )
        self.assertEqual(len(classified["ready_issues"]), 1)
        self.assertEqual(classified["ready_issues"][0]["issue_number"], 116)
        self.assertEqual(classified["ready_issues"][0]["approval_reason"], "agent:ready label present")

    def test_claim_is_stale_after_24_hours_without_pr(self) -> None:
        claim = {
            "agent": "april-clearwater",
            "branch": "codex/april-clearwater-issue-116-fix-status",
            "status": "claimed",
            "createdAt": "2026-03-15T08:00:00Z",
        }
        now = datetime(2026, 3, 16, 8, 0, tzinfo=timezone.utc)
        self.assertTrue(run_contributor.claim_is_stale(claim, has_open_pr=False, now=now))
        self.assertFalse(run_contributor.claim_is_stale(claim, has_open_pr=True, now=now))

    def test_sync_desired_execution_labels_returns_ready_for_approved_unblocked_issue(self) -> None:
        issue_body = run_planner.compose_issue_body_with_metadata(
            "## Context\nBody",
            "https://github.com/fairchild/workspaces/discussions/110",
            110,
            "fix-status-color",
            priority=1,
            blocked_by=[],
            requested_evidence=["swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests"],
        )
        issue = {
            "number": 116,
            "body": issue_body,
            "comments": {"nodes": []},
        }
        discussions = {
            110: {
                "number": 110,
                "comments": {
                    "nodes": [
                        {
                            "id": "planned",
                            "body": run_planner.comment_marker(110, "planned"),
                            "createdAt": "2026-03-16T08:00:00Z",
                            "reactionGroups": [
                                {
                                    "content": "THUMBS_UP",
                                    "users": {"nodes": [{"login": "fairchild"}]},
                                }
                            ],
                        }
                    ]
                },
            }
        }
        labels, reason = sync_execution_state.desired_execution_labels(
            issue,
            discussions=discussions,
            issue_states={116: "OPEN"},
            open_pr_issue_numbers=set(),
            owner_login="fairchild",
            now=datetime(2026, 3, 16, 9, 0, tzinfo=timezone.utc),
        )
        self.assertEqual(labels, {sync_execution_state.AGENT_READY_LABEL})
        self.assertEqual(reason, "execution-approved and ready")

    def test_sync_desired_execution_labels_expires_stale_claim(self) -> None:
        issue_body = run_planner.compose_issue_body_with_metadata(
            "## Context\nBody",
            "https://github.com/fairchild/workspaces/discussions/110",
            110,
            "fix-status-color",
            priority=1,
            blocked_by=[],
            requested_evidence=["swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests"],
        )
        issue = {
            "number": 116,
            "body": issue_body,
            "comments": {
                "nodes": [
                    {
                        "body": (
                            "*April Clearwater, Application Lead*\n\n"
                            "Claiming this issue.\n\n"
                            "<!-- contributor:issue=116;status=claimed;"
                            "agent=april-clearwater;branch=codex/april-clearwater-issue-116-fix-status -->"
                        ),
                        "createdAt": "2026-03-15T08:00:00Z",
                    }
                ]
            },
        }
        discussions = {
            110: {
                "number": 110,
                "comments": {
                    "nodes": [
                        {
                            "id": "planned",
                            "body": run_planner.comment_marker(110, "planned"),
                            "createdAt": "2026-03-16T08:00:00Z",
                            "reactionGroups": [
                                {
                                    "content": "THUMBS_UP",
                                    "users": {"nodes": [{"login": "fairchild"}]},
                                }
                            ],
                        }
                    ]
                },
            }
        }
        labels, reason = sync_execution_state.desired_execution_labels(
            issue,
            discussions=discussions,
            issue_states={116: "OPEN"},
            open_pr_issue_numbers=set(),
            owner_login="fairchild",
            now=datetime(2026, 3, 16, 9, 0, tzinfo=timezone.utc),
        )
        self.assertEqual(labels, {sync_execution_state.AGENT_READY_LABEL})
        self.assertEqual(reason, "execution-approved and ready")

    def test_extract_pr_issue_reference_reads_pr_marker(self) -> None:
        issue_number, agent = run_contributor.extract_pr_issue_reference(
            "Closes #116\n\n<!-- contributor:issue=116;agent=april-clearwater -->"
        )
        self.assertEqual(issue_number, 116)
        self.assertEqual(agent, "april-clearwater")

    def test_validate_evidence_accounting_accepts_complete_and_blocked_entries(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "## Evidence Status\n"
            "- [complete] swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests -- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`\n"
            "- [blocked] Screenshot of NewWorkspaceSheet from the exact commit under review -- Linux runner cannot launch the macOS app\n\n"
            "## Validation\n"
            "- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`\n"
            "- blocked on evidence: Linux runner cannot capture the requested macOS screenshot\n"
        )
        accounting, errors = run_contributor.validate_evidence_accounting(
            body,
            [
                "swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests",
                "Screenshot of NewWorkspaceSheet from the exact commit under review",
            ],
        )
        self.assertEqual(errors, [])
        self.assertEqual(
            accounting["complete_items"],
            ["swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests"],
        )
        self.assertEqual(
            accounting["blocked_items"],
            ["Screenshot of NewWorkspaceSheet from the exact commit under review"],
        )

    def test_validate_evidence_accounting_accepts_em_dash_separator_for_legacy_markdown(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "## Evidence Status\n"
            "- [complete] swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests — `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`\n\n"
            "## Validation\n"
            "- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`\n"
        )
        accounting, errors = run_contributor.validate_evidence_accounting(
            body,
            ["swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests"],
        )
        self.assertEqual(errors, [])
        self.assertEqual(accounting["source"], "markdown")
        self.assertEqual(
            accounting["complete_items"],
            ["swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests"],
        )

    def test_extract_requested_evidence_ignores_fallback_sentence_case_insensitively(self) -> None:
        body = (
            "## Requested Evidence\n"
            "- FOLLOW THE REPO EVIDENCE BAR FOR THE TOUCHED SURFACES.\n"
            "- swift test --filter WorkspaceManagerTests.WorkspaceProviderTests\n"
        )
        self.assertEqual(
            run_contributor.extract_requested_evidence(body),
            ["swift test --filter WorkspaceManagerTests.WorkspaceProviderTests"],
        )

    def test_validate_evidence_accounting_accepts_pending_ci_entries(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "## Evidence Status\n"
            "- [pending-ci] swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests -- self-hosted macOS CI will run this command\n"
            "- [pending-ci] Screenshot of NewWorkspaceSheet from the exact commit under review -- self-hosted macOS CI will capture this\n\n"
            "## Validation\n"
            "- blocked on evidence: macOS-only evidence is deferred to CI\n"
        )
        accounting, errors = run_contributor.validate_evidence_accounting(
            body,
            [
                "swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests",
                "Screenshot of NewWorkspaceSheet from the exact commit under review",
            ],
        )
        self.assertEqual(errors, [])
        self.assertEqual(
            accounting["pending_ci_items"],
            [
                "swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests",
                "Screenshot of NewWorkspaceSheet from the exact commit under review",
            ],
        )

    def test_validate_evidence_accounting_rejects_missing_requested_item(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "## Evidence Status\n"
            "- [complete] swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests -- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`\n\n"
            "## Validation\n"
            "- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`\n"
        )
        _, errors = run_contributor.validate_evidence_accounting(
            body,
            [
                "swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests",
                "Screenshot of NewWorkspaceSheet from the exact commit under review",
            ],
        )
        self.assertEqual(len(errors), 1)
        self.assertIn("missing:", errors[0])
        self.assertIn(
            "Screenshot of NewWorkspaceSheet from the exact commit under review",
            errors[0],
        )

    def test_validate_evidence_accounting_requires_blocked_on_evidence_language(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "## Evidence Status\n"
            "- [blocked] Screenshot of NewWorkspaceSheet from the exact commit under review -- Linux runner cannot launch the macOS app\n\n"
            "## Validation\n"
            "- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`\n"
        )
        _, errors = run_contributor.validate_evidence_accounting(
            body,
            ["Screenshot of NewWorkspaceSheet from the exact commit under review"],
        )
        self.assertEqual(len(errors), 1)
        self.assertIn("blocked on evidence", errors[0])

    def test_render_execution_summary_body_renders_exact_requested_items_from_indexes(self) -> None:
        body, errors = run_contributor.render_execution_summary_body(
            "## Summary\n- Updated the status severity mapping\n\n## Validation\n- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`\n",
            requested_evidence=[
                "Screenshot of NewWorkspaceSheet from the exact commit under review",
                "swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests",
            ],
            evidence_complete=["2 -- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`"],
            evidence_blocked=["1 -- Linux runner cannot launch the macOS app"],
            evidence_pending_ci=[],
        )
        self.assertEqual(errors, [])
        self.assertIn(
            "- [complete] swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests -- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`",
            body,
        )
        self.assertIn(
            "- [blocked] Screenshot of NewWorkspaceSheet from the exact commit under review -- Linux runner cannot launch the macOS app",
            body,
        )
        self.assertIn("blocked on evidence: Linux runner cannot launch the macOS app", body)
        self.assertIn("<!-- evidence-status:v1", body)
        accounting, validation_errors = run_contributor.validate_evidence_accounting(
            body,
            [
                "Screenshot of NewWorkspaceSheet from the exact commit under review",
                "swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests",
            ],
        )
        self.assertEqual(validation_errors, [])
        self.assertEqual(accounting["source"], "structured")

    def test_validate_evidence_accounting_flags_invalid_structured_metadata(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "<!-- evidence-status:v1\n"
            "{\n"
            '  "entries": [\n'
            "    {\n"
            '      "index": 1,\n'
            '      "item": "swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests",\n'
            '      "status": "complete",\n'
            '      "detail": ""\n'
            "    }\n"
            "  ]\n"
            "}\n"
            "-->\n\n"
            "## Evidence Status\n"
            "- [complete] swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests -- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`\n\n"
            "## Validation\n"
            "- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`\n"
        )
        accounting, errors = run_contributor.validate_evidence_accounting(
            body,
            ["swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests"],
        )
        self.assertEqual(accounting["source"], "structured-invalid")
        self.assertEqual(accounting["missing_items"], ["swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests"])
        self.assertTrue(any("empty detail" in line for line in accounting["invalid_lines"]))
        self.assertTrue(any("malformed hidden evidence metadata" in error for error in errors))

    def test_validate_evidence_accounting_flags_non_numeric_structured_metadata_version(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "<!-- evidence-status:vbogus\n"
            "{\n"
            '  "entries": []\n'
            "}\n"
            "-->\n\n"
            "## Evidence Status\n"
            "- [complete] swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests -- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`\n"
        )
        accounting, errors = run_contributor.validate_evidence_accounting(
            body,
            ["swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests"],
        )
        self.assertEqual(accounting["source"], "structured-invalid")
        self.assertTrue(any("not a valid integer" in line for line in accounting["invalid_lines"]))
        self.assertTrue(any("malformed hidden evidence metadata" in error for error in errors))

    def test_validate_evidence_accounting_flags_structured_item_mismatch(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "<!-- evidence-status:v1\n"
            "{\n"
            '  "entries": [\n'
            "    {\n"
            '      "index": 1,\n'
            '      "item": "swift test --filter WorkspaceManagerTests.OtherTests",\n'
            '      "status": "complete",\n'
            '      "detail": "`swift test --filter WorkspaceManagerTests.OtherTests`"\n'
            "    }\n"
            "  ]\n"
            "}\n"
            "-->\n\n"
            "## Evidence Status\n"
            "- [complete] swift test --filter WorkspaceManagerTests.OtherTests -- `swift test --filter WorkspaceManagerTests.OtherTests`\n"
        )
        accounting, errors = run_contributor.validate_evidence_accounting(
            body,
            ["swift test --filter WorkspaceManagerTests.WorkspaceProviderTests"],
        )
        self.assertEqual(accounting["source"], "structured-invalid")
        self.assertTrue(any("does not match requested evidence index" in line for line in accounting["invalid_lines"]))
        self.assertTrue(any("missing:" in error for error in errors))

    def test_render_execution_summary_body_rejects_out_of_range_index(self) -> None:
        _, errors = run_contributor.render_execution_summary_body(
            "## Summary\n- Updated the status severity mapping\n",
            requested_evidence=["swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests"],
            evidence_complete=["2 -- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`"],
            evidence_blocked=[],
            evidence_pending_ci=[],
        )
        self.assertEqual(len(errors), 1)
        self.assertIn("out of range", errors[0])

    def test_render_execution_summary_body_supports_pending_ci_from_indexes(self) -> None:
        body, errors = run_contributor.render_execution_summary_body(
            "## Summary\n- Updated the status severity mapping\n\n## Validation\n- workflow updated\n",
            requested_evidence=[
                "Screenshot of NewWorkspaceSheet from the exact commit under review",
                "swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests",
            ],
            evidence_complete=[],
            evidence_blocked=[],
            evidence_pending_ci=[
                "1 -- self-hosted macOS CI will capture the screenshot",
                "2 -- self-hosted macOS CI will run `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`",
            ],
        )
        self.assertEqual(errors, [])
        self.assertIn(
            "- [pending-ci] Screenshot of NewWorkspaceSheet from the exact commit under review -- self-hosted macOS CI will capture the screenshot",
            body,
        )
        self.assertIn("blocked on evidence: self-hosted macOS CI will capture the screenshot", body)

    def test_review_evidence_gate_requires_request_changes_for_blocked_evidence(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "## Evidence Status\n"
            "- [blocked] Screenshot of NewWorkspaceSheet from the exact commit under review -- Linux runner cannot launch the macOS app\n\n"
            "## Validation\n"
            "- blocked on evidence: Linux runner cannot capture the requested macOS screenshot\n"
        )
        accounting, errors = run_contributor.validate_evidence_accounting(
            body,
            ["Screenshot of NewWorkspaceSheet from the exact commit under review"],
        )
        gate_error = run_contributor.review_evidence_gate_error(
            "approve_with_followups",
            accounting,
            errors,
        )
        self.assertIsNotNone(gate_error)
        self.assertIn("request_changes", gate_error)

    def test_extract_test_commands_preserves_explicit_swift_test_commands(self) -> None:
        commands = run_contributor._extract_test_commands(
            [
                "swift test --filter WorkspaceManagerTests.WorkspaceProviderTests",
                "swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests",
                "Screenshot of NewWorkspaceSheet from the exact commit under review",
            ]
        )
        self.assertEqual(
            commands,
            [
                "swift test --filter WorkspaceManagerTests.WorkspaceProviderTests",
                "swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests",
            ],
        )

    def test_validate_requested_test_commands_rejects_unlisted_swift_filter(self) -> None:
        with mock.patch.object(
            run_contributor,
            "_listed_swift_tests",
            return_value=["WorkspaceManagerTests.WorkspaceProviderTests/registryExposesLiveProviders()"],
        ):
            errors = run_contributor.validate_requested_test_commands(
                ["swift test --filter WorkspaceProviders"],
                env={},
            )
        self.assertEqual(len(errors), 1)
        self.assertIn("does not match any `swift test list` specifier", errors[0])

    def test_validate_requested_test_commands_accepts_target_qualified_swift_filter(self) -> None:
        with mock.patch.object(
            run_contributor,
            "_listed_swift_tests",
            return_value=["WorkspaceManagerTests.WorkspaceProviderTests/registryExposesLiveProviders()"],
        ):
            errors = run_contributor.validate_requested_test_commands(
                ["swift test --filter WorkspaceManagerTests.WorkspaceProviderTests"],
                env={},
            )
        self.assertEqual(errors, [])

    def test_validate_requested_test_commands_skips_preflight_when_test_list_is_unavailable(self) -> None:
        with mock.patch.object(
            run_contributor,
            "_listed_swift_tests",
            return_value=[],
        ):
            errors = run_contributor.validate_requested_test_commands(
                ["swift test --filter WorkspaceManagerTests.WorkspaceProviderTests"],
                env={},
            )
        self.assertEqual(errors, [])

    def test_needs_macos_evidence_for_screenshot_only_requests(self) -> None:
        self.assertTrue(
            run_contributor._needs_macos_evidence(
                ["Screenshot of NewWorkspaceSheet from the exact commit under review"]
            )
        )

    def test_reconcile_pending_ci_evidence_marks_successful_items_complete(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "## Evidence Status\n"
            "- [pending-ci] swift build -- self-hosted macOS CI will run this command\n"
            "- [pending-ci] swift test --filter WorkspaceManagerTests.WorkspaceProviderTests -- self-hosted macOS CI will run this command\n"
            "- [pending-ci] Screenshot of NewWorkspaceSheet from the exact commit under review -- self-hosted macOS CI will capture this\n\n"
            "## Validation\n"
            "- blocked on evidence: macOS-only evidence is deferred to CI\n"
        )
        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            screenshot_upload_succeeded=True,
            screenshot_urls=[("NewWorkspaceSheet", "https://example.test/evidence.png")],
        )
        accounting, errors = run_contributor.validate_evidence_accounting(
            reconciled,
            [
                "swift build",
                "swift test --filter WorkspaceManagerTests.WorkspaceProviderTests",
                "Screenshot of NewWorkspaceSheet from the exact commit under review",
            ],
        )
        self.assertEqual(errors, [])
        self.assertEqual(accounting["pending_ci_items"], [])
        self.assertEqual(accounting["blocked_items"], [])
        self.assertEqual(
            accounting["complete_items"],
            [
                "swift build",
                "swift test --filter WorkspaceManagerTests.WorkspaceProviderTests",
                "Screenshot of NewWorkspaceSheet from the exact commit under review",
            ],
        )

    def test_reconcile_pending_ci_evidence_marks_failed_tests_blocked(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "## Evidence Status\n"
            "- [pending-ci] swift test --filter WorkspaceManagerTests.WorkspaceProviderTests -- self-hosted macOS CI will run this command\n\n"
            "## Validation\n"
            "- blocked on evidence: macOS-only evidence is deferred to CI\n"
        )
        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=False,
            smoke_succeeded=True,
        )
        accounting, errors = run_contributor.validate_evidence_accounting(
            reconciled,
            ["swift test --filter WorkspaceManagerTests.WorkspaceProviderTests"],
        )
        self.assertEqual(accounting["blocked_items"], ["swift test --filter WorkspaceManagerTests.WorkspaceProviderTests"])
        self.assertEqual(errors, [])

    def test_reconcile_pending_ci_evidence_blocks_structured_test_entries_with_no_matches(self) -> None:
        body, errors = run_contributor.render_execution_summary_body(
            "## Summary\n- Updated the status severity mapping\n\n## Validation\n- blocked on evidence: waiting on CI\n",
            requested_evidence=["swift test --filter WorkspaceManagerTests.WorkspaceProviderTests"],
            evidence_complete=[],
            evidence_blocked=[],
            evidence_pending_ci=["1 -- self-hosted macOS CI will run this command"],
        )
        self.assertEqual(errors, [])
        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            test_output=(
                "$ swift test --filter WorkspaceManagerTests.WorkspaceProviderTests\n"
                "warning: No matching test cases were run\n"
            ),
        )
        accounting, validation_errors = run_contributor.validate_evidence_accounting(
            reconciled,
            ["swift test --filter WorkspaceManagerTests.WorkspaceProviderTests"],
        )
        self.assertEqual(validation_errors, [])
        self.assertEqual(
            accounting["blocked_items"],
            ["swift test --filter WorkspaceManagerTests.WorkspaceProviderTests"],
        )
        self.assertEqual(accounting["source"], "structured")

    def test_reconcile_pending_ci_evidence_ignores_non_numeric_metadata_version(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "<!-- evidence-status:vbogus\n"
            "{\n"
            '  "entries": [\n'
            "    {\n"
            '      "index": 1,\n'
            '      "item": "swift test --filter WorkspaceManagerTests.WorkspaceProviderTests",\n'
            '      "status": "pending-ci",\n'
            '      "detail": "self-hosted macOS CI will run this command"\n'
            "    }\n"
            "  ]\n"
            "}\n"
            "-->\n\n"
            "## Evidence Status\n"
            "- [pending-ci] swift test --filter WorkspaceManagerTests.WorkspaceProviderTests -- self-hosted macOS CI will run this command\n\n"
            "## Validation\n"
            "- blocked on evidence: macOS-only evidence is deferred to CI\n"
        )
        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            test_output="$ swift test --filter WorkspaceManagerTests.WorkspaceProviderTests\nok\n",
        )
        self.assertIn(
            "- [complete] swift test --filter WorkspaceManagerTests.WorkspaceProviderTests -- `swift test --filter WorkspaceManagerTests.WorkspaceProviderTests` succeeded on self-hosted macOS CI",
            reconciled,
        )

    def test_reconcile_pending_ci_evidence_preserves_invalid_metadata_entries(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "<!-- evidence-status:v1\n"
            "{\n"
            '  "entries": [\n'
            '    "legacy-entry",\n'
            "    {\n"
            '      "index": 1,\n'
            '      "item": "swift test --filter WorkspaceManagerTests.WorkspaceProviderTests",\n'
            '      "status": "pending-ci",\n'
            '      "detail": "self-hosted macOS CI will run this command"\n'
            "    }\n"
            "  ]\n"
            "}\n"
            "-->\n\n"
            "## Evidence Status\n"
            "- [pending-ci] swift test --filter WorkspaceManagerTests.WorkspaceProviderTests -- self-hosted macOS CI will run this command\n\n"
            "## Validation\n"
            "- blocked on evidence: macOS-only evidence is deferred to CI\n"
        )
        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            test_output="$ swift test --filter WorkspaceManagerTests.WorkspaceProviderTests\nok\n",
        )
        metadata = run_contributor._extract_evidence_metadata(reconciled)
        self.assertIsNotNone(metadata)
        self.assertEqual(metadata["entries"][0], "legacy-entry")
        self.assertEqual(metadata["entries"][1]["status"], "complete")

    def test_insert_evidence_metadata_is_idempotent(self) -> None:
        body = (
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "## Evidence Status\n"
            "- [complete] swift build -- `swift build`\n"
        )
        payload = {
            "entries": [
                {
                    "index": 1,
                    "item": "swift build",
                    "status": "complete",
                    "detail": "`swift build`",
                }
            ]
        }
        once = run_contributor._insert_evidence_metadata(body, payload)
        twice = run_contributor._insert_evidence_metadata(once, payload)
        self.assertEqual(twice.count("<!-- evidence-status:v1"), 1)
        self.assertEqual(run_contributor._extract_evidence_metadata(twice), payload)

    def test_format_pr_list_for_context_includes_evidence_summary(self) -> None:
        issue_body = run_planner.compose_issue_body_with_metadata(
            "## Context\nBody",
            "https://github.com/fairchild/workspaces/discussions/110",
            110,
            "fix-status-color",
            priority=1,
            blocked_by=[],
            requested_evidence=[
                "swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests",
                "Screenshot of NewWorkspaceSheet from the exact commit under review",
            ],
        )
        pr_body = (
            "*April Clearwater, Application Lead*\n\n"
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "## Evidence Status\n"
            "- [complete] swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests -- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`\n"
            "- [blocked] Screenshot of NewWorkspaceSheet from the exact commit under review -- Linux runner cannot launch the macOS app\n\n"
            "## Validation\n"
            "- `swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests`\n"
            "- blocked on evidence: Linux runner cannot capture the requested macOS screenshot\n\n"
            "Closes #116\n\n"
            "<!-- contributor:issue=116;agent=april-clearwater -->"
        )
        payload = json.loads(
            run_contributor.format_pr_list_for_context(
                [
                    {
                        "number": 119,
                        "title": "Fix environment status color semantics in NewWorkspaceSheet",
                        "author": {"login": "app/april-clearwater"},
                        "isDraft": False,
                        "reviewDecision": "REVIEW_REQUIRED",
                        "headRefName": "codex/april-clearwater-issue-116-fix-status",
                        "url": "https://github.com/fairchild/workspaces/pull/119",
                        "body": pr_body,
                    }
                ],
                [
                    {
                        "number": 116,
                        "body": issue_body,
                    }
                ],
            )
        )
        self.assertEqual(payload[0]["linkedIssue"], 116)
        self.assertEqual(payload[0]["evidenceSummary"]["requested"], 2)
        self.assertEqual(payload[0]["evidenceSummary"]["complete"], 1)
        self.assertEqual(payload[0]["evidenceSummary"]["blocked"], 1)
        self.assertEqual(payload[0]["evidenceSummary"]["missing"], 0)
        self.assertEqual(payload[0]["evidenceSummary"]["source"], "markdown")

    def test_format_pr_list_for_context_reports_no_contract_for_fallback_requested_evidence(self) -> None:
        issue_body = run_planner.compose_issue_body(
            "## Context\nBody",
            "https://github.com/fairchild/workspaces/discussions/110",
            110,
            "legacy-evidence",
        )
        pr_body = (
            "*April Clearwater, Application Lead*\n\n"
            "## Summary\n"
            "- Updated the status severity mapping\n\n"
            "## Evidence Status\n"
            "- [complete] `swift test --filter WorkspaceProviders` passing — output below\n\n"
            "Closes #116\n\n"
            "<!-- contributor:issue=116;agent=april-clearwater -->"
        )
        payload = json.loads(
            run_contributor.format_pr_list_for_context(
                [
                    {
                        "number": 119,
                        "title": "Legacy evidence PR",
                        "author": {"login": "app/april-clearwater"},
                        "isDraft": False,
                        "reviewDecision": "REVIEW_REQUIRED",
                        "headRefName": "codex/april-clearwater-issue-116-legacy-evidence",
                        "url": "https://github.com/fairchild/workspaces/pull/119",
                        "body": pr_body,
                    }
                ],
                [
                    {
                        "number": 116,
                        "body": issue_body,
                    }
                ],
            )
        )
        self.assertEqual(payload[0]["evidenceSummary"]["contract"], "none")


    def test_format_own_open_prs_includes_evidence_delta_and_latest_review(self) -> None:
        rendered = run_contributor.format_own_open_prs(
            [
                {
                    "pr_number": 119,
                    "pr_title": "Fix environment status color semantics in NewWorkspaceSheet",
                    "issue_number": 116,
                    "review_decision": "CHANGES_REQUESTED",
                    "pr_branch": "codex/april-clearwater-issue-116-fix-status",
                    "requested_evidence": [
                        "Screenshot of NewWorkspaceSheet from the exact commit under review",
                        "swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests",
                        "Before screenshot showing the broken state",
                    ],
                    "evidence_accounting": {
                        "complete_items": ["swift test --filter WorkspaceManagerAppTests.NewWorkspaceSheetTests"],
                        "blocked_items": [],
                        "missing_items": [
                            "Screenshot of NewWorkspaceSheet from the exact commit under review",
                            "Before screenshot showing the broken state",
                        ],
                        "invalid_lines": [],
                    },
                    "latest_external_review": {
                        "author": "github-actions",
                        "state": "CHANGES_REQUESTED",
                        "submittedAt": "2026-03-17T14:00:39Z",
                        "body": "Please add the missing evidence accounting before approval.",
                    },
                }
            ]
        )
        self.assertIn("Requested evidence by index", rendered)
        self.assertIn("[1] Screenshot of NewWorkspaceSheet from the exact commit under review", rendered)
        self.assertIn("missing [1, 3]", rendered)
        self.assertIn("Latest external review: github-actions (CHANGES_REQUESTED)", rendered)
        self.assertIn("git checkout codex/april-clearwater-issue-116-fix-status", rendered)

    def test_format_own_open_prs_includes_branch_checkout_reminder(self) -> None:
        rendered = run_contributor.format_own_open_prs(
            [
                {
                    "pr_number": 119,
                    "pr_title": "Fix status color",
                    "issue_number": 116,
                    "review_decision": "REVIEW_REQUIRED",
                    "pr_branch": "codex/april-issue-116",
                    "requested_evidence": [],
                    "evidence_accounting": {
                        "complete_items": [],
                        "blocked_items": [],
                        "missing_items": [],
                        "invalid_lines": [],
                    },
                    "latest_external_review": None,
                }
            ]
        )
        self.assertIn("git checkout codex/april-issue-116", rendered)
        self.assertIn("rejects commits on the wrong branch", rendered)

    def test_format_own_open_prs_empty(self) -> None:
        self.assertEqual(run_contributor.format_own_open_prs([]), "")

    def test_classify_execution_work_detects_own_pr_by_marker(self) -> None:
        """Own-PR detection: PR body contains the contributor marker for the current persona."""
        issue_body = run_planner.compose_issue_body_with_metadata(
            "## Context\nBody",
            "https://github.com/fairchild/workspaces/discussions/110",
            110,
            "fix-status-color",
            priority=1,
            blocked_by=[],
            requested_evidence=["swift test"],
        )
        pr_body = run_contributor.compose_pr_body(116, "April Clearwater", "## Summary\n- Fixed color")
        issues = [
            {
                "number": 116,
                "title": "Fix status color",
                "url": "https://github.com/fairchild/workspaces/issues/116",
                "body": issue_body,
                "labels": {"nodes": [{"name": "agent:task"}, {"name": "agent:ready"}]},
                "comments": {"nodes": []},
            }
        ]
        pull_requests = [
            {
                "number": 119,
                "title": "Fix status color",
                "url": "https://github.com/fairchild/workspaces/pulls/119",
                "body": pr_body,
                "author": {"login": "april-clearwater[bot]"},
                "reviewDecision": "REVIEW_REQUIRED",
                "headRefName": "codex/april-clearwater-issue-116-fix-status",
                "reviews": {"nodes": []},
                "comments": {"nodes": []},
            }
        ]
        classified = run_contributor.classify_execution_work(
            issues,
            pull_requests,
            [],
            issue_states={116: "OPEN"},
            owner_login="fairchild",
            persona="April Clearwater",
            bot_login="april-clearwater[bot]",
        )
        self.assertEqual(len(classified["own_open_prs"]), 1)
        self.assertEqual(classified["own_open_prs"][0]["pr_number"], 119)
        self.assertEqual(classified["own_open_prs"][0]["pr_branch"], "codex/april-clearwater-issue-116-fix-status")
        self.assertEqual(classified["ready_issues"], [])
        self.assertEqual(classified["claimed_issues"], [])

    def test_classify_execution_work_detects_own_pr_by_bot_login(self) -> None:
        """Own-PR fallback: no marker in body, but author login matches bot_login."""
        issue_body = run_planner.compose_issue_body_with_metadata(
            "## Context\nBody",
            "https://github.com/fairchild/workspaces/discussions/110",
            110,
            "fix-status-color",
            priority=1,
            blocked_by=[],
            requested_evidence=["swift test"],
        )
        # PR body uses Closes #N but no contributor marker
        pr_body = "## Summary\n- Fixed color\n\nCloses #116"
        issues = [
            {
                "number": 116,
                "title": "Fix status color",
                "url": "https://github.com/fairchild/workspaces/issues/116",
                "body": issue_body,
                "labels": {"nodes": [{"name": "agent:task"}, {"name": "agent:ready"}]},
                "comments": {"nodes": []},
            }
        ]
        pull_requests = [
            {
                "number": 120,
                "title": "Fix status color",
                "url": "https://github.com/fairchild/workspaces/pulls/120",
                "body": pr_body,
                "author": {"login": "april-clearwater[bot]"},
                "reviewDecision": None,
                "headRefName": "codex/april-issue-116",
                "reviews": {"nodes": []},
                "comments": {"nodes": []},
            }
        ]
        classified = run_contributor.classify_execution_work(
            issues,
            pull_requests,
            [],
            issue_states={116: "OPEN"},
            owner_login="fairchild",
            persona="April Clearwater",
            bot_login="april-clearwater[bot]",
        )
        self.assertEqual(len(classified["own_open_prs"]), 1)
        self.assertEqual(classified["own_open_prs"][0]["pr_number"], 120)

    def test_classify_execution_work_other_agents_pr_not_own(self) -> None:
        """A PR authored by a different agent should not appear in own_open_prs."""
        issue_body = run_planner.compose_issue_body_with_metadata(
            "## Context\nBody",
            "https://github.com/fairchild/workspaces/discussions/110",
            110,
            "fix-status-color",
            priority=1,
            blocked_by=[],
            requested_evidence=["swift test"],
        )
        # PR marker belongs to plat-ironwood, not april-clearwater
        pr_body = (
            "## Summary\n- Fixed color\n\nCloses #116\n\n"
            "<!-- contributor:issue=116;agent=plat-ironwood -->"
        )
        issues = [
            {
                "number": 116,
                "title": "Fix status color",
                "url": "https://github.com/fairchild/workspaces/issues/116",
                "body": issue_body,
                "labels": {"nodes": [{"name": "agent:task"}, {"name": "agent:ready"}]},
                "comments": {"nodes": []},
            }
        ]
        pull_requests = [
            {
                "number": 121,
                "title": "Fix status color",
                "url": "https://github.com/fairchild/workspaces/pulls/121",
                "body": pr_body,
                "author": {"login": "plat-ironwood[bot]"},
                "reviewDecision": None,
                "headRefName": "codex/plat-issue-116",
                "reviews": {"nodes": []},
                "comments": {"nodes": []},
            }
        ]
        classified = run_contributor.classify_execution_work(
            issues,
            pull_requests,
            [],
            issue_states={116: "OPEN"},
            owner_login="fairchild",
            persona="April Clearwater",
            bot_login="april-clearwater[bot]",
        )
        # Not in own_open_prs because it belongs to a different agent
        self.assertEqual(classified["own_open_prs"], [])
        # Issue has a linked PR by another agent, so it should NOT be in ready_issues
        self.assertEqual(classified["ready_issues"], [])

    def test_classify_execution_work_claimed_issue_without_pr(self) -> None:
        """An issue claimed by the current agent without a linked PR goes into claimed_issues."""
        issue_body = run_planner.compose_issue_body_with_metadata(
            "## Context\nBody",
            "https://github.com/fairchild/workspaces/discussions/110",
            110,
            "fix-status-color",
            priority=1,
            blocked_by=[],
            requested_evidence=["swift test"],
        )
        claim_comment = (
            "<!-- contributor:issue=116;status=claimed;agent=april-clearwater;branch=codex/april-issue-116 -->\n"
            "Claimed issue #116 on branch `codex/april-issue-116`."
        )
        issues = [
            {
                "number": 116,
                "title": "Fix status color",
                "url": "https://github.com/fairchild/workspaces/issues/116",
                "body": issue_body,
                "labels": {"nodes": [{"name": "agent:task"}, {"name": "agent:ready"}, {"name": "agent:claimed"}]},
                "comments": {
                    "nodes": [
                        {
                            "body": claim_comment,
                            "createdAt": "2026-03-20T12:00:00Z",
                            "author": {"login": "april-clearwater[bot]"},
                        }
                    ]
                },
            }
        ]
        classified = run_contributor.classify_execution_work(
            issues,
            [],
            [],
            issue_states={116: "OPEN"},
            owner_login="fairchild",
            persona="April Clearwater",
            bot_login="april-clearwater[bot]",
            now=datetime(2026, 3, 20, 13, 0, tzinfo=timezone.utc),
        )
        self.assertEqual(len(classified["claimed_issues"]), 1)
        self.assertEqual(classified["claimed_issues"][0]["issue_number"], 116)
        self.assertEqual(classified["own_open_prs"], [])
        self.assertEqual(classified["ready_issues"], [])

    def test_route_action_review_uses_app_token(self) -> None:
        validated_json = json.dumps(
            {
                "action": "review_pr",
                "persona": "Plat Ironwood",
                "pr_number": 119,
                "verdict": "request_changes",
                "body": "## Findings\n- Missing evidence status",
            }
        )
        env = {
            "GH_TOKEN": "app-token",
        }

        with (
            mock.patch.object(run_contributor, "find_pr_review_state", return_value=None),
            mock.patch.object(run_contributor, "run_checked") as run_checked,
            mock.patch.object(run_contributor, "_update_mergeable_label") as update_mergeable_label,
        ):
            run_checked.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")

            result = run_contributor.route_action(validated_json, False, env)

        self.assertEqual(result, 0)
        _, kwargs = run_checked.call_args
        self.assertEqual(kwargs["env"]["GH_TOKEN"], "app-token")
        mergeable_args, _ = update_mergeable_label.call_args
        self.assertEqual(mergeable_args[2]["GH_TOKEN"], "app-token")


    def test_runner_platform_note_macos(self) -> None:
        with mock.patch("platform.system", return_value="Darwin"):
            note = run_contributor.runner_platform_note()
        self.assertEqual(note, "Runner platform: macOS")

    def test_runner_platform_note_linux(self) -> None:
        with mock.patch("platform.system", return_value="Linux"):
            note = run_contributor.runner_platform_note()
        self.assertIn("Runner platform: Linux", note)
        self.assertIn("evidence_pending_ci", note)
        # The note starts with "Runner platform: Linux" — not macOS
        self.assertTrue(note.startswith("Runner platform: Linux"))

    def test_reconcile_leaves_blocked_items_unchanged(self) -> None:
        """[blocked] items written by a Linux runner must NOT be touched by reconcile.

        The reconcile step only resolves [pending-ci] lines. Demonstrating this
        ensures we don't accidentally silently pass a PR with legitimately blocked
        evidence after the macOS evidence job runs.
        """
        body = (
            "## Evidence Status\n"
            "- [blocked] swift build -- cannot build macOS targets on Linux\n\n"
            "## Validation\n"
            "- blocked on evidence: Linux runner cannot build Swift\n"
        )
        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
        )
        self.assertIn("- [blocked] swift build", reconciled)
        self.assertNotIn("[complete]", reconciled)

    def test_linux_runner_pending_ci_resolves_correctly(self) -> None:
        """[pending-ci] items written by a Linux runner ARE resolved by the macOS evidence job.

        This is the correct path: Linux runner writes evidence_pending_ci for
        build/test items; macOS evidence job calls reconcile_pending_ci_evidence
        and replaces them with [complete] or [blocked].
        """
        body = (
            "## Evidence Status\n"
            "- [pending-ci] swift build -- self-hosted macOS CI will build this\n"
            "- [pending-ci] swift test --filter RunPlannerTests -- self-hosted macOS CI will run this\n\n"
            "## Validation\n"
            "- blocked on evidence: macOS-only evidence deferred to CI\n"
        )
        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
        )
        accounting, errors = run_contributor.validate_evidence_accounting(
            reconciled,
            ["swift build", "swift test --filter RunPlannerTests"],
        )
        self.assertEqual(errors, [])
        self.assertEqual(accounting["pending_ci_items"], [])
        self.assertEqual(accounting["blocked_items"], [])
        self.assertEqual(
            accounting["complete_items"],
            ["swift build", "swift test --filter RunPlannerTests"],
        )


if __name__ == "__main__":
    unittest.main()
