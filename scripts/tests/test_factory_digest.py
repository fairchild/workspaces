#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fixture tests for the Factory Digest issue writer.

Intent: protect the owner's single attention surface through deterministic
rendering and GitHub-boundary tests without mutating live issues.
"""

from __future__ import annotations

import importlib.util
import io
import os
import subprocess
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-digest.py"
FIXTURES_DIR = REPO_ROOT / "fixtures" / "factory-digest"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


factory_digest = load_module("factory_digest", SCRIPT_PATH)


class FactoryDigestTests(unittest.TestCase):
    maxDiff = None

    def test_render_digest_reports_factory_activity_and_cap_skip(self) -> None:
        summary = {
            "generated_at": "2026-07-14T13:30:00Z",
            "funnel": {},
            "breaches": [],
        }
        activity = factory_digest.FactoryActivity(
            implement_runs=7,
            review_verdicts=3,
            responder_replies=2,
            implement_daily_cap=6,
        )

        markdown = factory_digest.render_digest([], [], summary, activity)

        self.assertIn(
            "Factory activity: implement runs today 7/6 "
            "(cap exceeded; dispatches skipped) · review verdicts 3 · responder replies 2",
            markdown,
        )

    def test_count_successful_steps_counts_only_completed_target_steps(self) -> None:
        runs = [
            {"id": 1, "status": "completed"},
            {"id": 2, "status": "completed"},
            {"id": 3, "status": "in_progress"},
        ]
        jobs = {
            1: [
                {
                    "steps": [
                        {"name": "Post reply to gated target", "conclusion": "success"}
                    ]
                }
            ],
            2: [
                {
                    "steps": [
                        {"name": "Post reply to gated target", "conclusion": "skipped"}
                    ]
                }
            ],
        }

        with mock.patch.object(
            factory_digest,
            "fetch_run_jobs",
            side_effect=lambda _repo, _token, run_id: jobs[run_id],
        ) as fetch_jobs:
            count = factory_digest.count_successful_steps(
                "fairchild/workspaces",
                "token",
                runs,
                {"Post reply to gated target"},
            )

        self.assertEqual(count, 1)
        self.assertEqual(fetch_jobs.call_count, 2)

    def test_implement_activity_ignores_unrelated_label_event_runs(self) -> None:
        self.assertTrue(
            factory_digest.is_factory_implement_dispatch(
                {
                    "event": "issues",
                    "display_title": "Factory Implement ready #42",
                }
            )
        )
        self.assertTrue(
            factory_digest.is_factory_implement_dispatch(
                {"event": "workflow_dispatch", "display_title": "manual"}
            )
        )
        self.assertFalse(
            factory_digest.is_factory_implement_dispatch(
                {
                    "event": "issues",
                    "display_title": "Factory Implement claimed #42",
                }
            )
        )
        self.assertEqual(
            factory_digest.count_factory_implement_runs(
                [
                    {
                        "event": "issues",
                        "display_title": "Factory Implement ready #42",
                        "run_attempt": 2,
                    },
                    {"event": "workflow_dispatch", "run_attempt": 1},
                    {
                        "event": "issues",
                        "display_title": "Factory Implement claimed #42",
                        "run_attempt": 5,
                    },
                ]
            ),
            3,
        )

    def test_render_digest_orders_mergeable_linked_prs_first(self) -> None:
        summary = {
            "generated_at": "2026-07-12T13:30:00Z",
            "funnel": {"ideas": 4, "approved": 3, "planned": 2, "active": 1, "merged": 0},
            "breaches": [],
        }
        issues = [
            {
                "number": 10,
                "labels": [{"name": "mergeable"}],
                "state": "OPEN",
                "updatedAt": "2026-07-11T13:30:00Z",
            }
        ]
        pulls = [
            {
                "number": 20,
                "title": "Ordinary review",
                "url": "https://example.test/pull/20",
                "state": "OPEN",
                "isDraft": False,
                "createdAt": "2026-07-08T13:30:00Z",
                "updatedAt": "2026-07-12T10:00:00Z",
                "closingIssuesReferences": [],
            },
            {
                "number": 21,
                "title": "Ready to land",
                "url": "https://example.test/pull/21",
                "state": "OPEN",
                "isDraft": False,
                "createdAt": "2026-07-10T13:30:00Z",
                "updatedAt": "2026-07-12T11:00:00Z",
                "closingIssuesReferences": [{"number": 10}],
            },
        ]

        markdown = factory_digest.render_digest(issues, pulls, summary)

        self.assertIn(
            "## Needs your merge\n\n"
            "- no activity 0d [#21](https://example.test/pull/21) `Ready to land`: merge\n"
            "- no activity 0d [#20](https://example.test/pull/20) `Ordinary review`: review",
            markdown,
        )

    def test_render_digest_ignores_closed_mergeable_issue_for_pr_readiness(self) -> None:
        summary = {
            "generated_at": "2026-07-12T13:30:00Z",
            "funnel": {},
            "breaches": [],
        }
        issues = [
            {
                "number": 10,
                "labels": [{"name": "mergeable"}],
                "state": "CLOSED",
                "updatedAt": "2026-07-11T13:30:00Z",
            }
        ]
        pulls = [
            {
                "number": 21,
                "title": "Still needs review",
                "url": "https://example.test/pull/21",
                "state": "OPEN",
                "isDraft": False,
                "createdAt": "2026-07-10T13:30:00Z",
                "updatedAt": "2026-07-12T11:00:00Z",
                "closingIssuesReferences": [{"number": 10}],
            }
        ]

        markdown = factory_digest.render_digest(issues, pulls, summary)

        self.assertIn(
            "[#21](https://example.test/pull/21) `Still needs review`: review",
            markdown,
        )
        self.assertNotIn("`Still needs review`: merge", markdown)

    def test_render_digest_includes_release_aging_and_breach_sections(self) -> None:
        summary = {
            "generated_at": "2026-07-12T13:30:00Z",
            "funnel": {"ideas": 4, "approved": 3, "planned": 2, "active": 1, "merged": 0},
            "breaches": [
                {"category": "ci", "summary": "Failure rate crossed the threshold"},
                {"category": "throughput", "summary": "Planned work has no PR activity"},
            ],
        }
        issues = [
            {
                "number": 11,
                "title": "Available task",
                "url": "https://example.test/issues/11",
                "state": "OPEN",
                "updatedAt": "2026-07-09T13:30:00Z",
                "labels": [{"name": name} for name in ("agent", "task", "ready")],
            },
            {
                "number": 12,
                "title": "Owner decision",
                "url": "https://example.test/issues/12",
                "state": "OPEN",
                "updatedAt": "2026-07-07T13:30:00Z",
                "labels": [{"name": "needs-human"}],
            },
            {
                "number": 13,
                "title": "Claim went quiet",
                "url": "https://example.test/issues/13",
                "state": "OPEN",
                "updatedAt": "2026-07-10T13:29:59Z",
                "labels": [{"name": "claimed"}],
            },
            {
                "number": 14,
                "title": "Review went quiet",
                "url": "https://example.test/issues/14",
                "state": "OPEN",
                "updatedAt": "2026-07-12T12:00:00Z",
                "labels": [{"name": "review"}],
            },
            {
                "number": 15,
                "title": "Needs triage",
                "url": "https://example.test/issues/15",
                "state": "OPEN",
                "updatedAt": "2026-07-11T13:30:00Z",
                "labels": [{"name": "agent"}, {"name": "task"}],
            },
        ]
        pulls = [
            {
                "number": 24,
                "title": "Stalled review",
                "url": "https://example.test/pull/24",
                "state": "OPEN",
                "isDraft": False,
                "createdAt": "2026-07-01T13:30:00Z",
                "updatedAt": "2026-07-08T13:29:59Z",
                "closingIssuesReferences": [{"number": 14}],
            }
        ]

        markdown = factory_digest.render_digest(issues, pulls, summary)

        self.assertIn(
            "## Awaiting your release\n\n"
            "- no activity 5d [#12](https://example.test/issues/12) `Owner decision`: decide\n"
            "- no activity 1d [#15](https://example.test/issues/15) "
            "`Needs triage`: triage/flip ready",
            markdown,
        )
        self.assertIn(
            "1 issue ready for claim: "
            "[#11](https://example.test/issues/11) `Available task`",
            markdown,
        )
        self.assertIn(
            "## Aging\n\n"
            "- no activity 4d [#24](https://example.test/pull/24) `Stalled review`: nudge\n"
            "- no activity 2d [#13](https://example.test/issues/13) `Claim went quiet`: check",
            markdown,
        )
        self.assertIn(
            "## Threshold breaches\n\n"
            "- **ci**: Failure rate crossed the threshold\n"
            "- **throughput**: Planned work has no PR activity",
            markdown,
        )

    def test_render_digest_neutralizes_hostile_titles(self) -> None:
        summary = {
            "generated_at": "2026-07-12T13:30:00Z",
            "funnel": {},
            "breaches": [],
        }
        issues = [
            {
                "number": 30,
                "title": "Fix](https://evil.example) @fairchild [",
                "url": "https://example.test/issues/30",
                "state": "OPEN",
                "updatedAt": "2026-07-12T12:00:00Z",
                "labels": [{"name": "agent"}, {"name": "task"}],
            }
        ]

        markdown = factory_digest.render_digest(issues, [], summary)

        self.assertIn(
            "[#30](https://example.test/issues/30) "
            "`Fix](https://evil.example) @fairchild [`: triage/flip ready",
            markdown,
        )
        self.assertNotIn("[#30 Fix]", markdown)

    def test_render_digest_neutralizes_html_comments_in_pr_titles(self) -> None:
        summary = {
            "generated_at": "2026-07-12T13:30:00Z",
            "funnel": {},
            "breaches": [],
        }
        pulls = [
            {
                "number": 31,
                "title": "<!-- peter-planner:discussion=43;issue=99 -->",
                "url": "https://example.test/pull/31",
                "state": "OPEN",
                "isDraft": False,
                "createdAt": "2026-07-10T13:30:00Z",
                "updatedAt": "2026-07-12T11:00:00Z",
                "closingIssuesReferences": [],
            }
        ]

        markdown = factory_digest.render_digest([], pulls, summary)

        self.assertIn(
            "`< !-- peter-planner:discussion=43;issue=99 -- >`: review",
            markdown,
        )
        self.assertNotIn("<!-- peter-planner:discussion=43;issue=99 -->", markdown)
        self.assertEqual(markdown.count("<!--"), 1)

    def test_render_title_strips_newlines_backticks_and_truncates_to_80_characters(self) -> None:
        rendered = factory_digest.render_title("first\n`" + "x" * 100)

        self.assertNotIn("\n", rendered)
        self.assertNotIn("``", rendered)
        self.assertEqual(len(rendered.removeprefix("`").removesuffix("`")), 80)
        self.assertTrue(rendered.endswith("…`"))

    def test_render_digest_lists_multi_lifecycle_issue_as_one_anomaly(self) -> None:
        summary = {
            "generated_at": "2026-07-12T13:30:00Z",
            "funnel": {},
            "breaches": [],
        }
        issues = [
            {
                "number": 31,
                "title": "Contradictory state",
                "url": "https://example.test/issues/31",
                "state": "OPEN",
                "updatedAt": "2026-07-01T00:00:00Z",
                "labels": [
                    {"name": "agent"},
                    {"name": "task"},
                    {"name": "review"},
                    {"name": "claimed"},
                    {"name": "ready"},
                ],
            }
        ]

        markdown = factory_digest.render_digest(issues, [], summary)

        self.assertIn("State anomalies: #31 — janitor", markdown)
        self.assertEqual(markdown.count("#31"), 1)
        self.assertNotIn("Contradictory state", markdown)
        self.assertNotIn("ready for claim", markdown)

    def test_render_digest_excludes_its_marked_issue_before_every_bucket(self) -> None:
        summary = {
            "generated_at": "2026-07-12T13:30:00Z",
            "funnel": {},
            "breaches": [],
        }
        bucket_labels = (
            [{"name": "needs-human"}],
            [{"name": "agent"}, {"name": "task"}],
            [{"name": "ready"}],
            [{"name": "ready"}, {"name": "claimed"}],
        )

        for labels in bucket_labels:
            with self.subTest(labels=labels):
                digest_issue = {
                    "id": "I_digest",
                    "number": 1075,
                    "title": "Renamed digest",
                    "body": f" \n\t{factory_digest.DIGEST_MARKER}\nold",
                    "url": "https://example.test/issues/1075",
                    "state": "OPEN",
                    "createdAt": "2026-07-01T00:00:00Z",
                    "updatedAt": "2026-07-01T00:00:00Z",
                    "labels": labels,
                }

                markdown = factory_digest.render_digest([digest_issue], [], summary)

                self.assertNotIn("#1075", markdown)
                self.assertNotIn("Awaiting your release", markdown)
                self.assertNotIn("ready for claim", markdown)
                self.assertNotIn("State anomalies", markdown)
                self.assertIn("No open gates. The factory is idle.", markdown)

    def test_render_digest_does_not_itemize_more_than_three_ready_issues(self) -> None:
        summary = {
            "generated_at": "2026-07-12T13:30:00Z",
            "funnel": {},
            "breaches": [],
        }
        issues = [
            {
                "number": number,
                "title": f"Ready {number}",
                "url": f"https://example.test/issues/{number}",
                "state": "OPEN",
                "updatedAt": "2026-07-12T12:00:00Z",
                "labels": [{"name": "ready"}],
            }
            for number in range(40, 44)
        ]

        markdown = factory_digest.render_digest(issues, [], summary)

        self.assertIn("4 issues ready for claim", markdown)
        self.assertNotIn("#40", markdown)

    def test_cli_renders_basic_fixture_without_network_access(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--fixtures-dir",
                str(FIXTURES_DIR / "basic"),
                "--summary",
                str(FIXTURES_DIR / "basic" / "latest-summary.json"),
                "--dry-run",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("## Needs your merge", result.stdout)
        self.assertIn("## Awaiting your release", result.stdout)
        self.assertIn("## Aging", result.stdout)
        self.assertIn("## Threshold breaches", result.stdout)
        self.assertNotIn("#108", result.stdout)
        self.assertNotIn("State anomalies", result.stdout)

    def test_cli_idle_fixture_prints_only_idle_line_and_stats(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--fixtures-dir",
                str(FIXTURES_DIR / "idle"),
                "--summary",
                str(FIXTURES_DIR / "idle" / "latest-summary.json"),
                "--dry-run",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "<!-- factory-digest:v1 -->\n\n"
            "No open gates. The factory is idle.\n\n"
            "Factory activity: implement runs today 0/6 · review verdicts 0 · "
            "responder replies 0\n\n"
            "Stats: ideas 0 · approved 0 · planned 0 · active 0 · merged 0 · stalled 0 "
            "· generated 2026-07-12T13:30:00Z\n",
        )

    def test_cli_fixture_mode_rejects_writes(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--fixtures-dir",
                str(FIXTURES_DIR / "idle"),
                "--summary",
                str(FIXTURES_DIR / "idle" / "latest-summary.json"),
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("--fixtures-dir requires --dry-run", result.stderr)

    def test_publish_digest_matches_leading_marker_but_not_mid_body_inline_code(self) -> None:
        repo = factory_digest.RepoInfo("fairchild", "workspaces", "R_1", {})
        issues = [
            {
                "id": "I_1",
                "number": 99,
                "title": "Renamed by the owner",
                "body": " \n\t<!-- factory-digest:v1 -->\nold digest",
                "url": "https://example.test/issues/99",
                "state": "OPEN",
                "createdAt": "2026-07-01T00:00:00Z",
            },
            {
                "id": "I_1075",
                "number": 1075,
                "title": "Digest as pinned issue",
                "body": "The writer emits `<!-- factory-digest:v1 -->` as its first line.",
                "url": "https://example.test/issues/1075",
                "state": "OPEN",
                "createdAt": "2026-07-12T00:00:00Z",
            },
        ]

        with mock.patch.object(
            factory_digest,
            "graphql",
            return_value={
                "data": {
                    "updateIssue": {
                        "issue": {
                            "id": "I_1",
                            "number": 99,
                            "url": "https://example.test/issues/99",
                        }
                    }
                }
            },
        ) as graphql:
            result = factory_digest.publish_digest(repo, issues, "digest body", "token")

        self.assertEqual(result["number"], 99)
        query = graphql.call_args.args[1]
        variables = graphql.call_args.args[2]
        self.assertIn("updateIssue", query)
        self.assertEqual(
            variables["input"],
            {
                "id": "I_1",
                "body": "<!-- factory-digest:v1 -->\n\ndigest body",
            },
        )
        self.assertNotIn("title", variables["input"])
        self.assertNotIn("labelIds", variables["input"])

    def test_publish_digest_reopens_closed_marked_issue_before_update(self) -> None:
        repo = factory_digest.RepoInfo("fairchild", "workspaces", "R_1", {})
        issue = {
            "id": "I_closed",
            "number": 98,
            "title": "Old title",
            "body": "<!-- factory-digest:v1 -->\n\nold",
            "url": "https://example.test/issues/98",
            "state": "CLOSED",
            "createdAt": "2026-07-01T00:00:00Z",
        }
        operations: list[str] = []

        def fake_graphql(token: str, query: str, variables: dict[str, object]):
            if "reopenIssue" in query:
                operations.append("reopen")
                self.assertEqual(variables["input"], {"issueId": "I_closed"})
                return {"data": {"reopenIssue": {"issue": issue}}}
            operations.append("update")
            return {"data": {"updateIssue": {"issue": issue}}}

        with mock.patch.object(factory_digest, "graphql", side_effect=fake_graphql):
            result = factory_digest.publish_digest(repo, [issue], "new body", "token")

        self.assertEqual(result["number"], 98)
        self.assertEqual(operations, ["reopen", "update"])

    def test_publish_digest_creates_factory_label_and_labeled_issue_then_tolerates_pin_failure(
        self,
    ) -> None:
        repo = factory_digest.RepoInfo(
            owner="fairchild",
            name="workspaces",
            repository_id="R_1",
            label_ids={"human": "L_human"},
        )
        calls: list[tuple[str, dict[str, object]]] = []

        def fake_graphql(token: str, query: str, variables: dict[str, object]):
            calls.append((query, variables))
            if "createLabel" in query:
                return {"data": {"createLabel": {"label": {"id": "L_factory"}}}}
            if "createIssue" in query:
                return {
                    "data": {
                        "createIssue": {
                            "issue": {
                                "id": "I_2",
                                "number": 100,
                                "url": "https://example.test/issues/100",
                            }
                        }
                    }
                }
            raise factory_digest.FactoryDigestError("pinIssue is unavailable")

        stderr = io.StringIO()
        with mock.patch.object(factory_digest, "graphql", side_effect=fake_graphql):
            with redirect_stderr(stderr):
                result = factory_digest.publish_digest(repo, [], "digest body", "token")

        self.assertEqual(result["number"], 100)
        self.assertEqual(len(calls), 3)
        self.assertEqual(
            calls[0][1]["input"],
            {
                "repositoryId": "R_1",
                "name": "factory",
                "color": factory_digest.FACTORY_LABEL_COLOR,
                "description": factory_digest.FACTORY_LABEL_DESCRIPTION,
            },
        )
        self.assertEqual(
            calls[1][1]["input"],
            {
                "repositoryId": "R_1",
                "title": "Factory Digest",
                "body": "<!-- factory-digest:v1 -->\n\ndigest body",
                "labelIds": ["L_factory", "L_human"],
            },
        )
        self.assertIn("pinIssue", calls[2][0])
        self.assertEqual(calls[2][1]["input"], {"issueId": "I_2"})
        self.assertIn("warning: unable to pin Factory Digest", stderr.getvalue())

    def test_publish_digest_leaves_unmarked_same_title_issue_untouched_then_rediscovers_created(
        self,
    ) -> None:
        repo = factory_digest.RepoInfo(
            owner="fairchild",
            name="workspaces",
            repository_id="R_1",
            label_ids={"factory": "L_factory", "human": "L_human"},
        )
        unmarked = {
            "id": "I_unmarked",
            "number": 90,
            "title": "Factory Digest",
            "body": "owner-authored issue",
            "url": "https://example.test/issues/90",
            "state": "OPEN",
            "createdAt": "2026-06-01T00:00:00Z",
        }
        issues: list[dict[str, object]] = [unmarked]
        operations: list[str] = []

        def fake_graphql(token: str, query: str, variables: dict[str, object]):
            if "createIssue" in query:
                operations.append("create")
                issue = {
                    "id": "I_marked",
                    "number": 100,
                    "title": "Factory Digest",
                    "body": variables["input"]["body"],
                    "url": "https://example.test/issues/100",
                    "state": "OPEN",
                    "createdAt": "2026-07-01T00:00:00Z",
                }
                issues.append(issue)
                return {"data": {"createIssue": {"issue": issue}}}
            if "pinIssue" in query:
                operations.append("pin")
                return {"data": {"pinIssue": {"issue": issues[-1]}}}
            operations.append("update")
            self.assertEqual(variables["input"]["id"], "I_marked")
            return {"data": {"updateIssue": {"issue": issues[-1]}}}

        with mock.patch.object(factory_digest, "graphql", side_effect=fake_graphql):
            factory_digest.publish_digest(repo, issues, "first body", "token")
            factory_digest.publish_digest(repo, issues, "second body", "token")

        self.assertEqual(len(issues), 2)
        self.assertEqual(unmarked["body"], "owner-authored issue")
        self.assertEqual(operations, ["create", "pin", "update"])

    def test_publish_digest_warns_and_uses_most_recent_marked_issue(self) -> None:
        repo = factory_digest.RepoInfo("fairchild", "workspaces", "R_1", {})
        issues = [
            {
                "id": "I_old",
                "number": 70,
                "title": "Factory Digest",
                "body": "<!-- factory-digest:v1 -->",
                "state": "OPEN",
                "createdAt": "2026-07-01T00:00:00Z",
            },
            {
                "id": "I_new",
                "number": 71,
                "title": "Renamed digest",
                "body": "<!-- factory-digest:v1 -->",
                "state": "OPEN",
                "createdAt": "2026-07-02T00:00:00Z",
            },
        ]
        stderr = io.StringIO()

        with mock.patch.object(
            factory_digest,
            "graphql",
            return_value={"data": {"updateIssue": {"issue": issues[1]}}},
        ) as graphql:
            with redirect_stderr(stderr):
                factory_digest.publish_digest(repo, issues, "body", "token")

        self.assertEqual(graphql.call_args.args[2]["input"]["id"], "I_new")
        self.assertIn("using #71 and leaving #70 untouched", stderr.getvalue())

    def test_publish_digest_uses_higher_issue_number_as_created_at_tiebreaker(self) -> None:
        repo = factory_digest.RepoInfo("fairchild", "workspaces", "R_1", {})
        issues = [
            {
                "id": "I_exact",
                "number": 72,
                "title": "Factory Digest",
                "body": "<!-- factory-digest:v1 -->",
                "state": "OPEN",
                "createdAt": "2026-07-02T00:00:00Z",
            },
            {
                "id": "I_renamed",
                "number": 73,
                "title": "Renamed digest",
                "body": "<!-- factory-digest:v1 -->",
                "state": "OPEN",
                "createdAt": "2026-07-02T00:00:00Z",
            },
        ]

        with mock.patch.object(
            factory_digest,
            "graphql",
            return_value={"data": {"updateIssue": {"issue": issues[1]}}},
        ) as graphql:
            with redirect_stderr(io.StringIO()):
                factory_digest.publish_digest(repo, issues, "body", "token")

        self.assertEqual(graphql.call_args.args[2]["input"]["id"], "I_renamed")

    def test_publish_digest_propagates_create_and_update_api_failures(self) -> None:
        repo = factory_digest.RepoInfo(
            owner="fairchild",
            name="workspaces",
            repository_id="R_1",
            label_ids={"factory": "L_factory", "human": "L_human"},
        )
        existing = [
            {
                "id": "I_1",
                "number": 1,
                "title": "Factory Digest",
                "body": "<!-- factory-digest:v1 -->",
                "state": "OPEN",
                "createdAt": "2026-07-01T00:00:00Z",
            }
        ]

        with mock.patch.object(
            factory_digest,
            "graphql",
            side_effect=factory_digest.FactoryDigestError("permission denied"),
        ):
            for issues in (existing, []):
                with self.assertRaises(factory_digest.FactoryDigestError) as raised:
                    factory_digest.publish_digest(repo, issues, "body", "token")
                self.assertEqual(str(raised.exception), "permission denied")

    def test_fetch_live_inputs_paginates_and_normalizes_github_nodes(self) -> None:
        calls: list[tuple[str, str, str | None]] = []

        def fake_graphql(token: str, query: str, variables: dict[str, object]):
            calls.append((token, query, variables.get("after")))
            if "FactoryDigestIssues" in query:
                cursor = variables.get("after")
                return {
                    "data": {
                        "repository": {
                            "id": "R_1",
                            "factoryLabel": {"id": "L_factory", "name": "factory"},
                            "humanLabel": {"id": "L_human", "name": "human"},
                            "issues": {
                                "pageInfo": {
                                    "hasNextPage": cursor is None,
                                    "endCursor": "next" if cursor is None else None,
                                },
                                "nodes": [
                                    {
                                        "id": "I_1" if cursor is None else "I_2",
                                        "number": 10 if cursor is None else 11,
                                        "title": "First" if cursor is None else "Digest",
                                        "body": (
                                            "<!-- factory-digest:v1 -->"
                                            if cursor is not None
                                            else "unmarked"
                                        ),
                                        "url": "https://example.test/issues/10",
                                        "state": "OPEN" if cursor is None else "CLOSED",
                                        "createdAt": "2026-07-01T00:00:00Z",
                                        "updatedAt": "2026-07-02T00:00:00Z",
                                        "labels": {
                                            "nodes": [{"name": "ready"}]
                                            if cursor is None
                                            else [{"name": "human"}]
                                        },
                                    }
                                ],
                            },
                        }
                    }
                }
            return {
                "data": {
                    "repository": {
                        "pullRequests": {
                            "pageInfo": {"hasNextPage": False, "endCursor": None},
                            "nodes": [
                                {
                                    "number": 20,
                                    "title": "Pull",
                                    "url": "https://example.test/pulls/20",
                                    "state": "OPEN",
                                    "isDraft": False,
                                    "createdAt": "2026-07-01T00:00:00Z",
                                    "updatedAt": "2026-07-02T00:00:00Z",
                                    "closingIssuesReferences": {"nodes": [{"number": 10}]},
                                }
                            ],
                        }
                    }
                }
            }

        with mock.patch.object(
            factory_digest, "graphql", side_effect=fake_graphql
        ) as graphql:
            inputs = factory_digest.fetch_live_inputs(
                "fairchild/workspaces", "read-token"
            )

        issue_queries = [
            call.args[1]
            for call in graphql.call_args_list
            if "FactoryDigestIssues" in call.args[1]
        ]
        self.assertEqual(len(issue_queries), 2)
        self.assertIn("states: [OPEN, CLOSED]", issue_queries[0])
        self.assertIn("id number title body url state", issue_queries[0])
        self.assertEqual(inputs.repo.label_ids, {"factory": "L_factory", "human": "L_human"})
        self.assertEqual(inputs.issues[1]["state"], "CLOSED")
        self.assertIn(factory_digest.DIGEST_MARKER, inputs.issues[1]["body"])
        self.assertEqual(inputs.issues[0]["labels"], [{"name": "ready"}])
        self.assertEqual(inputs.pulls[0]["closingIssuesReferences"], [{"number": 10}])
        self.assertFalse(
            any("Discussion" in query or "discussion" in query for _, query, _ in calls)
        )
        self.assertTrue(all(token == "read-token" for token, _, _ in calls))

    def test_main_live_dry_run_reads_but_never_publishes(self) -> None:
        inputs = factory_digest.DigestInputs(
            repo=factory_digest.RepoInfo("fairchild", "workspaces", "R_1", {}),
            issues=[],
            pulls=[],
        )
        args = mock.Mock(
            summary=FIXTURES_DIR / "idle" / "latest-summary.json",
            fixtures_dir=None,
            dry_run=True,
        )
        stdout = io.StringIO()
        with mock.patch.object(factory_digest, "parse_args", return_value=args):
            with mock.patch.object(factory_digest, "fetch_live_inputs", return_value=inputs):
                with mock.patch.object(
                    factory_digest,
                    "fetch_factory_activity",
                    return_value=factory_digest.FactoryActivity(),
                ):
                    with mock.patch.object(
                        factory_digest,
                        "publish_digest",
                        side_effect=AssertionError("publish_digest called"),
                    ):
                        with mock.patch.dict(
                            os.environ,
                            {
                                "GITHUB_REPOSITORY": "fairchild/workspaces",
                                "GH_TOKEN": "read-token",
                            },
                            clear=True,
                        ):
                            with mock.patch("sys.stdout", stdout):
                                result = factory_digest.main()

        self.assertEqual(result, 0)
        self.assertIn("No open gates. The factory is idle.", stdout.getvalue())

    def test_main_uses_gh_token_for_reads_and_issue_write(self) -> None:
        inputs = factory_digest.DigestInputs(
            repo=factory_digest.RepoInfo(
                "fairchild",
                "workspaces",
                "R_1",
                {"factory": "L_factory", "human": "L_human"},
            ),
            issues=[],
            pulls=[],
        )
        args = mock.Mock(
            summary=FIXTURES_DIR / "idle" / "latest-summary.json",
            fixtures_dir=None,
            dry_run=False,
        )
        with mock.patch.object(factory_digest, "parse_args", return_value=args):
            with mock.patch.object(
                factory_digest, "fetch_live_inputs", return_value=inputs
            ) as fetch:
                with mock.patch.object(
                    factory_digest,
                    "fetch_factory_activity",
                    return_value=factory_digest.FactoryActivity(),
                ):
                    with mock.patch.object(
                        factory_digest,
                        "publish_digest",
                        return_value={"url": "https://example.test/issues/1"},
                    ) as publish:
                        with mock.patch.dict(
                            os.environ,
                            {
                                "GITHUB_REPOSITORY": "fairchild/workspaces",
                                "GH_TOKEN": "actions-token",
                            },
                            clear=True,
                        ):
                            with mock.patch("sys.stdout", io.StringIO()):
                                result = factory_digest.main()

        self.assertEqual(result, 0)
        fetch.assert_called_once_with("fairchild/workspaces", "actions-token")
        self.assertEqual(publish.call_args.args[3], "actions-token")


if __name__ == "__main__":
    unittest.main()
