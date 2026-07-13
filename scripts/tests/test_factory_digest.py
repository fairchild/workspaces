#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fixture tests for the Factory Digest writer.

Intent: protect the owner's single attention surface through deterministic
rendering and GitHub-boundary tests without mutating live discussions.
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

    def test_publish_digest_rediscovers_marked_digest_after_rename(self) -> None:
        repo = factory_digest.RepoInfo(
            owner="fairchild",
            name="workspaces",
            repository_id="R_1",
            category_ids={"announcements": "C_1", "general": "C_2"},
        )
        discussions = [
            {
                "id": "D_1",
                "number": 99,
                "title": "Renamed by the owner",
                "body": "intro\n<!-- factory-digest:v1 -->\nold digest",
                "url": "https://example.test/discussions/99",
                "state": "OPEN",
                "createdAt": "2026-07-01T00:00:00Z",
            }
        ]

        with mock.patch.object(
            factory_digest,
            "graphql",
            return_value={
                "data": {
                    "updateDiscussion": {
                        "discussion": {
                            "id": "D_1",
                            "number": 99,
                            "url": "https://example.test/discussions/99",
                        }
                    }
                }
            },
        ) as graphql:
            result = factory_digest.publish_digest(repo, discussions, "digest body", "write-token")

        self.assertEqual(result["number"], 99)
        query = graphql.call_args.args[1]
        variables = graphql.call_args.args[2]
        self.assertIn("updateDiscussion", query)
        self.assertEqual(
            variables["input"],
            {
                "discussionId": "D_1",
                "body": "<!-- factory-digest:v1 -->\n\ndigest body",
            },
        )
        self.assertNotIn("title", variables["input"])

    def test_publish_digest_reopens_closed_marked_digest_before_update(self) -> None:
        repo = factory_digest.RepoInfo("fairchild", "workspaces", "R_1", {"general": "C_1"})
        discussion = {
            "id": "D_closed",
            "number": 98,
            "title": "Old title",
            "body": "<!-- factory-digest:v1 -->\n\nold",
            "url": "https://example.test/discussions/98",
            "state": "CLOSED",
            "createdAt": "2026-07-01T00:00:00Z",
        }
        operations: list[str] = []

        def fake_graphql(token: str, query: str, variables: dict[str, object]):
            if "reopenDiscussion" in query:
                operations.append("reopen")
                return {"data": {"reopenDiscussion": {"discussion": discussion}}}
            operations.append("update")
            return {"data": {"updateDiscussion": {"discussion": discussion}}}

        with mock.patch.object(factory_digest, "graphql", side_effect=fake_graphql):
            result = factory_digest.publish_digest(repo, [discussion], "new body", "write-token")

        self.assertEqual(result["number"], 98)
        self.assertEqual(operations, ["reopen", "update"])

    def test_publish_digest_creates_in_announcements_and_tolerates_pin_failure(self) -> None:
        repo = factory_digest.RepoInfo(
            owner="fairchild",
            name="workspaces",
            repository_id="R_1",
            category_ids={"announcements": "C_1", "general": "C_2"},
        )
        calls: list[tuple[str, dict[str, object]]] = []

        def fake_graphql(token: str, query: str, variables: dict[str, object]):
            calls.append((query, variables))
            if "createDiscussion" in query:
                return {
                    "data": {
                        "createDiscussion": {
                            "discussion": {
                                "id": "D_2",
                                "number": 100,
                                "url": "https://example.test/discussions/100",
                            }
                        }
                    }
                }
            raise factory_digest.FactoryDigestError("pinDiscussion is unavailable")

        stderr = io.StringIO()
        with mock.patch.object(factory_digest, "graphql", side_effect=fake_graphql):
            with redirect_stderr(stderr):
                result = factory_digest.publish_digest(repo, [], "digest body", "write-token")

        self.assertEqual(result["number"], 100)
        self.assertEqual(len(calls), 2)
        self.assertEqual(
            calls[0][1]["input"],
            {
                "repositoryId": "R_1",
                "categoryId": "C_1",
                "title": "Factory Digest",
                "body": "<!-- factory-digest:v1 -->\n\ndigest body",
            },
        )
        self.assertIn("pinDiscussion", calls[1][0])
        self.assertIn("warning: unable to pin Factory Digest", stderr.getvalue())

    def test_publish_digest_leaves_unmarked_same_title_untouched_then_rediscovers_created_digest(
        self,
    ) -> None:
        repo = factory_digest.RepoInfo(
            owner="fairchild",
            name="workspaces",
            repository_id="R_1",
            category_ids={"general": "C_general"},
        )
        unmarked = {
            "id": "D_unmarked",
            "number": 90,
            "title": "Factory Digest",
            "body": "owner-authored discussion",
            "url": "https://example.test/discussions/90",
            "state": "OPEN",
            "createdAt": "2026-06-01T00:00:00Z",
        }
        discussions: list[dict[str, object]] = [unmarked]
        operations: list[str] = []

        def fake_graphql(token: str, query: str, variables: dict[str, object]):
            if "createDiscussion" in query:
                operations.append("create")
                self.assertEqual(variables["input"]["categoryId"], "C_general")
                discussion = {
                    "id": "D_marked",
                    "number": 100,
                    "title": "Factory Digest",
                    "body": variables["input"]["body"],
                    "url": "https://example.test/discussions/100",
                    "state": "OPEN",
                    "createdAt": "2026-07-01T00:00:00Z",
                }
                discussions.append(discussion)
                return {"data": {"createDiscussion": {"discussion": discussion}}}
            if "pinDiscussion" in query:
                operations.append("pin")
                return {"data": {"pinDiscussion": {"discussion": discussions[-1]}}}
            operations.append("update")
            self.assertEqual(variables["input"]["discussionId"], "D_marked")
            return {"data": {"updateDiscussion": {"discussion": discussions[-1]}}}

        with mock.patch.object(factory_digest, "graphql", side_effect=fake_graphql):
            factory_digest.publish_digest(repo, discussions, "first body", "write-token")
            factory_digest.publish_digest(repo, discussions, "second body", "write-token")

        self.assertEqual(len(discussions), 2)
        self.assertEqual(unmarked["body"], "owner-authored discussion")
        self.assertEqual(operations, ["create", "pin", "update"])

    def test_publish_digest_warns_and_uses_most_recent_marked_discussion(self) -> None:
        repo = factory_digest.RepoInfo("fairchild", "workspaces", "R_1", {"general": "C_1"})
        discussions = [
            {
                "id": "D_old",
                "number": 70,
                "title": "Factory Digest",
                "body": "<!-- factory-digest:v1 -->",
                "state": "OPEN",
                "createdAt": "2026-07-01T00:00:00Z",
            },
            {
                "id": "D_new",
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
            return_value={"data": {"updateDiscussion": {"discussion": discussions[1]}}},
        ) as graphql:
            with redirect_stderr(stderr):
                factory_digest.publish_digest(repo, discussions, "body", "write-token")

        self.assertEqual(graphql.call_args.args[2]["input"]["discussionId"], "D_new")
        self.assertIn("using #71 and leaving #70 untouched", stderr.getvalue())

    def test_publish_digest_uses_exact_title_only_as_created_at_tiebreaker(self) -> None:
        repo = factory_digest.RepoInfo("fairchild", "workspaces", "R_1", {"general": "C_1"})
        discussions = [
            {
                "id": "D_renamed",
                "number": 72,
                "title": "Renamed digest",
                "body": "<!-- factory-digest:v1 -->",
                "state": "OPEN",
                "createdAt": "2026-07-02T00:00:00Z",
            },
            {
                "id": "D_exact",
                "number": 73,
                "title": "Factory Digest",
                "body": "<!-- factory-digest:v1 -->",
                "state": "OPEN",
                "createdAt": "2026-07-02T00:00:00Z",
            },
        ]

        with mock.patch.object(
            factory_digest,
            "graphql",
            return_value={"data": {"updateDiscussion": {"discussion": discussions[1]}}},
        ) as graphql:
            with redirect_stderr(io.StringIO()):
                factory_digest.publish_digest(repo, discussions, "body", "write-token")

        self.assertEqual(graphql.call_args.args[2]["input"]["discussionId"], "D_exact")

    def test_publish_digest_explains_create_and_update_access_failures(self) -> None:
        repo = factory_digest.RepoInfo(
            owner="fairchild",
            name="workspaces",
            repository_id="R_1",
            category_ids={"general": "C_1"},
        )
        existing = [
            {
                "id": "D_1",
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
            for discussions in (existing, []):
                with self.assertRaises(factory_digest.FactoryDigestError) as raised:
                    factory_digest.publish_digest(repo, discussions, "body", "write-token")
                self.assertEqual(str(raised.exception), factory_digest.DISCUSSION_WRITE_ACCESS_ERROR)

    def test_discussion_schema_failure_uses_the_access_diagnostic(self) -> None:
        with mock.patch.object(
            factory_digest,
            "graphql",
            side_effect=factory_digest.FactoryDigestError(
                "GitHub GraphQL error: Field 'updateDiscussion' is not defined"
            ),
        ):
            with self.assertRaises(factory_digest.FactoryDigestError) as raised:
                factory_digest.run_discussion_write("token", "mutation", {})

        self.assertEqual(str(raised.exception), factory_digest.DISCUSSION_WRITE_ACCESS_ERROR)

    def test_fetch_live_inputs_paginates_and_normalizes_github_nodes(self) -> None:
        calls: list[tuple[str, str | None]] = []

        def fake_graphql(token: str, query: str, variables: dict[str, object]):
            calls.append((token, variables.get("after")))
            if "FactoryDigestDiscussions" in query:
                cursor = variables.get("after")
                return {
                    "data": {
                        "repository": {
                            "id": "R_1",
                            "discussionCategories": {
                                "nodes": [
                                    {"id": "C_1", "name": "Announcements"},
                                    {"id": "C_2", "name": "General"},
                                ]
                            },
                            "discussions": {
                                "pageInfo": {
                                    "hasNextPage": cursor is None,
                                    "endCursor": "next" if cursor is None else None,
                                },
                                "nodes": [
                                    {
                                        "id": "D_1" if cursor is None else "D_2",
                                        "number": 1 if cursor is None else 2,
                                        "title": "First" if cursor is None else "Second",
                                        "body": (
                                            "<!-- factory-digest:v1 -->"
                                            if cursor is not None
                                            else "unmarked"
                                        ),
                                        "url": "https://example.test/discussions/1",
                                        "state": "OPEN" if cursor is None else "CLOSED",
                                        "createdAt": "2026-07-01T00:00:00Z",
                                    }
                                ],
                            },
                        }
                    }
                }
            if "FactoryDigestIssues" in query:
                return {
                    "data": {
                        "repository": {
                            "issues": {
                                "pageInfo": {"hasNextPage": False, "endCursor": None},
                                "nodes": [
                                    {
                                        "number": 10,
                                        "title": "Issue",
                                        "url": "https://example.test/issues/10",
                                        "state": "OPEN",
                                        "createdAt": "2026-07-01T00:00:00Z",
                                        "updatedAt": "2026-07-02T00:00:00Z",
                                        "labels": {"nodes": [{"name": "ready"}]},
                                    }
                                ],
                            }
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

        self.assertEqual([item["title"] for item in inputs.discussions], ["First", "Second"])
        discussion_queries = [
            call.args[1]
            for call in graphql.call_args_list
            if "FactoryDigestDiscussions" in call.args[1]
        ]
        self.assertTrue(discussion_queries)
        self.assertIn("states: [OPEN, CLOSED]", discussion_queries[0])
        self.assertEqual(inputs.discussions[1]["state"], "CLOSED")
        self.assertIn(factory_digest.DIGEST_MARKER, inputs.discussions[1]["body"])
        self.assertEqual(inputs.issues[0]["labels"], [{"name": "ready"}])
        self.assertEqual(inputs.pulls[0]["closingIssuesReferences"], [{"number": 10}])
        self.assertTrue(all(token == "read-token" for token, _ in calls))

    def test_main_live_dry_run_reads_but_never_publishes(self) -> None:
        inputs = factory_digest.DigestInputs(
            repo=factory_digest.RepoInfo("fairchild", "workspaces", "R_1", {}),
            discussions=[],
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
                    "publish_digest",
                    side_effect=AssertionError("publish_digest called"),
                ):
                    with mock.patch.dict(
                        os.environ,
                        {"GITHUB_REPOSITORY": "fairchild/workspaces", "GH_TOKEN": "read-token"},
                        clear=True,
                    ):
                        with mock.patch("sys.stdout", stdout):
                            result = factory_digest.main()

        self.assertEqual(result, 0)
        self.assertIn("No open gates. The factory is idle.", stdout.getvalue())

    def test_main_uses_digest_token_only_for_the_write(self) -> None:
        inputs = factory_digest.DigestInputs(
            repo=factory_digest.RepoInfo("fairchild", "workspaces", "R_1", {}),
            discussions=[{"id": "D_1", "title": "Factory Digest"}],
            issues=[],
            pulls=[],
        )
        args = mock.Mock(
            summary=FIXTURES_DIR / "idle" / "latest-summary.json",
            fixtures_dir=None,
            dry_run=False,
        )
        with mock.patch.object(factory_digest, "parse_args", return_value=args):
            with mock.patch.object(factory_digest, "fetch_live_inputs", return_value=inputs) as fetch:
                with mock.patch.object(
                    factory_digest,
                    "publish_digest",
                    return_value={"url": "https://example.test/discussions/1"},
                ) as publish:
                    with mock.patch.dict(
                        os.environ,
                        {
                            "GITHUB_REPOSITORY": "fairchild/workspaces",
                            "GH_TOKEN": "read-token",
                            "DIGEST_TOKEN": "write-token",
                        },
                        clear=True,
                    ):
                        with mock.patch("sys.stdout", io.StringIO()):
                            result = factory_digest.main()

        self.assertEqual(result, 0)
        fetch.assert_called_once_with("fairchild/workspaces", "read-token")
        self.assertEqual(publish.call_args.args[3], "write-token")


if __name__ == "__main__":
    unittest.main()
