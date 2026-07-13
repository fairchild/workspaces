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
            "- [2d] [#21 Ready to land](https://example.test/pull/21): merge\n"
            "- [4d] [#20 Ordinary review](https://example.test/pull/20): review",
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
            "## Awaiting release\n\n"
            "- [5d] [#12 Owner decision](https://example.test/issues/12): decide\n"
            "- [3d] [#11 Available task](https://example.test/issues/11): available for claim",
            markdown,
        )
        self.assertIn(
            "## Aging\n\n"
            "- [4d] [#24 Stalled review](https://example.test/pull/24): nudge\n"
            "- [2d] [#13 Claim went quiet](https://example.test/issues/13): check",
            markdown,
        )
        self.assertIn(
            "## Threshold breaches\n\n"
            "- **ci**: Failure rate crossed the threshold\n"
            "- **throughput**: Planned work has no PR activity",
            markdown,
        )

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
        self.assertIn("## Awaiting release", result.stdout)
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

    def test_publish_digest_updates_the_one_existing_digest_without_retitling(self) -> None:
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
                "title": "Factory Digest",
                "url": "https://example.test/discussions/99",
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
        self.assertEqual(variables["input"], {"discussionId": "D_1", "body": "digest body"})
        self.assertNotIn("title", variables["input"])

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
                "body": "digest body",
            },
        )
        self.assertIn("pinDiscussion", calls[1][0])
        self.assertIn("warning: unable to pin Factory Digest", stderr.getvalue())

    def test_publish_digest_second_run_updates_the_single_created_discussion(self) -> None:
        repo = factory_digest.RepoInfo(
            owner="fairchild",
            name="workspaces",
            repository_id="R_1",
            category_ids={"general": "C_general"},
        )
        discussions: list[dict[str, object]] = []
        operations: list[str] = []

        def fake_graphql(token: str, query: str, variables: dict[str, object]):
            if "createDiscussion" in query:
                operations.append("create")
                self.assertEqual(variables["input"]["categoryId"], "C_general")
                discussion = {
                    "id": "D_1",
                    "number": 100,
                    "title": "Factory Digest",
                    "url": "https://example.test/discussions/100",
                }
                discussions.append(discussion)
                return {"data": {"createDiscussion": {"discussion": discussion}}}
            if "pinDiscussion" in query:
                operations.append("pin")
                return {"data": {"pinDiscussion": {"discussion": discussions[0]}}}
            operations.append("update")
            return {"data": {"updateDiscussion": {"discussion": discussions[0]}}}

        with mock.patch.object(factory_digest, "graphql", side_effect=fake_graphql):
            factory_digest.publish_digest(repo, discussions, "first body", "write-token")
            factory_digest.publish_digest(repo, discussions, "second body", "write-token")

        self.assertEqual(len(discussions), 1)
        self.assertEqual(operations, ["create", "pin", "update"])

    def test_publish_digest_does_not_downgrade_create_or_update_failures(self) -> None:
        repo = factory_digest.RepoInfo(
            owner="fairchild",
            name="workspaces",
            repository_id="R_1",
            category_ids={"general": "C_1"},
        )
        existing = [{"id": "D_1", "title": "Factory Digest"}]

        with mock.patch.object(
            factory_digest,
            "graphql",
            side_effect=factory_digest.FactoryDigestError("permission denied"),
        ):
            with self.assertRaisesRegex(factory_digest.FactoryDigestError, "permission denied"):
                factory_digest.publish_digest(repo, existing, "body", "write-token")
            with self.assertRaisesRegex(factory_digest.FactoryDigestError, "permission denied"):
                factory_digest.publish_digest(repo, [], "body", "write-token")

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
                                        "url": "https://example.test/discussions/1",
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

        with mock.patch.object(factory_digest, "graphql", side_effect=fake_graphql):
            inputs = factory_digest.fetch_live_inputs(
                "fairchild/workspaces", "read-token"
            )

        self.assertEqual([item["title"] for item in inputs.discussions], ["First", "Second"])
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
