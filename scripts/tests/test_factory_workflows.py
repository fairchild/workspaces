#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Contract tests for Agent Factory implementation and review workflows."""

from __future__ import annotations

import importlib.util
import re
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
IMPLEMENT_SCRIPT = REPO_ROOT / "scripts" / "factory-implement.py"
IMPLEMENT_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "factory-implement.yml"
REVIEW_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "factory-review-execute.yml"


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
    installation token rather than widening the job's GITHUB_TOKEN.
    """
    return re.search(r"(?m)^\s*contents:\s*write\s*$", block) is not None


factory_implement = load_module("factory_implement", IMPLEMENT_SCRIPT)
lifecycle_health = load_module(
    "lifecycle_health_check",
    REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "lifecycle-health-check.py",
)


class FactoryImplementTests(unittest.TestCase):
    def issue(
        self,
        *,
        title: str = "Implement a feature",
        body: str = "Change Sources/Feature.swift",
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
            3,
        )
        self.assertEqual(
            factory_implement.count_daily_runs(
                runs,
                "102",
                3,
                "fairchild",
            ),
            6,
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
            "7 run attempts",
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
            {"privileged", "wip", "budget"},
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
            }
        ]
        client.claimed_issues.return_value = []
        client.comments.return_value = []
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
            }
        ]
        client.claimed_issues.return_value = []
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
            }
        ]
        client.claimed_issues.return_value = []
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

    def test_workflow_contract_is_event_gated_and_uses_april_identity(self) -> None:
        workflow = IMPLEMENT_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("issues:\n    types: [labeled]", workflow)
        self.assertIn("github.event.sender.login == github.repository_owner", workflow)
        self.assertIn("github.actor == github.repository_owner", workflow)
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
        self.assertIn("actions: read", monitor)
        self.assertNotIn("Re-fire ready implementation work", monitor)


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


if __name__ == "__main__":
    unittest.main()
