#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fixture tests for the Factory lifecycle reconciliation janitor.

Intent: protect every mechanical transition and exclusion while proving the
default CLI path is deterministic and incapable of fixture-backed writes.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import os
import subprocess
import sys
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-janitor.py"
FIXTURES_DIR = REPO_ROOT / "fixtures" / "factory-janitor" / "basic"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


factory_janitor = load_module("factory_janitor", SCRIPT_PATH)


class FactoryJanitorTests(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self.inputs, self.now = factory_janitor.load_fixture_inputs(FIXTURES_DIR)
        self.plan = factory_janitor.build_plan(self.inputs, now=self.now)
        self.transitions = {
            transition.issue_number: transition for transition in self.plan.transitions
        }

    def issue(self, number: int):
        return next(issue for issue in self.inputs.issues if issue["number"] == number)

    def handled_numbers(self) -> set[int]:
        return set(self.transitions) | {
            anomaly.issue_number for anomaly in self.plan.anomalies
        }

    def test_multi_label_repair_keeps_highest_priority_state(self) -> None:
        claimed = self.transitions[101]
        review = self.transitions[115]

        self.assertEqual(claimed.current_states, ("claimed", "ready"))
        self.assertEqual(claimed.desired_state, "claimed")
        self.assertEqual(review.current_states, ("review", "claimed", "ready"))
        self.assertEqual(review.desired_state, "review")

    def test_open_pull_request_promotes_released_issue_to_review(self) -> None:
        transition = self.transitions[102]

        self.assertEqual(transition.current_states, ("ready",))
        self.assertEqual(transition.desired_state, "review")
        self.assertEqual(transition.reason, "open PR #201 references the issue")

    def test_owner_gate_blocks_unlabeled_issue_even_with_open_pull_request(
        self,
    ) -> None:
        issue = self.issue(105)

        self.assertEqual(factory_janitor.current_states(issue), ())
        self.assertNotIn(105, self.handled_numbers())

    def test_closed_pull_restores_ready_only_with_prior_ready_event(self) -> None:
        transition = self.transitions[103]

        self.assertEqual(transition.current_states, ("review",))
        self.assertEqual(transition.desired_state, "ready")
        self.assertIn(
            "Factory janitor restored ready because PR #202 closed without merging.",
            transition.comment or "",
        )
        self.assertIn("<!-- factory-janitor transition=", transition.comment or "")
        self.assertNotIn("\n", transition.comment or "")

    def test_closed_pull_without_prior_ready_returns_to_owner_gate(self) -> None:
        transition = self.transitions[118]

        self.assertIsNone(transition.desired_state)
        self.assertIn("returned to awaiting release", transition.comment or "")
        self.assertNotIn("restored ready", transition.comment or "")

    def test_review_without_any_known_pull_demotes_to_owner_gate(self) -> None:
        transition = self.transitions[117]

        self.assertIsNone(transition.desired_state)
        self.assertEqual(transition.reason, "review has no open PR")
        self.assertIn("returned to awaiting release", transition.comment or "")

    def test_stale_claim_uses_comment_fallback_and_preserves_human_assignee(
        self,
    ) -> None:
        transition = self.transitions[104]

        self.assertEqual(transition.desired_state, "ready")
        self.assertIn("37.5h (claim comment)", transition.reason)
        self.assertEqual(
            transition.assignees,
            (("U_april", "april-clearwater[bot]"),),
        )
        self.assertEqual(transition.preserved_assignees, ("fairchild",))
        self.assertIn("restored ready", transition.comment or "")
        self.assertIn(
            "Human assignees left in place: @fairchild.", transition.comment or ""
        )
        self.assertIn("<!-- factory-janitor transition=", transition.comment or "")

    def test_stale_claim_without_prior_ready_returns_to_owner_gate(self) -> None:
        transition = self.transitions[111]

        self.assertIsNone(transition.desired_state)
        self.assertIn("claimed label event", transition.reason)
        self.assertIn("returned to awaiting release", transition.comment or "")
        self.assertNotIn("restored ready", transition.comment or "")

    def test_claim_age_prefers_label_event_and_ignores_assignment_event(self) -> None:
        issue = self.issue(112)

        timestamp, source = factory_janitor.claim_timestamp(issue)

        self.assertEqual(timestamp.isoformat(), "2026-07-10T08:00:00+00:00")
        self.assertEqual(source, "claimed label event")
        self.assertIn(112, self.transitions)

    def test_malformed_chosen_claim_source_is_anomaly_without_transition(self) -> None:
        anomalies = {
            anomaly.issue_number: anomaly.detail for anomaly in self.plan.anomalies
        }

        self.assertEqual(
            anomalies[119],
            "latest claimed label event has malformed or missing timestamp",
        )
        self.assertNotIn(119, self.transitions)

    def test_missing_chosen_comment_timestamp_is_anomaly_without_transition(
        self,
    ) -> None:
        issue = copy.deepcopy(self.issue(104))
        del issue["comments"][-1]["createdAt"]
        inputs = replace(self.inputs, issues=[issue], pulls=[], closed_issues=[])

        plan = factory_janitor.build_plan(inputs, now=self.now)

        self.assertEqual(plan.transitions, ())
        self.assertEqual(
            plan.anomalies[0].detail,
            "latest claim comment has malformed or missing timestamp",
        )

    def test_human_label_excludes_agent_task_drift_unconditionally(self) -> None:
        issue = self.issue(108)

        self.assertTrue(
            {"human", "agent", "task"}.issubset(factory_janitor.label_names(issue))
        )
        self.assertFalse(factory_janitor.is_managed_issue(issue))
        self.assertNotIn(108, self.handled_numbers())

    def test_digest_factory_closed_and_out_of_scope_issues_are_untouched(self) -> None:
        self.assertTrue({106, 107, 109, 114}.isdisjoint(self.handled_numbers()))

    def test_leading_digest_marker_excludes_issue_without_factory_label(self) -> None:
        issue = {
            "id": "I_digest",
            "number": 999,
            "body": f" \n{factory_janitor.DIGEST_MARKER}\nOwner surface",
            "state": "OPEN",
            "labels": [
                {"id": "L_agent", "name": "agent"},
                {"id": "L_task", "name": "task"},
                {"id": "L_ready", "name": "ready"},
                {"id": "L_claimed", "name": "claimed"},
            ],
        }

        self.assertFalse(factory_janitor.is_managed_issue(issue))

    def test_pull_detection_ignores_drafts_and_raw_body_keywords(self) -> None:
        self.assertNotIn(116, self.handled_numbers())
        raw_body_pull = next(
            pull for pull in self.inputs.pulls if pull["number"] == 217
        )

        self.assertEqual(factory_janitor.referenced_issue_numbers(raw_body_pull), set())
        self.assertIn("isDraft", factory_janitor.PULLS_QUERY)
        self.assertNotIn("number body url", factory_janitor.PULLS_QUERY)

    def test_ambiguous_states_are_reported_without_blocking_other_repairs(self) -> None:
        anomalies = {
            anomaly.issue_number: anomaly.detail for anomaly in self.plan.anomalies
        }

        self.assertEqual(
            anomalies[110],
            "multiple open PRs reference the issue: #210, #211",
        )
        self.assertEqual(
            anomalies[113],
            "claimed state has no derivable claim timestamp",
        )
        self.assertNotIn(110, self.transitions)
        self.assertNotIn(113, self.transitions)

    def test_existing_marker_for_same_transition_skips_duplicate_comment(self) -> None:
        replay = copy.deepcopy(self.inputs)
        issue = next(item for item in replay.issues if item["number"] == 104)
        issue["comments"].append(
            {
                "body": self.transitions[104].comment,
                "createdAt": "2026-07-13T13:00:00Z",
                "authorAssociation": "NONE",
                "author": {"login": "github-actions[bot]"},
            }
        )

        rerun = factory_janitor.build_plan(replay, now=self.now)
        transition = next(
            item for item in rerun.transitions if item.issue_number == 104
        )

        self.assertIsNone(transition.comment)

    def test_second_plan_after_state_repairs_is_idempotent(self) -> None:
        replay = copy.deepcopy(self.inputs)
        by_number = {
            int(issue["number"]): issue
            for issue in replay.issues + replay.closed_issues
        }
        for transition in self.plan.transitions:
            issue = by_number[transition.issue_number]
            removed = set(transition.current_label_ids) - {transition.desired_state}
            issue["labels"] = [
                label for label in issue["labels"] if label["name"] not in removed
            ]
            if transition.desired_state is not None and transition.desired_state not in {
                label["name"] for label in issue["labels"]
            }:
                issue["labels"].append(
                    {
                        "id": replay.repo.label_ids[transition.desired_state],
                        "name": transition.desired_state,
                    }
                )
            removed_ids = {assignee_id for assignee_id, _ in transition.assignees}
            if removed_ids:
                issue["assignees"] = [
                    assignee
                    for assignee in issue["assignees"]
                    if assignee["id"] not in removed_ids
                ]
            if transition.comment:
                issue["comments"].append(
                    {
                        "body": transition.comment,
                        "createdAt": self.now.isoformat(),
                        "authorAssociation": "NONE",
                        "author": {"login": "github-actions[bot]"},
                    }
                )

        second_plan = factory_janitor.build_plan(replay, now=self.now)

        self.assertEqual(second_plan.transitions, ())
        self.assertEqual(
            [anomaly.issue_number for anomaly in second_plan.anomalies],
            [110, 113, 119],
        )

    def test_closed_issues_shed_lifecycle_labels_without_comment(self) -> None:
        stale = self.transitions[120]
        human_lane = self.transitions[121]

        self.assertEqual(stale.current_states, ("claimed", "mergeable"))
        self.assertIsNone(stale.desired_state)
        self.assertEqual(stale.reason, "issue is closed")
        self.assertIsNone(stale.comment)
        self.assertEqual(stale.assignees, ())
        self.assertEqual(human_lane.current_states, ("ready",))
        self.assertIsNone(human_lane.desired_state)

    def test_closed_issue_without_lifecycle_labels_is_untouched(self) -> None:
        self.assertNotIn(122, self.handled_numbers())

    def test_closed_cleanup_rejects_open_issue_defensively(self) -> None:
        open_issue = copy.deepcopy(self.issue(101))

        self.assertIn("claimed", factory_janitor.label_names(open_issue))
        self.assertIsNone(factory_janitor.closed_lifecycle_transition(open_issue))

    def test_closed_issue_mutations_only_remove_labels(self) -> None:
        operations = factory_janitor._mutations_for_transition(
            self.transitions[120], self.inputs.repo.label_ids
        )

        self.assertEqual([operation.name for operation in operations], ["remove-labels"])
        self.assertEqual(
            operations[0].variables["input"]["labelIds"],
            ["L_claimed", "L_mergeable"],
        )

    def test_live_fetch_dedupes_closed_issues_across_label_queries(self) -> None:
        closed_node = {
            "id": "I_900",
            "number": 900,
            "title": "Closed with claimed and mergeable",
            "state": "CLOSED",
            "labels": {
                "nodes": [
                    {"id": "L_claimed", "name": "claimed"},
                    {"id": "L_mergeable", "name": "mergeable"},
                ]
            },
        }
        page = {"pageInfo": {"hasNextPage": False, "endCursor": None}}
        queried_labels: list[str] = []

        def fake_graphql(_token, query, variables):
            if "FactoryJanitorIssues" in query:
                repository = {
                    "id": "R_1",
                    "readyLabel": {"id": "L_ready", "name": "ready"},
                    "claimedLabel": {"id": "L_claimed", "name": "claimed"},
                    "reviewLabel": {"id": "L_review", "name": "review"},
                    "issues": {**page, "nodes": []},
                }
            elif "FactoryJanitorPulls" in query:
                repository = {"pullRequests": {**page, "nodes": []}}
            else:
                queried_labels.append(variables["label"])
                nodes = (
                    [closed_node]
                    if variables["label"] in {"claimed", "mergeable"}
                    else []
                )
                repository = {"issues": {**page, "nodes": nodes}}
            return {"data": {"repository": repository}}

        with mock.patch.object(factory_janitor, "graphql", side_effect=fake_graphql):
            inputs = factory_janitor.fetch_live_inputs("fairchild/workspaces", "token")

        self.assertEqual(
            queried_labels, list(factory_janitor.CLOSED_LIFECYCLE_LABELS)
        )
        self.assertEqual(
            [issue["number"] for issue in inputs.closed_issues], [900]
        )
        self.assertEqual(
            [label["name"] for label in inputs.closed_issues[0]["labels"]],
            ["claimed", "mergeable"],
        )

    def test_mutations_are_ordered_labels_unassign_then_comment(self) -> None:
        operations = factory_janitor._mutations_for_transition(
            self.transitions[104], self.inputs.repo.label_ids
        )

        self.assertEqual(
            [operation.name for operation in operations],
            ["add-label", "remove-labels", "unassign-bots", "comment"],
        )
        self.assertEqual(operations[0].variables["input"]["labelIds"], ["L_ready"])
        self.assertEqual(operations[1].variables["input"]["labelIds"], ["L_claimed"])
        self.assertEqual(operations[2].variables["input"]["assigneeIds"], ["U_april"])
        self.assertIn(
            "<!-- factory-janitor transition=",
            operations[3].variables["input"]["body"],
        )

    def test_apply_retries_transient_failure_stops_issue_and_continues(self) -> None:
        calls: list[str] = []

        def fake_graphql(_token, _query, variables):
            mutation_id = variables["input"]["clientMutationId"]
            calls.append(mutation_id)
            if mutation_id.endswith("104-remove-labels"):
                raise factory_janitor.GitHubRequestError(
                    "temporary outage", transient=True
                )
            return {"data": {}}

        plan = factory_janitor.ReconciliationPlan(
            (self.transitions[104], self.transitions[102]), ()
        )
        with (
            mock.patch.object(factory_janitor, "graphql", side_effect=fake_graphql),
            mock.patch.object(factory_janitor.time, "sleep") as sleep,
            self.assertRaisesRegex(
                factory_janitor.FactoryJanitorError,
                r"persistent per-issue failures: #104: temporary outage",
            ),
        ):
            factory_janitor.apply_plan(plan, self.inputs, "token")

        self.assertEqual(
            calls,
            [
                "factory-janitor-104-add-label",
                "factory-janitor-104-remove-labels",
                "factory-janitor-104-remove-labels",
                "factory-janitor-104-remove-labels",
                "factory-janitor-102-add-label",
                "factory-janitor-102-remove-labels",
            ],
        )
        self.assertEqual([item.args[0] for item in sleep.call_args_list], [1.0, 2.0])
        self.assertFalse(any("104-unassign" in item for item in calls))
        self.assertFalse(any("104-comment" in item for item in calls))

    def test_graphql_partial_data_with_errors_is_failure(self) -> None:
        response = mock.MagicMock()
        response.read.return_value = json.dumps(
            {"data": {"partial": True}, "errors": [{"message": "field failed"}]}
        ).encode("utf-8")
        response.__enter__.return_value = response

        with (
            mock.patch.object(
                factory_janitor.urllib.request, "urlopen", return_value=response
            ),
            self.assertRaisesRegex(
                factory_janitor.GitHubRequestError,
                "GitHub GraphQL error: field failed",
            ),
        ):
            factory_janitor.graphql("token", "query { viewer { login } }", {})

    def test_cli_plan_validation_forbids_every_none_to_transition(self) -> None:
        invalid = replace(self.transitions[102], current_states=())

        with self.assertRaisesRegex(
            factory_janitor.FactoryJanitorError,
            r"Owner release gate forbids every none->\* transition",
        ):
            factory_janitor.validate_plan(
                factory_janitor.ReconciliationPlan((invalid,), ())
            )

    def test_fixture_cli_defaults_to_dry_run_and_reports_zero_writes(self) -> None:
        env = os.environ.copy()
        env.pop("GH_TOKEN", None)
        env.pop("GITHUB_REPOSITORY", None)

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--fixtures-dir",
                str(FIXTURES_DIR),
            ],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[transition] #102: ready -> review", result.stdout)
        self.assertIn("[transition] #103: review -> ready", result.stdout)
        self.assertIn("[transition] #117: review -> none", result.stdout)
        self.assertIn(
            "[transition] #120: claimed+mergeable -> none (issue is closed)",
            result.stdout,
        )
        self.assertIn("[anomaly] #110: multiple open PRs", result.stdout)
        self.assertIn(
            "Dry run: 11 transition(s), 3 anomalies; no writes.", result.stdout
        )
        self.assertNotRegex(result.stdout, r"\[transition\].*: none ->")
        self.assertNotIn("[applied]", result.stdout)

    def test_fixture_mode_rejects_apply(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--fixtures-dir",
                str(FIXTURES_DIR),
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
