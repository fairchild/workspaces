#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Policy tests for the factory CI-evidence verifier (#1120).

Intent: the verifier completes named-check evidence only from live check-run
state bound to the current head, never writes when the head moved, and clears
blocked:evidence only when it was machine-applied and everything is complete
and SHA-current.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-evidence-verify.py"
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "factory-evidence-verify.yml"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


verify = load_module("factory_evidence_verify", SCRIPT_PATH)
# check_runs_for lives in the contributor runtime's evidence module; the
# verifier re-exports it by import, so patching run_optional must target the
# module that actually calls it.
verify_evidence = sys.modules["evidence"]

HEAD = "a" * 40
OTHER_HEAD = "b" * 40
CI_ITEM = "CI: `Web CI` green on the PR head"
DIFF_ITEM = "Diff: dot-only segments rejected, readable from the diff alone"


def ci_entry(
    *,
    index: int = 1,
    status: str = "pending-ci",
    verified_head_sha: str | None = None,
) -> dict[str, object]:
    entry: dict[str, object] = {
        "index": index,
        "item": CI_ITEM,
        "status": status,
        "detail": "waiting for checks",
        "kind": "ci",
    }
    if verified_head_sha is not None:
        entry["verified_head_sha"] = verified_head_sha
    return entry


def body_with_entries(entries: list[dict[str, object]]) -> str:
    payload = json.dumps({"entries": entries}, indent=2, ensure_ascii=False)
    lines = "\n".join(
        f"- [{entry['status']}] {entry['item']} -- {entry['detail']}" for entry in entries
    )
    return (
        "*Persona*\n\n## Summary\n- change\n\n"
        f"<!-- evidence-status:v1\n{payload}\n-->\n\n"
        f"## Evidence Status\n{lines}\n\n"
        "## Validation\n- blocked on evidence: waiting for checks\n\n"
        "Closes #99\n\n<!-- contributor:issue=99;agent=test -->"
    )


def with_owner_edit(body: str, note: str) -> str:
    """Simulate an owner editing the PR description (not the evidence block)."""
    return body.replace("## Summary\n- change", f"## Summary\n- change\n- {note}")


def pr_payload(
    body: str,
    *,
    head_sha: str = HEAD,
    labels: list[str] | None = None,
    state: str = "open",
) -> dict[str, object]:
    return {
        "number": 321,
        "state": state,
        "body": body,
        "head": {"sha": head_sha},
        "labels": [{"name": name} for name in labels or []],
    }


class CheckRunsForTests(unittest.TestCase):
    """The empty list and None mean different things and the callers act on
    the difference, so the boundary that produces them is pinned here."""

    def resolve(self, raw: str):
        with mock.patch.object(verify_evidence, "run_optional", return_value=raw):
            return verify_evidence.check_runs_for("Web CI", HEAD, {})

    def test_an_answered_empty_result_is_a_list_not_a_failure(self) -> None:
        self.assertEqual(self.resolve('{"total_count": 0, "check_runs": []}'), [])

    def test_a_failed_or_malformed_lookup_is_none(self) -> None:
        for raw in ("", "not json", "[]", '{"message": "Not Found"}'):
            with self.subTest(raw=raw):
                self.assertIsNone(self.resolve(raw))

    def test_unfinished_runs_come_back_but_yield_no_completed_run(self) -> None:
        runs = self.resolve(
            '{"check_runs": [{"status": "in_progress", "name": "Web CI"}]}'
        )
        self.assertEqual(len(runs or []), 1)
        self.assertIsNone(verify.latest_completed_run(runs))


class CheckRunResolutionTests(unittest.TestCase):
    def test_missing_run_stays_pending(self) -> None:
        update = verify.entry_update_for_check_run("Web CI", HEAD, None)
        self.assertEqual(update["status"], "pending-ci")
        self.assertIn("no completed run of `Web CI`", str(update["detail"]))

    def test_an_unknown_check_name_says_so_instead_of_reading_as_waiting(self) -> None:
        # An entry naming a check that does not exist never completes. Saying
        # "waiting for checks" there leaves the PR looking like CI is slow.
        update = verify.entry_update_for_check_run(
            "Wbe CI", HEAD, None, check_known=False
        )
        self.assertEqual(update["status"], "pending-ci")
        self.assertIn("no run of `Wbe CI` exists on head", str(update["detail"]))
        self.assertIn("may not match a check on this repository", str(update["detail"]))
        # Stated as an observation, not a verdict: a later check suite can
        # still create the run, so this lane must not accuse a valid name.
        self.assertIn("may not have been created", str(update["detail"]))

    def test_a_failed_lookup_is_not_reported_as_an_unknown_check(self) -> None:
        # check_runs_for returns None when the query itself did not resolve,
        # which says nothing about whether the check exists.
        self.assertIsNone(verify.latest_completed_run(None))
        update = verify.entry_update_for_check_run("Web CI", HEAD, None, check_known=True)
        self.assertIn("no completed run of `Web CI`", str(update["detail"]))

    def test_latest_completed_run_picks_the_newest_finished_run(self) -> None:
        runs = [
            {"status": "completed", "completed_at": "2026-08-27T01:00:00Z", "id": 1},
            {"status": "in_progress", "id": 2},
            {"status": "completed", "completed_at": "2026-08-27T02:00:00Z", "id": 3},
        ]
        picked = verify.latest_completed_run(runs)
        assert picked is not None
        self.assertEqual(picked["id"], 3)
        self.assertIsNone(verify.latest_completed_run([{"status": "queued"}]))

    def test_green_run_completes_with_sha_binding_and_link(self) -> None:
        update = verify.entry_update_for_check_run(
            "Web CI",
            HEAD,
            {"conclusion": "success", "html_url": "https://example.invalid/run/1"},
        )
        self.assertEqual(update["status"], "complete")
        self.assertEqual(update["verified_head_sha"], HEAD)
        self.assertEqual(update["proof_url"], "https://example.invalid/run/1")
        self.assertIn(HEAD[:12], str(update["detail"]))
        self.assertIn("https://example.invalid/run/1", str(update["detail"]))

    def test_failed_run_stays_pending_with_conclusion_linked(self) -> None:
        update = verify.entry_update_for_check_run(
            "Web CI",
            HEAD,
            {"conclusion": "failure", "html_url": "https://example.invalid/run/2"},
        )
        self.assertEqual(update["status"], "pending-ci")
        self.assertIn("concluded failure", str(update["detail"]))
        self.assertNotIn("verified_head_sha", update)


class VerificationSelectionTests(unittest.TestCase):
    def test_pending_and_stale_complete_entries_need_verification(self) -> None:
        entries: list[object] = [
            ci_entry(index=1, status="pending-ci"),
            ci_entry(index=2, status="complete", verified_head_sha=OTHER_HEAD),
            ci_entry(index=3, status="complete", verified_head_sha=HEAD),
            {"index": 4, "item": DIFF_ITEM, "status": "pending-ci", "detail": "d"},
        ]

        self.assertEqual(
            verify.ci_entries_needing_verification(entries, HEAD),
            [(1, "Web CI"), (2, "Web CI")],
        )

    def test_entries_without_extractable_names_are_skipped(self) -> None:
        entries: list[object] = [
            {"index": 1, "item": "CI job green somewhere", "status": "pending-ci", "detail": "d"}
        ]
        self.assertEqual(verify.ci_entries_needing_verification(entries, HEAD), [])


class BlockedLabelClearTests(unittest.TestCase):
    def test_clears_only_when_all_complete_and_sha_current(self) -> None:
        complete = [
            ci_entry(index=1, status="complete", verified_head_sha=HEAD),
            {"index": 2, "item": DIFF_ITEM, "status": "complete", "detail": "d"},
        ]
        self.assertTrue(verify.should_clear_blocked_label(complete, HEAD))
        self.assertFalse(
            verify.should_clear_blocked_label(
                [ci_entry(index=1, status="complete", verified_head_sha=OTHER_HEAD)], HEAD
            )
        )
        self.assertFalse(
            verify.should_clear_blocked_label([ci_entry(index=1, status="pending-ci")], HEAD)
        )
        self.assertFalse(verify.should_clear_blocked_label([], HEAD))
        self.assertFalse(verify.should_clear_blocked_label(None, HEAD))

    def test_label_provenance_requires_factory_actor_on_latest_event(self) -> None:
        factory_actor = next(iter(verify.FACTORY_LABEL_ACTORS))

        def timeline(events: list[dict[str, object]]):
            return mock.patch.object(verify, "_gh_json", return_value=events)

        with timeline(
            [
                {
                    "event": "labeled",
                    "label": {"name": "blocked:evidence"},
                    "actor": {"login": factory_actor},
                }
            ]
        ):
            self.assertTrue(verify.blocked_label_applied_by_factory(321, {}))

        with timeline(
            [
                {
                    "event": "labeled",
                    "label": {"name": "blocked:evidence"},
                    "actor": {"login": factory_actor},
                },
                {
                    "event": "labeled",
                    "label": {"name": "blocked:evidence"},
                    "actor": {"login": "some-human"},
                },
            ]
        ):
            self.assertFalse(verify.blocked_label_applied_by_factory(321, {}))

        with timeline([]):
            self.assertFalse(verify.blocked_label_applied_by_factory(321, {}))


class StandingRejectionTests(unittest.TestCase):
    @staticmethod
    def review(login: str, state: str, submitted_at: str, commit: str = HEAD):
        return {
            "user": {"login": login},
            "state": state,
            "commit_id": commit,
            "submitted_at": submitted_at,
        }

    def check(self, reviews) -> bool:
        with mock.patch.object(verify, "_gh_json", return_value=reviews):
            return verify.standing_rejection(321, HEAD, {})

    def test_a_reviewer_apps_standing_rejection_on_this_head_counts(self) -> None:
        for bot in sorted(verify.REVIEWER_BOTS):
            with self.subTest(bot=bot):
                self.assertTrue(
                    self.check([self.review(bot, "CHANGES_REQUESTED", "2026-08-27T01:00:00Z")])
                )

    def test_a_later_verdict_from_the_same_reviewer_wins(self) -> None:
        bot = "workspace-agents[bot]"
        self.assertFalse(
            self.check(
                [
                    self.review(bot, "CHANGES_REQUESTED", "2026-08-27T01:00:00Z"),
                    self.review(bot, "APPROVED", "2026-08-27T02:00:00Z"),
                ]
            )
        )
        # ...but a comment-only review never displaces a verdict.
        self.assertTrue(
            self.check(
                [
                    self.review(bot, "CHANGES_REQUESTED", "2026-08-27T01:00:00Z"),
                    self.review(bot, "COMMENTED", "2026-08-27T02:00:00Z"),
                ]
            )
        )

    def test_other_authors_older_heads_and_failed_lookups_do_not_count(self) -> None:
        self.assertFalse(
            self.check([self.review("fairchild", "CHANGES_REQUESTED", "2026-08-27T01:00:00Z")])
        )
        self.assertFalse(
            self.check(
                [
                    self.review(
                        "workspace-agents[bot]",
                        "CHANGES_REQUESTED",
                        "2026-08-27T01:00:00Z",
                        commit=OTHER_HEAD,
                    )
                ]
            )
        )
        self.assertFalse(self.check([]))
        self.assertFalse(self.check(None))


class ProcessPrTests(unittest.TestCase):
    maxDiff = None

    def test_green_check_completes_entry_and_clears_machine_label(self) -> None:
        body = body_with_entries([ci_entry()])
        pr = pr_payload(body, labels=["blocked:evidence"])
        written: dict[str, str] = {}
        gh_calls: list[list[str]] = []

        def fake_gh_json(args, env):
            if any("pulls/321" in arg for arg in args):
                return pr
            return None

        def fake_write(pr_number, new_body, env):
            written["body"] = new_body
            return True

        with (
            mock.patch.object(verify, "_gh_json", side_effect=fake_gh_json),
            mock.patch.object(
                verify,
                "check_runs_for",
                return_value=[
                    {
                        "status": "completed",
                        "conclusion": "success",
                        "completed_at": "2026-08-27T00:00:00Z",
                        "html_url": "https://example.invalid/run/1",
                    }
                ],
            ),
            mock.patch.object(verify, "_write_pr_body", side_effect=fake_write),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True),
        ):
            verify.process_pr(321, {})

        self.assertIn(f"- [complete] {CI_ITEM}", written["body"])
        self.assertIn(f'"verified_head_sha": "{HEAD}"', written["body"])
        self.assertIn(
            ["pr", "edit", "321", "--remove-label", "blocked:evidence"],
            gh_calls,
        )

    def run_process_pr(self, entries, *, labels, rejection: bool):
        """process_pr over one PR, reporting the gh commands it issued."""
        body = body_with_entries(entries)
        pr = pr_payload(body, labels=labels)
        gh_calls: list[list[str]] = []

        def fake_gh_json(args, env):
            if any(arg.endswith("/reviews") for arg in args):
                if not rejection:
                    return []
                return [
                    {
                        "user": {"login": "workspace-agents[bot]"},
                        "state": "CHANGES_REQUESTED",
                        "commit_id": HEAD,
                        "submitted_at": "2026-08-27T01:00:00Z",
                    }
                ]
            if any("pulls/321" in arg for arg in args):
                return pr
            return None

        with (
            mock.patch.object(verify, "_gh_json", side_effect=fake_gh_json),
            mock.patch.object(
                verify,
                "check_runs_for",
                return_value=[
                    {
                        "status": "completed",
                        "conclusion": "success",
                        "completed_at": "2026-08-27T00:00:00Z",
                        "html_url": "https://example.invalid/run/1",
                    }
                ],
            ),
            mock.patch.object(verify, "_write_pr_body", return_value=True),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True),
        ):
            verify.process_pr(321, {})
        return gh_calls

    def dispatched(self, gh_calls) -> bool:
        return any(
            call[:2] == ["workflow", "run"] and verify.REVIEW_WORKFLOW in call
            for call in gh_calls
        )

    def test_completing_the_contract_asks_for_a_fresh_review(self) -> None:
        # #1379: this lane writes the PR body with GITHUB_TOKEN, and GitHub
        # suppresses `pull_request: edited` runs caused by that token — so the
        # completion that satisfies the reviewer's objection generates no event
        # at all. Dispatching is the only way the news travels.
        calls = self.run_process_pr([ci_entry()], labels=["blocked:evidence"], rejection=True)
        self.assertTrue(self.dispatched(calls))
        self.assertIn(["pr", "edit", "321", "--remove-label", "blocked:evidence"], calls)

    def test_no_standing_rejection_means_no_review_is_requested(self) -> None:
        calls = self.run_process_pr([ci_entry()], labels=["blocked:evidence"], rejection=False)
        self.assertFalse(self.dispatched(calls))

    def test_an_already_complete_contract_asks_for_nothing(self) -> None:
        # Only the transition asks. Otherwise every check suite on a finished
        # PR would spend a slot of the review budget.
        complete = dict(ci_entry(), status="complete", verified_head_sha=HEAD)
        calls = self.run_process_pr([complete], labels=[], rejection=True)
        self.assertFalse(self.dispatched(calls))

    def test_a_remaining_blocking_label_holds_the_request_back(self) -> None:
        # A human-applied blocked:evidence is left alone, and the readiness
        # gate would refuse the PR anyway, so asking spends budget for nothing.
        body = body_with_entries([ci_entry()])
        pr = pr_payload(body, labels=["blocked:evidence"])
        gh_calls: list[list[str]] = []

        def fake_gh_json(args, env):
            if any(arg.endswith("/reviews") for arg in args):
                return [
                    {
                        "user": {"login": "workspace-agents[bot]"},
                        "state": "CHANGES_REQUESTED",
                        "commit_id": HEAD,
                        "submitted_at": "2026-08-27T01:00:00Z",
                    }
                ]
            if any("pulls/321" in arg for arg in args):
                return pr
            return None

        with (
            mock.patch.object(verify, "_gh_json", side_effect=fake_gh_json),
            mock.patch.object(
                verify,
                "check_runs_for",
                return_value=[
                    {
                        "status": "completed",
                        "conclusion": "success",
                        "completed_at": "2026-08-27T00:00:00Z",
                        "html_url": "https://example.invalid/run/1",
                    }
                ],
            ),
            mock.patch.object(verify, "_write_pr_body", return_value=True),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=False),
            mock.patch.object(verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True),
        ):
            verify.process_pr(321, {})
        self.assertFalse(self.dispatched(gh_calls))
        self.assertNotIn(["pr", "edit", "321", "--remove-label", "blocked:evidence"], gh_calls)

    def test_head_movement_between_read_and_write_skips_the_write(self) -> None:
        body = body_with_entries([ci_entry()])
        responses = iter(
            [
                pr_payload(body),
                pr_payload(body, head_sha=OTHER_HEAD),
            ]
        )

        with (
            mock.patch.object(verify, "_gh_json", side_effect=lambda args, env: next(responses)),
            mock.patch.object(
                verify,
                "check_runs_for",
                return_value=[
                    {
                        "status": "completed",
                        "conclusion": "success",
                        "completed_at": "2026-08-27T00:00:00Z",
                        "html_url": "https://example.invalid/run/1",
                    }
                ],
            ),
            mock.patch.object(verify, "_write_pr_body") as write,
            mock.patch.object(verify, "_gh") as gh,
        ):
            verify.process_pr(321, {})

        write.assert_not_called()
        gh.assert_not_called()

    def test_non_factory_and_metadata_less_bodies_are_skipped(self) -> None:
        for body in ("plain PR body", "*Persona*\n\n<!-- contributor:issue=99;agent=test -->"):
            with self.subTest(body=body):
                with (
                    mock.patch.object(verify, "_gh_json", return_value=pr_payload(body)),
                    mock.patch.object(verify, "check_runs_for") as lookup,
                    mock.patch.object(verify, "_write_pr_body") as write,
                ):
                    verify.process_pr(321, {})
                lookup.assert_not_called()
                write.assert_not_called()

    def test_human_applied_label_is_never_removed(self) -> None:
        entries = [ci_entry(status="complete", verified_head_sha=HEAD)]
        body = body_with_entries(entries)
        pr = pr_payload(body, labels=["blocked:evidence"])

        with (
            mock.patch.object(verify, "_gh_json", return_value=pr),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=False),
            mock.patch.object(verify, "_gh") as gh,
        ):
            verify.process_pr(321, {})

        gh.assert_not_called()


class BodyChangeRaceGuardTests(unittest.TestCase):
    """Coverage for #1183: a body edit at a stable head SHA must never be
    clobbered by a write derived from the stale pre-edit body."""

    maxDiff = None

    def test_stable_sha_body_change_does_not_write_stale_derived_body(self) -> None:
        body = body_with_entries([ci_entry()])
        edited_body = with_owner_edit(body, "owner edited the description mid-flight")
        updates = {
            1: verify.entry_update_for_check_run(
                "Web CI",
                HEAD,
                {"conclusion": "success", "html_url": "https://example.invalid/run/1"},
            )
        }
        stale_new_body = verify.update_evidence_entries(body, updates)

        written: dict[str, str] = {}

        def fake_write(pr_number, new_body, env):
            written["body"] = new_body
            return True

        with (
            mock.patch.object(
                verify,
                "_gh_json",
                # attempt 1: same SHA, drifted body; attempt 2: stable now
                side_effect=[
                    pr_payload(edited_body, head_sha=HEAD),
                    pr_payload(edited_body, head_sha=HEAD),
                ],
            ) as gh_json,
            mock.patch.object(verify, "_write_pr_body", side_effect=fake_write) as write,
        ):
            result = verify._apply_ci_updates(321, HEAD, body, updates, {})

        # Both mocked re-fetches must actually have been consumed — otherwise
        # this test would pass even if the retry loop short-circuited after
        # detecting the first drift instead of re-checking the reapplied body.
        self.assertEqual(gh_json.call_count, 2)
        write.assert_called_once()
        self.assertEqual(result, written["body"])
        self.assertNotEqual(written["body"], stale_new_body)
        self.assertIn("owner edited the description mid-flight", written["body"])
        self.assertIn(f"- [complete] {CI_ITEM}", written["body"])

    def test_race_then_reapply_succeeds_and_completes_verification(self) -> None:
        body = body_with_entries([ci_entry()])
        edited_body = with_owner_edit(body, "clarify rollout plan")
        pr_initial = pr_payload(body, labels=["blocked:evidence"])
        pr_drifted = pr_payload(edited_body, labels=["blocked:evidence"])

        written: dict[str, str] = {}
        gh_calls: list[list[str]] = []

        def fake_write(pr_number, new_body, env):
            written["body"] = new_body
            return True

        with (
            mock.patch.object(
                verify,
                "_gh_json",
                # A fourth call now: after the write completes the contract,
                # process_pr asks whether a rejection is standing before
                # requesting a fresh review.
                side_effect=[pr_initial, pr_drifted, pr_drifted, []],
            ) as gh_json,
            mock.patch.object(
                verify,
                "check_runs_for",
                return_value=[
                    {
                        "status": "completed",
                        "conclusion": "success",
                        "completed_at": "2026-08-27T00:00:00Z",
                        "html_url": "https://example.invalid/run/1",
                    }
                ],
            ),
            mock.patch.object(verify, "_write_pr_body", side_effect=fake_write),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True),
        ):
            verify.process_pr(321, {})

        self.assertEqual(gh_json.call_count, 4)
        self.assertIn("clarify rollout plan", written["body"])
        self.assertIn(f"- [complete] {CI_ITEM}", written["body"])
        self.assertIn(
            ["pr", "edit", "321", "--remove-label", "blocked:evidence"],
            gh_calls,
        )

    def test_gives_up_without_writing_when_body_keeps_changing(self) -> None:
        body = body_with_entries([ci_entry()])
        drifting_bodies = [
            with_owner_edit(body, f"edit #{i}") for i in range(1, verify.MAX_WRITE_ATTEMPTS + 1)
        ]
        gh_responses = [pr_payload(body, labels=["blocked:evidence"])] + [
            pr_payload(b, labels=["blocked:evidence"]) for b in drifting_bodies
        ]

        with (
            mock.patch.object(verify, "_gh_json", side_effect=gh_responses) as gh_json,
            mock.patch.object(
                verify,
                "check_runs_for",
                return_value=[
                    {
                        "status": "completed",
                        "conclusion": "success",
                        "completed_at": "2026-08-27T00:00:00Z",
                        "html_url": "https://example.invalid/run/1",
                    }
                ],
            ),
            mock.patch.object(verify, "_write_pr_body") as write,
            mock.patch.object(verify, "_gh") as gh,
            mock.patch.object(verify, "log") as log_mock,
        ):
            verify.process_pr(321, {})

        # Bounded: exactly one initial fetch plus MAX_WRITE_ATTEMPTS retries —
        # a fourth call would raise StopIteration and fail this test, proving
        # the loop can't spin past the documented bound.
        self.assertEqual(gh_json.call_count, 1 + verify.MAX_WRITE_ATTEMPTS)
        write.assert_not_called()
        gh.assert_not_called()
        self.assertTrue(
            any("giving up" in call.args[0] for call in log_mock.call_args_list)
        )

    def test_retargeted_entry_is_dropped_instead_of_misapplied(self) -> None:
        """If an owner retargets the evidence line itself (not just prose) to
        a different check between read and write, the stale-index update
        must be dropped, never slapped onto the now-different entry."""
        body = body_with_entries([ci_entry()])
        retargeted_entry = ci_entry(status="pending-ci")
        retargeted_entry["item"] = "CI: `macOS CI` green on the PR head"
        retargeted_body = body_with_entries([retargeted_entry])
        updates = {
            1: verify.entry_update_for_check_run(
                "Web CI",
                HEAD,
                {"conclusion": "success", "html_url": "https://example.invalid/run/1"},
            )
        }

        with (
            mock.patch.object(
                verify, "_gh_json", side_effect=[pr_payload(retargeted_body, head_sha=HEAD)]
            ) as gh_json,
            mock.patch.object(verify, "_write_pr_body") as write,
        ):
            result = verify._apply_ci_updates(321, HEAD, body, updates, {})

        self.assertEqual(gh_json.call_count, 1)
        write.assert_not_called()
        self.assertEqual(result, retargeted_body)
        self.assertNotIn("Web CI", result)
        self.assertIn("[pending-ci] CI: `macOS CI` green on the PR head", result)


class WorkflowContractTests(unittest.TestCase):
    def test_verify_workflow_is_a_minimal_trusted_lane(self) -> None:
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")

        self.assertIn("check_suite:", workflow)
        self.assertIn("types: [completed]", workflow)
        self.assertIn("vars.AGENT_AUTOMATIONS_ENABLED == 'true'", workflow)
        self.assertIn("vars.FACTORY_EVIDENCE_VERIFY_ENABLED == 'true'", workflow)
        # M3 hardening norm: manual dispatch respects kill switches on every
        # factory entry — no event path may bypass the vars gates.
        self.assertNotIn("github.event_name == 'workflow_dispatch' ||", workflow)
        self.assertIn("github.event.check_suite.pull_requests[0] != null", workflow)
        self.assertIn("runs-on: ubuntu-latest", workflow)
        self.assertIn("ref: main", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("checks: read", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("issues: write", workflow)
        self.assertIn("pull-requests: write", workflow)
        self.assertIn("scripts/factory-evidence-verify.py", workflow)
        self.assertNotIn("self-hosted", workflow)
        self.assertNotIn("CLAUDE_CODE_OAUTH_TOKEN", workflow)
        self.assertNotIn("APRIL_PRIVATE_KEY", workflow)


if __name__ == "__main__":
    unittest.main()
