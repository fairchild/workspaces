#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fixture and contract tests for the standing-ready-queue sweep (#1148).

Intent: prove the sweep dispatches the oldest eligible issues, respects
remaining daily-cap headroom, and never touches issue labels or comments
itself — admission stays owner-only via factory-implement.py's own gate.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-sweep.py"
FIXTURES_DIR = REPO_ROOT / "fixtures" / "factory-sweep"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


factory_sweep = load_module("factory_sweep", SCRIPT_PATH)


def cross_reference(number: int, *, is_pull: bool, state: str) -> dict[str, object]:
    source_issue: dict[str, object] = {"number": number, "state": state}
    if is_pull:
        source_issue["pull_request"] = {"url": f"https://example.test/pulls/{number}"}
    return {"event": "cross-referenced", "source": {"type": "issue", "issue": source_issue}}


class HasOpenLinkedPullTests(unittest.TestCase):
    def client(self, timeline: list[dict[str, object]]) -> factory_sweep.GitHubClient:
        client = factory_sweep.GitHubClient("fairchild/workspaces", "token")
        client.timeline = mock.Mock(return_value=timeline)  # type: ignore[method-assign]
        return client

    def test_true_only_for_an_open_pull_cross_reference(self) -> None:
        self.assertTrue(
            self.client(
                [cross_reference(900, is_pull=True, state="open")]
            ).has_open_linked_pull(42)
        )

    def test_false_when_the_only_cross_reference_pull_is_closed(self) -> None:
        self.assertFalse(
            self.client(
                [cross_reference(900, is_pull=True, state="closed")]
            ).has_open_linked_pull(42)
        )

    def test_false_when_the_cross_reference_is_an_issue_not_a_pull(self) -> None:
        self.assertFalse(
            self.client(
                [cross_reference(900, is_pull=False, state="open")]
            ).has_open_linked_pull(42)
        )

    def test_false_with_no_cross_references_at_all(self) -> None:
        self.assertFalse(self.client([{"event": "labeled"}]).has_open_linked_pull(42))


def ready_event(actor: str) -> dict[str, object]:
    return {
        "event": "labeled",
        "label": {"name": "ready"},
        "actor": {"login": actor},
        "created_at": "2026-07-15T00:00:00Z",
    }


class EligibleIssueNumbersTests(unittest.TestCase):
    def client_with_no_edits(self) -> factory_sweep.GitHubClient:
        client = factory_sweep.GitHubClient("fairchild/workspaces", "token")
        client.user_content_edits_since = lambda number, since: []  # type: ignore[method-assign]
        return client

    def test_filters_out_issues_with_an_open_linked_pull_and_preserves_order(self) -> None:
        client = self.client_with_no_edits()
        client.timeline = lambda number: [ready_event("fairchild")]  # type: ignore[method-assign]
        client.has_open_linked_pull = lambda number, events=None: number == 502  # type: ignore[method-assign]
        issues = [{"number": 501}, {"number": 502}, {"number": 503}]

        self.assertEqual(
            factory_sweep.eligible_issue_numbers(client, "fairchild", candidates=issues),
            [501, 503],
        )

    def test_filters_out_issues_whose_latest_ready_actor_is_not_the_owner(self) -> None:
        client = self.client_with_no_edits()
        timelines = {
            501: [ready_event("fairchild")],
            502: [ready_event("collaborator")],
            503: [],
        }
        client.timeline = lambda number: timelines[number]  # type: ignore[method-assign]
        client.has_open_linked_pull = lambda number, events=None: False  # type: ignore[method-assign]
        issues = [{"number": 501}, {"number": 502}, {"number": 503}]

        self.assertEqual(
            factory_sweep.eligible_issue_numbers(client, "fairchild", candidates=issues),
            [501],
        )

    def test_filters_out_issues_edited_by_a_non_owner_after_release(self) -> None:
        client = factory_sweep.GitHubClient("fairchild/workspaces", "token")
        client.timeline = lambda number: [ready_event("fairchild")]  # type: ignore[method-assign]
        client.has_open_linked_pull = lambda number, events=None: False  # type: ignore[method-assign]
        edits = {
            501: [],
            502: [{"editor": {"login": "contributor"}, "editedAt": "2026-07-16T00:00:00Z"}],
        }
        client.user_content_edits_since = lambda number, since: edits[number]  # type: ignore[method-assign]
        issues = [{"number": 501}, {"number": 502}]

        self.assertEqual(
            factory_sweep.eligible_issue_numbers(client, "fairchild", candidates=issues),
            [501],
        )

    def test_reuses_the_fetched_timeline_for_both_checks_no_duplicate_fetch(self) -> None:
        client = self.client_with_no_edits()
        client.timeline = mock.Mock(return_value=[ready_event("fairchild")])  # type: ignore[method-assign]
        client.has_open_linked_pull = mock.Mock(return_value=False)  # type: ignore[method-assign]

        factory_sweep.eligible_issue_numbers(
            client, "fairchild", candidates=[{"number": 501}]
        )

        client.timeline.assert_called_once_with(501)
        client.has_open_linked_pull.assert_called_once_with(
            501, events=[ready_event("fairchild")]
        )


class PlanSweepTests(unittest.TestCase):
    def test_dispatches_up_to_remaining_headroom_oldest_first(self) -> None:
        plan = factory_sweep.plan_sweep([501, 502, 503], daily_run_count=4, daily_cap=6)

        self.assertEqual(plan.dispatch, (501, 502))
        self.assertEqual(plan.skipped_over_cap, (503,))

    def test_clamps_headroom_at_zero_when_already_over_cap(self) -> None:
        plan = factory_sweep.plan_sweep([601, 602], daily_run_count=9, daily_cap=6)

        self.assertEqual(plan.dispatch, ())
        self.assertEqual(plan.skipped_over_cap, (601, 602))

    def test_dispatches_everything_eligible_when_headroom_is_plentiful(self) -> None:
        plan = factory_sweep.plan_sweep([1, 2, 3], daily_run_count=0, daily_cap=6)

        self.assertEqual(plan.dispatch, (1, 2, 3))
        self.assertEqual(plan.skipped_over_cap, ())


class ApplyPlanTests(unittest.TestCase):
    def test_dispatches_every_planned_issue_against_the_given_ref(self) -> None:
        client = mock.Mock()
        plan = factory_sweep.SweepPlan(
            dispatch=(501, 503), skipped_over_cap=(), daily_run_count=4, daily_cap=6
        )

        factory_sweep.apply_plan(client, plan, "main")

        self.assertEqual(
            client.dispatch_factory_implement.call_args_list,
            [mock.call(501, "main"), mock.call(503, "main")],
        )

    def test_continues_past_a_single_failure_then_raises_with_every_failure(self) -> None:
        client = mock.Mock()
        client.dispatch_factory_implement.side_effect = [
            factory_sweep.factory_implement.FactoryImplementError("boom"),
            None,
        ]
        plan = factory_sweep.SweepPlan(
            dispatch=(501, 503), skipped_over_cap=(), daily_run_count=4, daily_cap=6
        )

        with self.assertRaisesRegex(factory_sweep.FactorySweepError, "#501: boom"):
            factory_sweep.apply_plan(client, plan, "main")

        self.assertEqual(client.dispatch_factory_implement.call_count, 2)


class OpenReadyAgentIssuesTests(unittest.TestCase):
    def test_requests_the_ready_agent_task_intersection_oldest_first_and_excludes_prs(
        self,
    ) -> None:
        client = factory_sweep.GitHubClient("fairchild/workspaces", "token")
        client.request = mock.Mock(  # type: ignore[method-assign]
            return_value=[{"number": 501}, {"number": 900, "pull_request": {}}]
        )

        issues = client.open_ready_agent_issues()

        self.assertEqual(issues, [{"number": 501}])
        client.request.assert_called_once_with(
            "GET",
            "/repos/fairchild/workspaces/issues"
            "?state=open&labels=ready,agent,task&sort=created&direction=asc"
            "&per_page=100&page=1",
        )

    def test_paginates_past_a_full_first_page(self) -> None:
        client = factory_sweep.GitHubClient("fairchild/workspaces", "token")
        first_page = [{"number": number} for number in range(1, 101)]
        second_page = [{"number": 101}]
        client.request = mock.Mock(side_effect=[first_page, second_page])  # type: ignore[method-assign]

        issues = client.open_ready_agent_issues()

        self.assertEqual([issue["number"] for issue in issues], list(range(1, 102)))
        self.assertEqual(client.request.call_count, 2)
        self.assertIn("page=2", client.request.call_args_list[1].args[1])


class CliFixtureTests(unittest.TestCase):
    def test_basic_fixture_dispatches_within_headroom_and_reports_the_overflow(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPT_PATH), "--fixtures-dir", str(FIXTURES_DIR / "basic")],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Factory sweep budget: 4/6", result.stdout)
        self.assertIn("[dispatch] #501, #503", result.stdout)
        self.assertIn("Dry run: 2 dispatch(es) planned; no writes.", result.stdout)

    def test_over_cap_fixture_dispatches_only_remaining_headroom(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPT_PATH), "--fixtures-dir", str(FIXTURES_DIR / "over-cap")],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Factory sweep budget: 5/6", result.stdout)
        self.assertIn("[dispatch] #601", result.stdout)
        self.assertIn(
            "[skip] over daily cap, retrying on a future sweep: #602, #603", result.stdout
        )

    def test_fixtures_dir_rejects_apply(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--fixtures-dir",
                str(FIXTURES_DIR / "basic"),
                "--apply",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("--fixtures-dir cannot be combined with --apply", result.stderr)


if __name__ == "__main__":
    unittest.main()
