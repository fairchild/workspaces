#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Contract tests for Agent Factory implementation and review workflows."""

from __future__ import annotations

import importlib.util
import json
import re
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
IMPLEMENT_SCRIPT = REPO_ROOT / "scripts" / "factory-implement.py"
IMPLEMENT_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "factory-implement.yml"
REVIEW_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "factory-review-execute.yml"
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
REPO_VARIABLES_MANIFEST = REPO_ROOT / "config" / "github" / "repo-variables.json"
FACTORY_ENABLED_VAR_DOT_REF = re.compile(r"vars\.(FACTORY_[A-Z0-9_]*_ENABLED)\b")
FACTORY_ENABLED_VAR_BRACKET_REF = re.compile(r"vars\[\s*['\"](FACTORY_[A-Z0-9_]*_ENABLED)['\"]\s*\]")


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def parse_jobs(text: str) -> dict[str, str]:
    """Split a workflow into per-job text blocks keyed by job name.

    Jobs are the 2-space-indented keys under the top-level ``jobs:`` mapping.
    Stdlib-only (no YAML dependency) — indentation is enough to isolate the
    text of each job for permission and env assertions.
    """
    jobs: dict[str, str] = {}
    in_jobs = False
    current: str | None = None
    buffer: list[str] = []
    for line in text.splitlines():
        if re.match(r"^jobs:\s*$", line):
            in_jobs = True
            continue
        if not in_jobs:
            continue
        if line.startswith("#"):  # a column-zero comment is not a section end
            continue
        if re.match(r"^\S", line):  # a new top-level key ends the jobs section
            break
        header = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if header:
            if current is not None:
                jobs[current] = "\n".join(buffer)
            current = header.group(1)
            buffer = [line]
        elif current is not None:
            buffer.append(line)
    if current is not None:
        jobs[current] = "\n".join(buffer)
    return jobs


def workflow_permissions_block(text: str) -> str:
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if re.match(r"^permissions:\s*$", line):
            block = [line]
            for follow in lines[i + 1 :]:
                if re.match(r"^\S", follow):
                    break
                block.append(follow)
            return "\n".join(block)
    return ""


def grants_contents_write(block: str) -> bool:
    """True when a `permissions:` entry grants GITHUB_TOKEN `contents: write`.

    Line-anchored so it does not match `permission-contents: write` — the input
    to actions/create-github-app-token, which mints a separately-scoped App
    installation token rather than widening the job's GITHUB_TOKEN. The scalar
    `permissions: write-all` form grants contents write too.
    """
    if re.search(r"(?m)^\s*permissions:\s*write-all\s*$", block) is not None:
        return True
    return re.search(r"(?m)^\s*contents:\s*write\s*$", block) is not None


factory_implement = load_module("factory_implement", IMPLEMENT_SCRIPT)
lifecycle_health = load_module(
    "lifecycle_health_check",
    REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "lifecycle-health-check.py",
)


class FactoryImplementTests(unittest.TestCase):
    # The default body carries a Requested Evidence contract because admission
    # now requires one (#1380): without it every claim path would decline
    # before reaching the condition under test.
    EVIDENCE_CONTRACT = "\n\n## Requested Evidence\n- `swift test` passes\n"

    def issue(
        self,
        *,
        title: str = "Implement a feature",
        body: str = "Change Sources/Feature.swift" + EVIDENCE_CONTRACT,
        labels: tuple[str, ...] = ("agent", "task", "ready"),
    ):
        return {
            "number": 42,
            "state": "open",
            "title": title,
            "body": body,
            "labels": [{"name": label} for label in labels],
            "assignees": [{"login": "fairchild"}],
        }

    def test_privileged_scope_matches_contributor_path_policy(self) -> None:
        privileged = (
            ".github/workflows/ci.yml",
            ".agents/memory/april/PROFILE.md",
            ".claude/settings.json",
            ".claude/skills/chat-sdk/SKILL.md",
            "Auth.swift",
            "scripts/notarize.sh",
            "scripts/generate-sparkle-appcast.sh",
            "scripts/install-local.sh",
            "scripts/prepare-prerelease.sh",
            "scripts/release-manifest.sh",
            "scripts/verify-installed-perf.sh",
            "scripts/verify-p12.sh",
            "scripts/verify-sparkle-appcast.swift",
            "WorkspaceManager.entitlements",
            "Config/AppKeychain.swift",
            "Config/SigningProfile.swift",
            "Sources/Auth/Session.swift",
            "infra/service/private-key.ts",
        )

        for path in privileged:
            with self.subTest(path=path):
                issue = self.issue(body=f"Change `{path}`")
                self.assertTrue(factory_implement.privileged_scope(issue))

        markdown_link = self.issue(
            body="Change [the CI workflow](.github/workflows/ci.yml)"
        )
        self.assertTrue(factory_implement.privileged_scope(markdown_link))
        self.assertTrue(
            factory_implement.privileged_scope(
                self.issue(title="Change scripts/release-manifest.sh", body="No paths here")
            )
        )

        self.assertFalse(
            factory_implement.privileged_scope(
                self.issue(body="Change `myclaude/config.json`")
            )
        )
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
        for conflicting in ("claimed", "review"):
            with self.subTest(conflicting=conflicting):
                self.assertEqual(
                    factory_implement.evaluate_claim(
                        self.issue(labels=("agent", "task", "ready", conflicting)),
                        0,
                    ).action,
                    "skip",
                )

        over_budget = factory_implement.evaluate_claim(
            self.issue(),
            0,
            daily_run_count=7,
            daily_cap=6,
        )
        self.assertEqual(over_budget.action, "budget")

    def test_missing_evidence_contract_is_declined_at_admission(self) -> None:
        # Before #1380 this issue was admitted, claimed, and burned a full
        # implement run before the contributor runtime refused it.
        self.assertEqual(
            factory_implement.evaluate_claim(
                self.issue(body="Change Sources/Feature.swift"), 0
            ).action,
            "no_evidence_contract",
        )
        # A section that exists but says "none" is not a contract either.
        self.assertEqual(
            factory_implement.evaluate_claim(
                self.issue(
                    body="Change Sources/Feature.swift\n\n## Requested Evidence\n- None\n"
                ),
                0,
            ).action,
            "no_evidence_contract",
        )
        # The contributor runtime's own fallback sentence is not a contract
        # either -- admission and the runtime read the same function, so the
        # two cannot drift into disagreeing about what counts.
        self.assertEqual(
            factory_implement.evaluate_claim(
                self.issue(
                    body="Change Sources/Feature.swift\n\n## Requested Evidence\n"
                    "- Follow the repo evidence bar for the touched surfaces.\n"
                ),
                0,
            ).action,
            "no_evidence_contract",
        )
        self.assertEqual(factory_implement.evaluate_claim(self.issue(), 0).action, "claim")
        # Privileged scope is still decided first: an issue that is both
        # privileged and contract-less reports the scope problem, which is the
        # one the owner has to act on.
        self.assertEqual(
            factory_implement.evaluate_claim(
                self.issue(body="Change `.github/workflows/ci.yml`"), 0
            ).action,
            "privileged",
        )

    def test_release_actor_must_own_trigger_and_latest_ready_event(self) -> None:
        events = [
            {
                "event": "labeled",
                "label": {"name": "ready"},
                "actor": {"login": "fairchild"},
            }
        ]

        self.assertEqual(
            factory_implement.verify_release_actor(events, "fairchild", "fairchild"),
            "fairchild",
        )
        with self.assertRaisesRegex(
            factory_implement.FactoryImplementError,
            "trigger actor",
        ):
            factory_implement.verify_release_actor(events, "collaborator", "fairchild")
        events.append(
            {
                "event": "labeled",
                "label": {"name": "ready"},
                "actor": {"login": "untrusted-app[bot]"},
            }
        )
        with self.assertRaisesRegex(
            factory_implement.FactoryImplementError,
            "most recent ready label actor",
        ):
            factory_implement.verify_release_actor(events, "fairchild", "fairchild")

    @staticmethod
    def ready_event(action: str, actor: str, created_at: str) -> dict[str, object]:
        return {
            "event": action,
            "label": {"name": "ready"},
            "actor": {"login": actor},
            "created_at": created_at,
        }

    def release_timeline(self, *steps: tuple[str, str]) -> list[dict[str, object]]:
        return [
            self.ready_event(action, actor, f"2026-08-27T0{index}:00:00Z")
            for index, (action, actor) in enumerate(steps, start=1)
        ]

    APRIL = "april-clearwater[bot]"

    def test_a_failed_run_restoring_ready_stays_admissible(self) -> None:
        # #1380: rollback re-applies `ready` as April after a failed run, so
        # the newest ready event on a retried issue is bot-attributed. Reading
        # only that event refused every later firing -- label events AND the
        # documented owner workflow_dispatch recovery -- until a human cycled
        # the label by hand.
        restored = self.release_timeline(
            ("labeled", "fairchild"),
            ("unlabeled", self.APRIL),
            ("labeled", self.APRIL),
        )
        for trigger in ("fairchild", "github-actions[bot]"):
            with self.subTest(trigger=trigger):
                self.assertEqual(
                    factory_implement.verify_release_actor(restored, trigger, "fairchild"),
                    "fairchild",
                )
        # Two failed runs in a row stay transparent.
        twice = restored + self.release_timeline(
            ("unlabeled", self.APRIL), ("labeled", self.APRIL)
        )[:2]
        self.assertIsNotNone(factory_implement.owner_release_event(twice, "fairchild"))
        # The boundary is the owner's release, not the restore: the content the
        # owner reviewed is the content as of their release.
        self.assertEqual(
            factory_implement.owner_release_event(restored, "fairchild"),
            restored[0],
        )

    def test_an_owner_revocation_ends_the_lineage(self) -> None:
        # Owner withdraws `ready` after the claim reads the issue; the run
        # fails and rollback restores it. That restore must not replay a
        # release the owner took back.
        revoked = self.release_timeline(
            ("labeled", "fairchild"),
            ("unlabeled", "fairchild"),
            ("labeled", self.APRIL),
        )
        self.assertIsNone(factory_implement.owner_release_event(revoked, "fairchild"))
        with self.assertRaisesRegex(
            factory_implement.FactoryImplementError, "most recent ready label actor"
        ):
            factory_implement.verify_release_actor(revoked, "fairchild", "fairchild")

    def test_a_factory_ready_is_only_a_restore_when_it_undoes_a_claim(self) -> None:
        # Identity is not provenance: the App token is held by several lanes,
        # so a factory-applied `ready` on an issue that was never claimed is
        # not a restore of anything.
        unpaired = self.release_timeline(
            ("labeled", "fairchild"), ("labeled", self.APRIL)
        )
        self.assertIsNone(factory_implement.owner_release_event(unpaired, "fairchild"))
        # ...and a restore with no owner release underneath it at all.
        orphan = self.release_timeline(
            ("unlabeled", self.APRIL), ("labeled", self.APRIL)
        )
        self.assertIsNone(factory_implement.owner_release_event(orphan, "fairchild"))

    def test_only_the_factory_app_identity_is_transparent(self) -> None:
        # Pinned deliberately. github-actions[bot] is shared by every workflow
        # in the repo, so widening this set would make any of them able to
        # revive an issue. The janitor's stale-claim restore posts under that
        # identity and is a known, documented gap (see the follow-up issue) --
        # not something to close by loosening this.
        self.assertEqual(
            factory_implement.FACTORY_LABEL_ACTORS, frozenset({self.APRIL})
        )
        for impostor in (
            "github-actions[bot]",
            "workspace-agents[bot]",
            "dependabot[bot]",
            "collaborator",
        ):
            with self.subTest(actor=impostor):
                self.assertIsNone(
                    factory_implement.owner_release_event(
                        self.release_timeline(
                            ("labeled", "fairchild"),
                            ("unlabeled", self.APRIL),
                            ("labeled", impostor),
                        ),
                        "fairchild",
                    )
                )

    def test_the_walk_orders_by_timestamp_not_by_list_position(self) -> None:
        # The timeline reads chronologically today, but GitHub documents no
        # sort guarantee and offset pagination is not a snapshot.
        shuffled = list(
            reversed(
                self.release_timeline(
                    ("labeled", "fairchild"),
                    ("unlabeled", self.APRIL),
                    ("labeled", self.APRIL),
                )
            )
        )
        release = factory_implement.owner_release_event(shuffled, "fairchild")
        assert release is not None
        self.assertEqual(release["created_at"], "2026-08-27T01:00:00Z")

    def test_a_collaborator_relabel_still_ends_the_walk(self) -> None:
        self.assertIsNone(
            factory_implement.owner_release_event(
                self.release_timeline(
                    ("labeled", "fairchild"), ("labeled", "collaborator")
                ),
                "fairchild",
            )
        )

    def test_non_owner_editor_is_flagged_owner_edits_are_not(self) -> None:
        # No edits at all.
        self.assertIsNone(factory_implement.latest_non_owner_editor([], "fairchild"))
        # The owner's own edit is trusted.
        self.assertIsNone(
            factory_implement.latest_non_owner_editor(
                [{"editor": {"login": "fairchild"}}], "fairchild"
            )
        )
        # A non-owner edit is the whole point of the check.
        self.assertEqual(
            factory_implement.latest_non_owner_editor(
                [{"editor": {"login": "contributor"}}], "fairchild"
            ),
            "contributor",
        )
        # The LATEST non-owner edit wins when there are several — `edits` is
        # newest-first (matching GitHubClient.user_content_edits_since), so
        # that's the FIRST non-owner match, not the last.
        self.assertEqual(
            factory_implement.latest_non_owner_editor(
                [
                    {"editor": {"login": "second-contributor"}},
                    {"editor": {"login": "fairchild"}},
                    {"editor": {"login": "first-contributor"}},
                ],
                "fairchild",
            ),
            "second-contributor",
        )
        # A deleted/anonymized editor can't be verified as the owner — fail closed.
        self.assertEqual(
            factory_implement.latest_non_owner_editor([{"editor": None}], "fairchild"),
            "an unidentified editor",
        )

    def test_user_content_edits_since_excludes_edits_strictly_before_the_boundary(
        self,
    ) -> None:
        client = factory_implement.GitHubClient("fairchild/workspaces", "token")
        # userContentEdits is newest-first (verified live against this repo's
        # own GraphQL API — the opposite of most GitHub connections).
        page = {
            "userContentEdits": {
                "pageInfo": {"hasNextPage": False, "endCursor": None},
                "nodes": [
                    {"editor": {"login": "fairchild"}, "editedAt": "2026-07-16T00:00:00Z"},
                    # Same second as `since`: must count as at-or-after, not before —
                    # GitHub timestamps are second-precision.
                    {"editor": {"login": "contributor"}, "editedAt": "2026-07-15T00:00:00Z"},
                    {"editor": {"login": "contributor"}, "editedAt": "2026-07-14T00:00:00Z"},
                ],
            }
        }
        with mock.patch.object(
            client, "graphql", return_value={"data": {"repository": {"issue": page}}}
        ):
            edits = client.user_content_edits_since(42, "2026-07-15T00:00:00Z")

        self.assertEqual(
            [edit["editedAt"] for edit in edits],
            ["2026-07-16T00:00:00Z", "2026-07-15T00:00:00Z"],
        )

    def test_user_content_edits_since_paginates_past_a_full_page_of_newer_edits(
        self,
    ) -> None:
        # A hostile edit sitting behind 50 even-newer (e.g. owner) edits must
        # not silently fall outside a single `first: 50` page.
        client = factory_implement.GitHubClient("fairchild/workspaces", "token")
        newest_page = {
            "pageInfo": {"hasNextPage": True, "endCursor": "cursor-1"},
            "nodes": [
                {"editor": {"login": "fairchild"}, "editedAt": f"2026-08-{i + 1:02d}T00:00:00Z"}
                for i in range(50)
            ],
        }
        older_page = {
            "pageInfo": {"hasNextPage": False, "endCursor": None},
            "nodes": [
                {"editor": {"login": "contributor"}, "editedAt": "2026-07-15T12:00:00Z"},
            ],
        }
        responses = [
            {"data": {"repository": {"issue": {"userContentEdits": newest_page}}}},
            {"data": {"repository": {"issue": {"userContentEdits": older_page}}}},
        ]
        with mock.patch.object(client, "graphql", side_effect=responses) as graphql:
            edits = client.user_content_edits_since(42, "2026-07-15T00:00:00Z")

        self.assertEqual(graphql.call_count, 2)
        self.assertEqual(graphql.call_args_list[1].args[1]["after"], "cursor-1")
        self.assertIn(
            {"editor": {"login": "contributor"}, "editedAt": "2026-07-15T12:00:00Z"},
            edits,
        )

    def test_user_content_edits_since_fails_closed_on_null_connection_or_nodes(
        self,
    ) -> None:
        client = factory_implement.GitHubClient("fairchild/workspaces", "token")
        # A null connection or null nodes list is not the same as a genuinely
        # empty history (which GitHub renders as nodes: []) — must raise, not
        # silently degrade to "no edits".
        for issue_payload in (
            {"userContentEdits": None},
            {"userContentEdits": {"nodes": None, "pageInfo": {}}},
        ):
            with self.subTest(issue_payload=issue_payload):
                with mock.patch.object(
                    client,
                    "graphql",
                    return_value={"data": {"repository": {"issue": issue_payload}}},
                ):
                    with self.assertRaisesRegex(
                        factory_implement.FactoryImplementError, "was null"
                    ):
                        client.user_content_edits_since(42, "2026-07-15T00:00:00Z")

    def test_daily_budget_counts_reruns_and_execution_rechecks_switches(self) -> None:
        runs = [
            {
                "id": 100,
                "event": "issues",
                "display_title": "Factory Implement ready #40",
                "run_attempt": 2,
                "actor": {"login": "fairchild"},
            },
            {
                "id": 101,
                "event": "workflow_dispatch",
                "run_attempt": 1,
                "actor": {"login": "fairchild"},
            },
            {
                "id": 99,
                "event": "issues",
                "display_title": "Factory Implement claimed #39",
                "run_attempt": 8,
                "actor": {"login": "fairchild"},
            },
            {
                # The Monitor sweep's own dispatch identity (#1148) — must
                # count toward budget just like an owner-triggered dispatch,
                # or the sweep could blow past the daily cap unnoticed.
                "id": 98,
                "event": "workflow_dispatch",
                "run_attempt": 9,
                "actor": {"login": "github-actions[bot]"},
            },
        ]
        self.assertEqual(
            factory_implement.count_daily_runs(
                runs,
                "101",
                repository_owner="fairchild",
            ),
            12,
        )
        self.assertEqual(
            factory_implement.count_daily_runs(
                runs,
                "102",
                3,
                "fairchild",
            ),
            15,
        )

        actions_client = mock.Mock()
        actions_client.workflow_runs_on.return_value = runs
        with self.assertRaisesRegex(
            factory_implement.FactoryImplementError,
            "disabled",
        ):
            factory_implement.authorize_execution(
                actions_client,
                daily_cap=6,
                current_run_id="102",
                current_run_attempt=3,
                global_switch="false",
                stage_switch="true",
                repository_owner="fairchild",
            )

        with self.assertRaisesRegex(
            factory_implement.FactoryImplementError,
            "16 run attempts",
        ):
            factory_implement.authorize_execution(
                actions_client,
                daily_cap=6,
                current_run_id="102",
                current_run_attempt=4,
                global_switch="true",
                stage_switch="true",
                repository_owner="fairchild",
            )

    def test_claim_and_rollback_payloads_preserve_unrelated_state(self) -> None:
        issue = self.issue(labels=("agent", "task", "ready", "quality"))

        claim = factory_implement.claim_payload(issue)
        self.assertEqual(claim["labels"], ["agent", "claimed", "quality", "task"])
        self.assertNotIn("assignees", claim)

        claimed_issue = {
            **issue,
            "labels": [{"name": name} for name in claim["labels"]],
        }
        rollback = factory_implement.rollback_payload(claimed_issue)
        self.assertEqual(rollback["labels"], ["agent", "quality", "ready", "task"])
        self.assertNotIn("assignees", rollback)

        decline = factory_implement.decline_payload(issue)
        self.assertEqual(decline["labels"], ["agent", "quality", "task"])
        self.assertNotIn("assignees", decline)

    def test_negative_outcomes_partition_terminal_and_transient(self) -> None:
        self.assertEqual(
            factory_implement.TERMINAL_DECLINES | factory_implement.TRANSIENT_DEFERRALS,
            {"privileged", "no_evidence_contract", "wip", "budget"},
        )
        self.assertEqual(
            set(factory_implement.TERMINAL_DECLINE_COMMENTS),
            set(factory_implement.TERMINAL_DECLINES),
            "every terminal decline needs a comment explaining what to fix",
        )
        self.assertEqual(
            factory_implement.TERMINAL_DECLINES & factory_implement.TRANSIENT_DEFERRALS,
            frozenset(),
        )

    def claim_client(self, issue) -> mock.Mock:
        client = mock.Mock()
        client.issue.return_value = issue
        client.timeline.return_value = [
            {
                "event": "labeled",
                "label": {"name": "ready"},
                "actor": {"login": "fairchild"},
                "created_at": "2026-07-15T00:00:00Z",
            }
        ]
        client.claimed_issues.return_value = []
        client.comments.return_value = []
        client.user_content_edits_since.return_value = []
        return client

    def run_claim(self, client, actions_client, *, daily_cap: int = 6) -> list[str]:
        outputs: list[str] = []
        with mock.patch.object(
            factory_implement,
            "write_output",
            lambda name, value: outputs.append(f"{name}={value}"),
        ):
            factory_implement.claim(
                client,
                actions_client,
                42,
                "https://example.test/runs/7",
                "april-clearwater[bot]",
                "fairchild",
                "fairchild",
                "true",
                "true",
                daily_cap,
                "7",
                1,
            )
        return outputs

    def test_privileged_decline_is_terminal_and_withdraws_ready(self) -> None:
        client = self.claim_client(
            self.issue(
                body="Change `.github/workflows/ci.yml`",
                labels=("agent", "task", "ready", "quality"),
            )
        )
        actions_client = mock.Mock()
        actions_client.workflow_runs_on.return_value = []

        outputs = self.run_claim(client, actions_client)

        client.comment.assert_called_once_with(
            42, factory_implement.PRIVILEGED_COMMENT
        )
        client.update_issue.assert_called_once_with(
            42, {"labels": ["agent", "quality", "task"]}
        )
        client.add_assignees.assert_not_called()
        self.assertIn("matched=false", outputs)
        self.assertNotIn("matched=true", outputs)

    def test_missing_evidence_contract_decline_is_terminal_and_withdraws_ready(
        self,
    ) -> None:
        client = self.claim_client(
            self.issue(
                body="Change Sources/Feature.swift",
                labels=("agent", "task", "ready", "quality"),
            )
        )
        actions_client = mock.Mock()
        actions_client.workflow_runs_on.return_value = []

        outputs = self.run_claim(client, actions_client)

        client.comment.assert_called_once_with(
            42, factory_implement.NO_EVIDENCE_CONTRACT_COMMENT
        )
        comment_body = client.comment.call_args.args[1]
        self.assertIn("## Requested Evidence", comment_body)
        client.update_issue.assert_called_once_with(
            42, {"labels": ["agent", "quality", "task"]}
        )
        client.add_assignees.assert_not_called()
        self.assertIn("matched=false", outputs)
        self.assertNotIn("matched=true", outputs)

    def test_claim_defers_and_never_touches_labels_when_content_edited_after_release(
        self,
    ) -> None:
        client = self.claim_client(self.issue())
        client.user_content_edits_since.return_value = [
            {"editor": {"login": "issue-author"}, "editedAt": "2026-07-16T00:00:00Z"}
        ]
        actions_client = mock.Mock()
        actions_client.workflow_runs_on.return_value = []

        outputs = self.run_claim(client, actions_client)

        client.comment.assert_called_once()
        comment_body = client.comment.call_args.args[1]
        self.assertIn("edited", comment_body)
        self.assertIn("@issue-author", comment_body)
        self.assertIn(factory_implement.STALE_SCOPE_COMMENT_MARKER, comment_body)
        client.update_issue.assert_not_called()
        client.add_assignees.assert_not_called()
        self.assertIn("matched=false", outputs)
        self.assertNotIn("matched=true", outputs)

    def test_transient_deferrals_leave_ready_for_retry(self) -> None:
        wip_client = self.claim_client(self.issue())
        wip_client.claimed_issues.return_value = [{"number": 1}, {"number": 2}]
        idle_actions = mock.Mock()
        idle_actions.workflow_runs_on.return_value = []

        self.run_claim(wip_client, idle_actions)

        wip_client.comment.assert_called_once_with(42, factory_implement.WIP_COMMENT)
        wip_client.update_issue.assert_not_called()

        budget_client = self.claim_client(self.issue())
        busy_actions = mock.Mock()
        busy_actions.workflow_runs_on.return_value = [
            {
                "id": run_id,
                "event": "workflow_dispatch",
                "run_attempt": 1,
                "actor": {"login": "fairchild"},
            }
            for run_id in range(100, 107)
        ]

        self.run_claim(budget_client, busy_actions)

        budget_client.comment.assert_called_once()
        self.assertIn(
            "leaving this issue ready", budget_client.comment.call_args.args[1]
        )
        budget_client.update_issue.assert_not_called()

    def test_admission_comments_speak_as_the_stage_not_a_persona(self) -> None:
        budget = factory_implement.budget_skip_comment(7, 6)

        for body in (
            factory_implement.PRIVILEGED_COMMENT,
            factory_implement.WIP_COMMENT,
            budget,
        ):
            with self.subTest(body=body):
                self.assertNotIn("April Clearwater", body)
                self.assertIn("Factory admission:", body)
        self.assertTrue(
            factory_implement.PRIVILEGED_COMMENT.startswith("Factory admission:")
        )
        self.assertTrue(factory_implement.WIP_COMMENT.startswith("Factory admission:"))

    def test_claim_survives_unsupported_agent_assignment(self) -> None:
        client = mock.Mock()
        client.issue.return_value = self.issue()
        client.timeline.return_value = [
            {
                "event": "labeled",
                "label": {"name": "ready"},
                "actor": {"login": "fairchild"},
                "created_at": "2026-07-15T00:00:00Z",
            }
        ]
        client.claimed_issues.return_value = []
        client.user_content_edits_since.return_value = []
        client.add_assignees.side_effect = factory_implement.FactoryImplementError(
            "GitHub API POST /assignees failed with HTTP 403: "
            "Assigning agents is not supported with GitHub App installation tokens."
        )
        actions_client = mock.Mock()
        actions_client.workflow_runs_on.return_value = []
        outputs: list[str] = []

        with mock.patch.object(
            factory_implement, "write_output", lambda name, value: outputs.append(f"{name}={value}")
        ):
            factory_implement.claim(
                client,
                actions_client,
                42,
                "https://example.test/runs/7",
                "april-clearwater[bot]",
                "fairchild",
                "fairchild",
                "true",
                "true",
                6,
                "7",
                1,
            )

        client.update_issue.assert_called_once_with(42, {"labels": mock.ANY})
        client.add_assignees.assert_called_once_with(42, ["april-clearwater[bot]"])
        self.assertIn("matched=true", outputs)

    def test_health_check_accepts_claim_comment_without_assignee(self) -> None:
        marker = factory_implement.claim_comment(
            {**self.issue(), "title": "Fix it"},
            "https://example.test/runs/7",
        )

        def health_issue(*, assignees=(), comments=()):
            return {
                "number": 42,
                "labels": {"nodes": [{"name": name} for name in ("agent", "task", "claimed")]},
                "assignees": {"nodes": [{"login": login} for login in assignees]},
                "comments": {"nodes": [{"body": body, "createdAt": "2026-07-15T00:00:00Z"} for body in comments]},
            }

        assigned = lifecycle_health.check_claim_assignment_consistency(
            [health_issue(assignees=["april-clearwater[bot]"])]
        )
        commented = lifecycle_health.check_claim_assignment_consistency(
            [health_issue(comments=[marker])]
        )
        orphaned = lifecycle_health.check_claim_assignment_consistency(
            [health_issue()]
        )

        self.assertTrue(assigned["pass"])
        self.assertTrue(commented["pass"])
        self.assertFalse(orphaned["pass"])

    def test_rollback_removes_assignee_best_effort(self) -> None:
        claim_body = factory_implement.claim_comment(
            self.issue(labels=("agent", "task", "claimed")),
            "https://example.test/runs/7",
        )
        client = mock.Mock()
        client.issue.return_value = self.issue(labels=("agent", "task", "claimed"))
        client.comments.return_value = [
            {"body": claim_body, "user": {"login": "april-clearwater[bot]"}}
        ]
        client.remove_assignees.side_effect = factory_implement.FactoryImplementError(
            "GitHub API DELETE /assignees failed with HTTP 403"
        )

        factory_implement.rollback(
            client,
            42,
            "https://example.test/runs/7",
            "april-clearwater[bot]",
        )

        client.update_issue.assert_called_once_with(42, {"labels": mock.ANY})
        client.remove_assignees.assert_called_once_with(42, ["april-clearwater[bot]"])
        client.comment.assert_called_once()

    def test_claim_comment_binds_runtime_identity_branch_and_run(self) -> None:
        issue = {**self.issue(), "title": "Fix a subtle bug"}

        body = factory_implement.claim_comment(issue, "https://example.test/runs/7")

        self.assertIn("Workflow run: https://example.test/runs/7", body)
        self.assertIn("agent=april-clearwater", body)
        self.assertIn("branch=codex/april-clearwater-issue-42-fix-a-subtle-bug", body)
        self.assertEqual(
            factory_implement.latest_factory_claim_run(
                [
                    {"body": body, "user": {"login": "april-clearwater[bot]"}},
                    {
                        "body": body.replace("runs/7", "runs/forged"),
                        "user": {"login": "attacker"},
                    },
                ],
                "april-clearwater[bot]",
            ),
            "https://example.test/runs/7",
        )

    def test_claim_comments_before_mutating_labels(self) -> None:
        client = mock.Mock()
        client.issue.return_value = self.issue()
        client.timeline.return_value = [
            {
                "event": "labeled",
                "label": {"name": "ready"},
                "actor": {"login": "fairchild"},
                "created_at": "2026-07-15T00:00:00Z",
            }
        ]
        client.claimed_issues.return_value = []
        client.user_content_edits_since.return_value = []
        actions_client = mock.Mock()
        actions_client.workflow_runs_on.return_value = []

        factory_implement.claim(
            client,
            actions_client,
            42,
            "https://example.test/runs/7",
            "april-clearwater[bot]",
            "fairchild",
            "fairchild",
            "true",
            "true",
            6,
            "7",
            1,
        )

        self.assertEqual(
            [call[0] for call in client.method_calls if call[0] in {"comment", "update_issue"}],
            ["comment", "update_issue"],
        )

    def test_budget_skip_comment_dedupes_across_changing_run_counts(self) -> None:
        first = factory_implement.budget_skip_comment(7, 6)
        second = factory_implement.budget_skip_comment(8, 6)
        client = mock.Mock()
        client.comments.return_value = [{"body": first}]

        factory_implement.comment_once(
            client,
            42,
            second,
            dedupe_key=factory_implement.BUDGET_COMMENT_MARKER,
        )

        self.assertIn("7 implementation runs", first)
        self.assertIn("8 implementation runs", second)
        self.assertTrue(
            first.startswith(factory_implement.BUDGET_COMMENT_MARKER + "\n")
        )
        client.comment.assert_not_called()

    def test_stale_scope_comment_dedup_is_scoped_per_release_cycle(self) -> None:
        first_cycle = factory_implement.stale_scope_comment(
            "contributor", "2026-07-15T00:00:00Z"
        )
        second_cycle = factory_implement.stale_scope_comment(
            "contributor", "2026-07-20T00:00:00Z"
        )
        client = mock.Mock()
        client.comments.return_value = [{"body": first_cycle}]

        # A hostile edit against the OLD release cycle is correctly suppressed...
        factory_implement.comment_once(
            client,
            42,
            first_cycle,
            dedupe_key=factory_implement.stale_scope_marker("2026-07-15T00:00:00Z"),
        )
        client.comment.assert_not_called()

        # ...but a hostile edit against a NEW release cycle (the owner
        # re-reviewed and re-applied ready since) must still get its own
        # warning, not be silently swallowed by the earlier marker.
        factory_implement.comment_once(
            client,
            42,
            second_cycle,
            dedupe_key=factory_implement.stale_scope_marker("2026-07-20T00:00:00Z"),
        )
        client.comment.assert_called_once_with(42, second_cycle)

    def test_workflow_contract_is_event_gated_and_uses_april_identity(self) -> None:
        workflow = IMPLEMENT_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("issues:\n    types: [labeled]", workflow)
        self.assertIn("github.event.sender.login == github.repository_owner", workflow)
        self.assertIn("github.actor == github.repository_owner", workflow)
        # The Monitor sweep's own workflow_dispatch identity (#1148) — trusted
        # to *trigger* a claim attempt, never to grant admission itself; see
        # verify_release_actor for the actual (unchanged) owner-only gate.
        self.assertIn("github.actor == 'github-actions[bot]'", workflow)
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
        self.assertIn("FACTORY_EXPECTED_ISSUE_SCOPE_DIGEST", workflow)
        self.assertIn("VERIFIED_ACTOR: ${{ needs.claim.outputs.verified_actor }}", workflow)
        self.assertIn("@${VERIFIED_ACTOR} mentioned you in issue #${ISSUE_NUMBER}", workflow)
        self.assertNotIn("@${GITHUB_REPOSITORY_OWNER} mentioned you", workflow)
        self.assertIn("factory-implement.py authorize", workflow)
        self.assertIn('FACTORY_REQUIRE_EXPLICIT_EVIDENCE: "true"', workflow)
        self.assertIn("permission-contents: write", workflow)
        self.assertIn("permission-pull-requests: write", workflow)
        self.assertIn("scripts/factory-implement.py rollback", workflow)
        self.assertIn("needs.claim.result == 'failure'", workflow)
        self.assertIn("needs.claim.result == 'cancelled'", workflow)
        self.assertIn('FACTORY_VISUAL_EVIDENCE_AVAILABLE: "false"', workflow)
        self.assertIn("uses: ./.github/workflows/_evidence.yml", workflow)
        self.assertIn("upload_text_evidence: true", workflow)
        self.assertIn("needs_screenshot_evidence: false", workflow)
        self.assertIn("secrets.EVIDENCE_UPLOAD_TOKEN", workflow)
        self.assertIn("pr_number: ${{ needs.implement.outputs.pr_number }}", workflow)
        self.assertIn("pr_head_sha: ${{ needs.implement.outputs.pr_head_sha }}", workflow)

        evidence_workflow = (
            REPO_ROOT / ".github" / "workflows" / "_evidence.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("ref: ${{ inputs.pr_head_sha || inputs.pr_branch }}", evidence_workflow)
        self.assertIn('EXPECTED_HEAD_SHA: ${{ inputs.pr_head_sha }}', evidence_workflow)
        self.assertIn("headRefOid", evidence_workflow)
        self.assertIn("Evidence identity is not SHA-bound", evidence_workflow)
        self.assertIn("--add-label blocked:evidence", evidence_workflow)

        monitor = (
            REPO_ROOT / ".github" / "workflows" / "factory-monitor.yml"
        ).read_text(encoding="utf-8")
        # write, not read: the standing-queue sweep dispatches
        # factory-implement.yml through the Actions API (#1148).
        self.assertIn("actions: write", monitor)
        self.assertNotIn("actions: read", monitor)
        self.assertIn("scripts/factory-sweep.py", monitor)
        sweep_gate = monitor.split("- name: Sweep standing ready queue", 1)[1].split(
            "shell: bash", 1
        )[0]
        self.assertIn("vars.AGENT_AUTOMATIONS_ENABLED == 'true'", sweep_gate)
        self.assertIn("vars.FACTORY_IMPLEMENT_ENABLED == 'true'", sweep_gate)
        # Manual Monitor runs are open to any write-capable collaborator, and
        # this step is the one that spends FACTORY_IMPLEMENT_DAILY_CAP.
        self.assertIn("github.actor == github.repository_owner", sweep_gate)
        # Pinned regression guard: the level-triggered sweep this issue adds
        # is a properly re-authenticated design (owner-only admission is
        # re-verified independently in verify_release_actor), not a revival
        # of the unauthenticated re-fire lane retired in #1096.
        self.assertNotIn("Re-fire ready implementation work", monitor)

    def test_sweep_trigger_actor_is_trusted_but_never_grants_admission(self) -> None:
        owner_ready_events = [
            {
                "event": "labeled",
                "label": {"name": "ready"},
                "actor": {"login": "fairchild"},
            }
        ]

        self.assertEqual(
            factory_implement.verify_release_actor(
                owner_ready_events, "github-actions[bot]", "fairchild"
            ),
            "fairchild",
        )
        with self.assertRaisesRegex(
            factory_implement.FactoryImplementError,
            "trigger actor",
        ):
            factory_implement.verify_release_actor(
                owner_ready_events, "some-other-app[bot]", "fairchild"
            )

        collaborator_ready_events = [
            {
                "event": "labeled",
                "label": {"name": "ready"},
                "actor": {"login": "collaborator"},
            }
        ]
        with self.assertRaisesRegex(
            factory_implement.FactoryImplementError,
            "most recent ready label actor",
        ):
            factory_implement.verify_release_actor(
                collaborator_ready_events, "github-actions[bot]", "fairchild"
            )

    def test_user_content_edits_since_parses_a_single_page_response(self) -> None:
        client = factory_implement.GitHubClient("fairchild/workspaces", "token")
        with mock.patch.object(
            client,
            "graphql",
            return_value={
                "data": {
                    "repository": {
                        "issue": {
                            "userContentEdits": {
                                "pageInfo": {"hasNextPage": False, "endCursor": None},
                                "nodes": [
                                    {
                                        "editor": {"login": "fairchild"},
                                        "editedAt": "2026-07-16T00:00:00Z",
                                    }
                                ],
                            }
                        }
                    }
                }
            },
        ) as graphql:
            edits = client.user_content_edits_since(42, "2026-07-15T00:00:00Z")

        self.assertEqual(
            edits, [{"editor": {"login": "fairchild"}, "editedAt": "2026-07-16T00:00:00Z"}]
        )
        variables = graphql.call_args.args[1]
        self.assertEqual(
            variables,
            {"owner": "fairchild", "name": "workspaces", "number": 42, "after": None},
        )

    def test_user_content_edits_since_fails_closed_on_a_missing_issue_or_repository(
        self,
    ) -> None:
        client = factory_implement.GitHubClient("fairchild/workspaces", "token")
        with mock.patch.object(
            client, "graphql", return_value={"data": {"repository": {"issue": None}}}
        ):
            with self.assertRaisesRegex(
                factory_implement.FactoryImplementError, "was not found"
            ):
                client.user_content_edits_since(42, "2026-07-15T00:00:00Z")
        with mock.patch.object(
            client, "graphql", return_value={"data": {"repository": None}}
        ):
            with self.assertRaisesRegex(
                factory_implement.FactoryImplementError, "was not found"
            ):
                client.user_content_edits_since(42, "2026-07-15T00:00:00Z")

    def test_daily_budget_counts_sweep_dispatches_alongside_owner_dispatches(self) -> None:
        self.assertTrue(
            factory_implement.is_factory_implement_dispatch(
                {"event": "workflow_dispatch", "actor": {"login": "github-actions[bot]"}},
                "fairchild",
            )
        )
        self.assertFalse(
            factory_implement.is_factory_implement_dispatch(
                {"event": "workflow_dispatch", "actor": {"login": "some-other-app[bot]"}},
                "fairchild",
            )
        )


class FactoryTelemetryContractTests(unittest.TestCase):
    def test_implement_lane_keeps_model_job_readonly_and_grants_telemetry_write(self) -> None:
        text = IMPLEMENT_WORKFLOW.read_text(encoding="utf-8")
        self.assertFalse(grants_contents_write(workflow_permissions_block(text)))
        jobs = parse_jobs(text)

        self.assertIn("implement", jobs)
        self.assertFalse(grants_contents_write(jobs["implement"]))
        self.assertIn("FACTORY_TELEMETRY_DIR:", jobs["implement"])
        self.assertIn("FACTORY_TELEMETRY_LANE: implement", jobs["implement"])
        self.assertIn("factory-implement-telemetry", jobs["implement"])

        self.assertIn("telemetry", jobs)
        self.assertTrue(grants_contents_write(jobs["telemetry"]))
        self.assertIn("actions: read", jobs["telemetry"])
        self.assertIn("scripts/factory-cost-append.py", jobs["telemetry"])

    def test_review_lane_keeps_reviewer_jobs_readonly_and_grants_telemetry_write(self) -> None:
        text = REVIEW_WORKFLOW.read_text(encoding="utf-8")
        self.assertFalse(grants_contents_write(workflow_permissions_block(text)))
        jobs = parse_jobs(text)

        for reviewer, label in (("april", "april"), ("plat", "plat")):
            self.assertIn(reviewer, jobs)
            self.assertFalse(grants_contents_write(jobs[reviewer]))
            self.assertIn("FACTORY_TELEMETRY_DIR:", jobs[reviewer])
            self.assertIn("FACTORY_TELEMETRY_LANE: review", jobs[reviewer])
            self.assertIn(f"FACTORY_TELEMETRY_REVIEWER: {label}", jobs[reviewer])
            self.assertIn(f"factory-review-telemetry-{label}", jobs[reviewer])

        self.assertIn("telemetry", jobs)
        self.assertTrue(grants_contents_write(jobs["telemetry"]))
        self.assertIn("actions: read", jobs["telemetry"])
        self.assertIn("needs: [admit, april, plat]", jobs["telemetry"])
        self.assertIn("scripts/factory-cost-append.py", jobs["telemetry"])


def referenced_factory_enabled_vars() -> set[str]:
    """Every vars.FACTORY_*_ENABLED name gated on by any workflow file.

    Covers both accessor styles (`vars.NAME` and `vars['NAME']`/`vars["NAME"]`)
    across both workflow extensions GitHub Actions recognizes."""
    names: set[str] = set()
    paths = sorted(WORKFLOWS_DIR.glob("*.yml")) + sorted(WORKFLOWS_DIR.glob("*.yaml"))
    for path in paths:
        text = path.read_text(encoding="utf-8")
        names.update(FACTORY_ENABLED_VAR_DOT_REF.findall(text))
        names.update(FACTORY_ENABLED_VAR_BRACKET_REF.findall(text))
    return names


class RepoVariableContractTests(unittest.TestCase):
    """A workflow gate on an unset repo variable ships green and never runs
    (#1149: factory-evidence-verify.yml gated on FACTORY_EVIDENCE_VERIFY_ENABLED
    for two PRs before anyone noticed the variable didn't exist). This is the
    local-files half of the contract — no network, so it runs unattended in
    ci-agents.yml on any workflow-file change. The other half (does the
    manifest name actually exist as a live repo variable) is
    `.github/workflows/repo-variables-drift.yml` + `scripts/check-repo-variables.py`,
    which also runs unattended (via the `vars` context, not a `gh` call — see
    config/github/README.md)."""

    def test_every_referenced_factory_enabled_var_has_a_manifest_entry(self) -> None:
        referenced = referenced_factory_enabled_vars()
        self.assertTrue(referenced, "expected at least one vars.FACTORY_*_ENABLED reference under .github/workflows/")

        manifest = json.loads(REPO_VARIABLES_MANIFEST.read_text(encoding="utf-8"))
        missing = sorted(referenced - set(manifest.keys()))
        self.assertEqual(
            missing,
            [],
            f"vars.FACTORY_*_ENABLED referenced in a workflow with no entry in "
            f"{REPO_VARIABLES_MANIFEST.relative_to(REPO_ROOT)} (gate can never fire "
            f"since nobody is prompted to `gh variable set`): {missing}",
        )


PERMISSION_LEVELS = {"none": 0, "read": 1, "write": 2}


PERMISSION_ENTRY_RE = re.compile(
    r"""^['"]?([a-z-]+)['"]?\s*:\s*['"]?(none|read|write)['"]?\s*(?:#.*)?$"""
)
# `./` and `$/` are both documented same-repository `uses:` forms ($/ is the
# recommended one); quotes and trailing comments are legal spellings.
REUSABLE_USES_RE = re.compile(
    r"""(?m)^\s*uses:\s*['"]?(?:\.|\$)/\.github/workflows/([\w.-]+)['"]?\s*(?:#.*)?$"""
)


def parse_permissions(text: str, key_indent: str) -> dict[str, str] | None:
    """Parse the `permissions:` mapping declared at ``key_indent``, or None.

    Returns ``{"*": "read"|"write"}`` for the scalar ``read-all``/``write-all``
    forms and ``{}`` for ``permissions: {}``, which zeroes every scope. Any
    scope missing from an explicit mapping is `none` — that replacement
    semantic is why a narrow block on a reusable-call job matters (#1446).
    Handles block and flow mappings, quoted keys/values, and trailing
    comments; raises ValueError on any `permissions:` form it cannot
    classify — a gate that guessed here would pass real mismatches silently.
    """
    lines = text.splitlines()
    for i, line in enumerate(lines):
        header = re.match(rf"^{key_indent}permissions:(?P<rest>.*)$", line)
        if not header:
            continue
        rest = header.group("rest").strip()
        if rest.startswith("#"):
            rest = ""
        else:
            rest = re.sub(r"\s+#.*$", "", rest).strip()
        if rest:
            scalar = rest.strip("'\"")
            if scalar == "read-all":
                return {"*": "read"}
            if scalar == "write-all":
                return {"*": "write"}
            flow = re.match(r"^\{(.*)\}$", rest)
            if flow is None:
                raise ValueError(f"unsupported permissions form: {line.strip()!r}")
            grants: dict[str, str] = {}
            body = flow.group(1).strip()
            for pair in filter(None, (p.strip() for p in body.split(","))):
                entry = PERMISSION_ENTRY_RE.match(pair)
                if entry is None:
                    raise ValueError(f"unsupported permissions flow entry: {pair!r}")
                grants[entry.group(1)] = entry.group(2)
            return grants
        grants = {}
        for follow in lines[i + 1 :]:
            if not follow.strip() or follow.lstrip().startswith("#"):
                continue
            if not re.match(rf"^{key_indent}\s+\S", follow):
                break  # dedented: the mapping ended
            entry = PERMISSION_ENTRY_RE.match(follow.strip())
            if entry is None:
                raise ValueError(f"unsupported permissions entry: {follow.strip()!r}")
            grants[entry.group(1)] = entry.group(2)
        return grants
    return None


def effective_level(grant: dict[str, str], scope: str) -> str:
    return grant.get("*", grant.get(scope, "none"))


def declared_permissions(callee_text: str) -> dict[str, str]:
    """The strongest level a called workflow declares per scope, at workflow or
    job level — the set its caller's grant must cover."""
    required: dict[str, str] = {}
    blocks = [parse_permissions(callee_text, "")]
    blocks.extend(parse_permissions(job_text, "    ") for job_text in parse_jobs(callee_text).values())
    for block in blocks:
        for scope, level in (block or {}).items():
            if PERMISSION_LEVELS[level] > PERMISSION_LEVELS[required.get(scope, "none")]:
                required[scope] = level
    return required


def local_reusable_call_sites() -> list[tuple[Path, str, str]]:
    """(caller path, job name, callee filename) for every same-repo call."""
    sites: list[tuple[Path, str, str]] = []
    for path in sorted(WORKFLOWS_DIR.glob("*.yml")) + sorted(WORKFLOWS_DIR.glob("*.yaml")):
        for job_name, job_text in parse_jobs(path.read_text(encoding="utf-8")).items():
            uses = REUSABLE_USES_RE.search(job_text)
            if uses:
                sites.append((path, job_name, uses.group(1)))
    return sites


class ParsePermissionsTests(unittest.TestCase):
    """Fixtures from the codex review of this gate: presentation-equivalent
    YAML forms must parse identically, and any `permissions:` form the parser
    cannot classify must raise instead of silently weakening the contract."""

    def test_flow_mapping(self) -> None:
        self.assertEqual(
            parse_permissions("permissions: {contents: read, issues: write}", ""),
            {"contents": "read", "issues": "write"},
        )

    def test_empty_flow_mapping_zeroes_every_scope(self) -> None:
        self.assertEqual(parse_permissions("permissions: {}", ""), {})

    def test_quoted_scalar_and_quoted_entries(self) -> None:
        self.assertEqual(parse_permissions('permissions: "write-all"', ""), {"*": "write"})
        self.assertEqual(parse_permissions('permissions:\n  "issues": "write"', ""), {"issues": "write"})

    def test_header_trailing_comment_then_block(self) -> None:
        self.assertEqual(
            parse_permissions("permissions: # the floor\n  contents: read", ""),
            {"contents": "read"},
        )

    def test_wider_entry_indent(self) -> None:
        self.assertEqual(parse_permissions("permissions:\n    contents: read", ""), {"contents": "read"})

    def test_unsupported_form_raises(self) -> None:
        with self.assertRaises(ValueError):
            parse_permissions("permissions: write", "")
        with self.assertRaises(ValueError):
            parse_permissions("permissions:\n  contents: admin", "")

    def test_callee_write_all_survives_as_a_requirement(self) -> None:
        # A callee declaring write-all requires a caller wildcard of the same
        # level; an explicit caller mapping cannot satisfy it (conservative:
        # GitHub compares scope by scope, but listing every scope at write is
        # not a shape this repo writes).
        self.assertEqual(declared_permissions("permissions: write-all\njobs:\n"), {"*": "write"})

    def test_job_level_flow_mapping_overrides_workflow_level(self) -> None:
        workflow = (
            "permissions: write-all\n"
            "jobs:\n"
            "  call:\n"
            "    permissions: {contents: read}\n"
            "    uses: ./.github/workflows/_evidence.yml\n"
        )
        self.assertEqual(parse_permissions(parse_jobs(workflow)["call"], "    "), {"contents": "read"})

    def test_call_site_discovery_accepts_quoted_and_dollar_forms(self) -> None:
        for spelling in (
            'uses: "./.github/workflows/_evidence.yml"',
            "uses: ./.github/workflows/_evidence.yml # evidence",
            "uses: $/.github/workflows/_evidence.yml",
        ):
            with self.subTest(spelling=spelling):
                match = REUSABLE_USES_RE.search(f"  call:\n    {spelling}\n")
                self.assertIsNotNone(match)
                self.assertEqual(match.group(1), "_evidence.yml")


class EvidenceReconcileContractTests(unittest.TestCase):
    """The reconcile job hands the macOS lane the contract the gate reads.

    `reconcile_pending_ci_evidence` is the one caller that reads an
    `## Evidence Status` line without the requested-evidence contract, so it
    has to guess where an item ends and the guess decides which lane owns the
    item (#1551). The job already holds the PR number and a token with issue
    read access, so this is plumbing rather than new capability -- and it is
    plumbing a static check can hold in place."""

    EVIDENCE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "_evidence.yml"

    def reconcile_step(self) -> str:
        workflow = self.EVIDENCE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("- name: Reconcile pending-ci evidence", workflow)
        step = workflow.split("- name: Reconcile pending-ci evidence", 1)[1]
        return step.split("\n      - name: ", 1)[0]

    def test_the_reconcile_step_reads_the_linked_issue_contract(self) -> None:
        step = self.reconcile_step()
        self.assertIn("closingIssuesReferences", step)
        self.assertIn("gh issue view \"$ISSUE_NUMBER\" --json body", step)
        self.assertIn("extract_requested_evidence", step)
        self.assertIn("requested_evidence=module.extract_requested_evidence(", step)

    def test_more_than_one_linked_issue_yields_no_contract(self) -> None:
        # Two contracts cannot both be this PR's, and anchoring on the wrong
        # one would resolve a line the other lane owns. The `length == 1`
        # form is the same one the PR-number resolution step uses.
        step = self.reconcile_step()
        self.assertIn(
            "if (.closingIssuesReferences | length) == 1 "
            "then .closingIssuesReferences[0].number else empty end",
            step,
        )
        self.assertIn("Evidence reconcile has no contract", step)

    def test_a_missing_contract_leaves_an_empty_file_rather_than_no_file(self) -> None:
        # The python heredoc reads `issue-body.md` unconditionally, so the
        # step truncates it first: a stale file from a previous run in the
        # same workspace would otherwise be read as this PR's contract.
        step = self.reconcile_step()
        self.assertIn(": > issue-body.md", step)
        self.assertLess(step.index(": > issue-body.md"), step.index("gh issue view"))

    def test_the_reconcile_job_can_read_the_issue_it_resolves(self) -> None:
        # The grant predates #1551 -- the job already wrote issue labels. It
        # is pinned here because the reconcile step now depends on it for a
        # read, and dropping it would fail at run time rather than at lint.
        workflow = self.EVIDENCE_WORKFLOW.read_text(encoding="utf-8")
        reconcile_job = parse_jobs(workflow)["reconcile"]
        self.assertIn("permission-issues: write", reconcile_job)


class ReusableWorkflowPermissionTests(unittest.TestCase):
    """A job calling a local reusable workflow must hold every permission the
    callee declares. GitHub validates that at run creation: a shortfall fails
    the whole run as `startup_failure` with zero jobs, before any `if:` or
    kill switch is evaluated, and actionlint does not check it (#1446:
    factory-revise.yml shipped with a `contents: read` floor and no job-level
    grant on its `_evidence.yml` call site, and every run the lane ever had
    died at startup with nothing posted anywhere). This is the local gate for
    that class of failure."""

    def test_every_local_reusable_call_site_grants_what_the_callee_declares(self) -> None:
        sites = local_reusable_call_sites()
        self.assertTrue(sites, "expected at least one local reusable-workflow call site under .github/workflows/")
        failures: list[str] = []
        for caller, job_name, callee_name in sites:
            caller_text = caller.read_text(encoding="utf-8")
            callee_path = WORKFLOWS_DIR / callee_name
            self.assertTrue(callee_path.is_file(), f"{caller.name} job '{job_name}' calls missing {callee_name}")
            required = declared_permissions(callee_path.read_text(encoding="utf-8"))
            grant = parse_permissions(parse_jobs(caller_text)[job_name], "    ")
            if grant is None:
                grant = parse_permissions(caller_text, "")
            if grant is None:
                # The inherited repository default is invisible to a static
                # check, so an unknowable grant fails closed instead of
                # skipping (codex review finding).
                failures.append(
                    f"{caller.name} job '{job_name}' calls {callee_name} with no explicit "
                    f"permissions at job or workflow level — declare the grant so this "
                    f"contract stays checkable"
                )
                continue
            for scope, level in sorted(required.items()):
                held = grant.get("*", "none") if scope == "*" else effective_level(grant, scope)
                if PERMISSION_LEVELS[held] < PERMISSION_LEVELS[level]:
                    failures.append(
                        f"{caller.name} job '{job_name}' holds {scope}: {held} but "
                        f"{callee_name} declares {scope}: {level} — the run would die at startup"
                    )
        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
