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
run_contributor = load_module(
    "run_contributor",
    REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "run-contributor.py",
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
            blocked_by=[101],
            requested_evidence=["swift test --filter WorkspaceProviders"],
        )
        self.assertIn("- Ship this issue as one PR.", body)
        self.assertIn("## Blocked By", body)
        self.assertIn("- #101", body)
        self.assertIn("## Requested Evidence", body)
        self.assertIn("swift test --filter WorkspaceProviders", body)

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


if __name__ == "__main__":
    unittest.main()
