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
import os
import subprocess
import sys
import unittest
from pathlib import Path


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

    def test_multi_label_repair_keeps_highest_priority_state(self) -> None:
        claimed = self.transitions[101]
        review = self.transitions[115]

        self.assertEqual(claimed.current_states, ("claimed", "ready"))
        self.assertEqual(claimed.desired_state, "claimed")
        self.assertEqual(review.current_states, ("review", "claimed", "ready"))
        self.assertEqual(review.desired_state, "review")

    def test_open_pull_request_promotes_issue_to_review(self) -> None:
        transition = self.transitions[102]

        self.assertEqual(transition.current_states, ("ready",))
        self.assertEqual(transition.desired_state, "review")
        self.assertEqual(transition.reason, "open PR #201 references the issue")

    def test_closed_unmerged_pull_request_demotes_review_and_comments(self) -> None:
        transition = self.transitions[103]

        self.assertEqual(transition.current_states, ("review",))
        self.assertEqual(transition.desired_state, "ready")
        self.assertEqual(
            transition.comment,
            "Factory janitor restored ready because PR #202 closed without merging.",
        )
        self.assertNotIn("\n", transition.comment or "")

    def test_stale_claim_expires_unassigns_and_comments(self) -> None:
        transition = self.transitions[104]

        self.assertEqual(transition.desired_state, "ready")
        self.assertIn("37.5h (claim comment)", transition.reason)
        self.assertEqual(
            transition.assignees,
            (("U_april", "april-clearwater[bot]"),),
        )
        self.assertEqual(
            transition.comment,
            "Factory janitor restored ready because the claim expired after "
            "24 hours without an open PR.",
        )

    def test_claim_age_falls_back_to_label_event(self) -> None:
        transition = self.transitions[111]

        self.assertEqual(transition.desired_state, "ready")
        self.assertIn("claimed label event", transition.reason)

    def test_recent_assignee_event_prevents_stale_expiry(self) -> None:
        issue = next(issue for issue in self.inputs.issues if issue["number"] == 112)

        timestamp, source = factory_janitor.claim_timestamp(issue)

        self.assertEqual(timestamp.isoformat(), "2026-07-13T08:00:00+00:00")
        self.assertEqual(source, "assignee event")
        self.assertNotIn(112, self.transitions)

    def test_unlabeled_agent_task_issue_awaits_owner_release(self) -> None:
        issue = next(issue for issue in self.inputs.issues if issue["number"] == 105)
        handled_numbers = set(self.transitions) | {
            anomaly.issue_number for anomaly in self.plan.anomalies
        }

        self.assertEqual(factory_janitor.current_states(issue), ())
        self.assertNotIn(105, handled_numbers)

    def test_digest_factory_human_and_out_of_scope_issues_are_untouched(self) -> None:
        handled_numbers = set(self.transitions) | {
            anomaly.issue_number for anomaly in self.plan.anomalies
        }

        self.assertTrue({106, 107, 108, 109, 114}.isdisjoint(handled_numbers))

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

    def test_second_plan_after_transitions_is_idempotent(self) -> None:
        replay = copy.deepcopy(self.inputs)
        by_number = {int(issue["number"]): issue for issue in replay.issues}
        for transition in self.plan.transitions:
            issue = by_number[transition.issue_number]
            issue["labels"] = [
                label
                for label in issue["labels"]
                if label["name"] not in factory_janitor.MANAGED_STATES
            ]
            issue["labels"].append(
                {
                    "id": replay.repo.label_ids[transition.desired_state],
                    "name": transition.desired_state,
                }
            )
            if transition.assignees:
                issue["assignees"] = []

        second_plan = factory_janitor.build_plan(replay, now=self.now)

        self.assertEqual(second_plan.transitions, ())
        self.assertEqual(
            [anomaly.issue_number for anomaly in second_plan.anomalies],
            [110, 113],
        )

    def test_apply_mutation_contains_labels_unassignment_and_comment(self) -> None:
        query, variables = factory_janitor._mutation_for_transition(
            self.transitions[104],
            self.inputs.repo.label_ids,
        )

        self.assertIn("addLabelsToLabelable", query)
        self.assertIn("removeLabelsFromLabelable", query)
        self.assertIn("removeAssigneesFromAssignable", query)
        self.assertIn("addComment", query)
        self.assertEqual(variables["addInput"]["labelIds"], ["L_ready"])
        self.assertEqual(variables["removeInput"]["labelIds"], ["L_claimed"])
        self.assertEqual(variables["unassignInput"]["assigneeIds"], ["U_april"])

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
        self.assertIn("[anomaly] #110: multiple open PRs", result.stdout)
        self.assertIn(
            "Dry run: 6 transition(s), 2 anomalies; no writes.", result.stdout
        )
        self.assertNotIn("none -> ready", result.stdout)
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
