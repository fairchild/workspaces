#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py==4.2.0"]
# ///
"""Policy tests for the factory CI-evidence verifier (#1120).

Intent: the verifier completes named-check evidence only from live check-run
state bound to the current head, never writes when the head moved, and clears
blocked:evidence only when it was machine-applied and everything is complete
and SHA-current.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
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
REVIEW_WORKFLOW = "factory-review.yml"
CHANGES_REQUESTED = "CHANGES_REQUESTED"
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
    """A body whose contract is derived from its entries -- the shape to avoid.

    Kept as a one-line wrapper over `body_with_contract` so the migration is
    visible rather than silent: anything still calling this is a fixture that
    cannot express a contract and an entries list disagreeing, which is where
    every defect of that family lives (#1778, round 10).
    """
    return body_with_contract([str(entry.get("item", "")) for entry in entries], entries)


def body_with_contract(
    contract: list[str],
    entries: list[dict[str, object]],
    *,
    lines: list[str] | None = None,
) -> str:
    """A body whose contract, metadata and visible lines are given SEPARATELY.

    `body_with_entries` derives all three from one list, so no fixture built
    with it can express an entry that disagrees with the contract -- a
    requirement deleted from the metadata, one added, one retargeted to
    another check, or a visible line that says something the metadata does
    not. Every defect of that shape was therefore unreachable by construction,
    which is why two of them shipped (#1778, round 8).

    Nothing here is derived from anything else: the contract is what the issue
    asked for, the entries are what the description records, and `lines`
    defaults to the entries' own rendering only so a caller that does not care
    can leave it out.
    """
    payload = json.dumps({"entries": entries}, indent=2, ensure_ascii=False)
    visible = "\n".join(
        lines
        if lines is not None
        else [f"- [{entry['status']}] {entry['item']} -- {entry['detail']}" for entry in entries]
    )
    requested = "\n".join(f"- {item}" for item in contract)
    return (
        "*Persona*\n\n## Summary\n- change\n\n"
        f"## Requested Evidence\n{requested}\n\n"
        f"<!-- evidence-status:v1\n{payload}\n-->\n\n"
        f"## Evidence Status\n{visible}\n\n"
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
    def test_every_ci_entry_needs_verification_whatever_it_records(self) -> None:
        # Entry 3 is the one this changed: `complete` and bound to the current
        # head used to be skipped, which is how a completion typed into the
        # block was never looked at again (#1778). The `diff` entry is still
        # not this lane's business.
        entries: list[object] = [
            ci_entry(index=1, status="pending-ci"),
            ci_entry(index=2, status="complete", verified_head_sha=OTHER_HEAD),
            ci_entry(index=3, status="complete", verified_head_sha=HEAD),
            {"index": 4, "item": DIFF_ITEM, "status": "pending-ci", "detail": "d"},
        ]

        self.assertEqual(
            verify.ci_entries_needing_verification(entries, HEAD),
            [(1, "Web CI"), (2, "Web CI"), (3, "Web CI")],
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
        # A `ci` entry counts only where THIS RUN verified it, so the clear
        # takes what the run concluded rather than what the body says (#1778).
        green = {1: {"status": "complete", "verified_head_sha": HEAD, "check_name": "Web CI"}}
        self.assertTrue(verify.should_clear_blocked_label(complete, HEAD, verified=green))
        # The same entries with nothing verified: the half of #1778 that let a
        # forged body clear its own label.
        self.assertFalse(verify.should_clear_blocked_label(complete, HEAD, verified={}))
        # A stale RECORDED sha with nothing verified stays refused, which is
        # the property this row was written for.
        stale = [ci_entry(index=1, status="complete", verified_head_sha=OTHER_HEAD)]
        self.assertFalse(verify.should_clear_blocked_label(stale, HEAD, verified={}))
        # With this run's own verification green on this head it clears, and
        # that is the change rather than an oversight: the verification is the
        # authority and the recorded sha is the forgeable field. In the flow
        # the updates are written into the body before this is asked, so the
        # two never disagree there; asked directly, the run wins.
        self.assertTrue(verify.should_clear_blocked_label(stale, HEAD, verified=green))
        self.assertFalse(
            verify.should_clear_blocked_label(
                [ci_entry(index=1, status="pending-ci")], HEAD, verified=green
            )
        )
        self.assertFalse(verify.should_clear_blocked_label([], HEAD, verified=green))
        self.assertFalse(verify.should_clear_blocked_label(None, HEAD, verified=green))
        # A body of non-`ci` entries needs nothing verified, because this lane
        # has no way to verify one -- the residual #1778 does not close.
        self.assertTrue(
            verify.should_clear_blocked_label(
                [{"index": 1, "item": DIFF_ITEM, "status": "complete", "detail": "d"}],
                HEAD,
                verified={},
            )
        )
        # And the recorded reading survives for the one question it is safe
        # for: whether this run changed anything.
        self.assertTrue(verify._recorded_contract_is_complete(complete, HEAD))

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


class AForgedCompletionIsUndoneByTheNextRunTests(unittest.TestCase):
    """A `complete` nothing verified is a claim, and the verifier now checks it (#1778).

    `ci_entries_needing_verification` skipped an entry already `complete` and
    bound to the current head, and `should_clear_blocked_label` read the
    entries AS RECORDED. Put together: anyone who can edit a pull request
    description could write `{"status": "complete", "verified_head_sha":
    "<head>"}` into a `ci` entry, and the next run of this lane looked at
    nothing, re-rendered the entry as complete, and removed the
    `blocked:evidence` label it had applied itself.

    Nothing about that needed a compromised token or a forged identity. The
    body is the record, the record is editable by anyone with write access to
    the pull request, and the lane trusted it about the one thing it exists to
    check.

    Re-verify rather than sign, which is the decision on the issue: one login
    covers many actors here, so a signature proves what the block's existence
    already proves. A `ci` entry is re-checked against the live check runs on
    every run instead.
    """

    def run_over(self, entries, *, runs, labels=("blocked:evidence",)):
        """`process_pr` over one body, reporting the body written and the gh commands."""
        body = body_with_entries(entries)
        pr = pr_payload(body, labels=list(labels))
        written: dict[str, str] = {}
        gh_calls: list[list[str]] = []

        def fake_gh_json(args, env):
            if any("pulls/321" in arg for arg in args):
                return pr
            return None

        with (
            mock.patch.object(verify, "_gh_json", side_effect=fake_gh_json),
            mock.patch.object(verify, "check_runs_for", return_value=runs),
            mock.patch.object(
                verify,
                "_write_pr_body",
                side_effect=lambda number, new_body, env: written.update(body=new_body) or True,
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})
        return written.get("body"), gh_calls

    @staticmethod
    def cleared(gh_calls) -> bool:
        return ["pr", "edit", "321", "--remove-label", "blocked:evidence"] in gh_calls

    FORGED = dict(status="complete", verified_head_sha=HEAD)
    FAILED_RUN = [
        {
            "status": "completed",
            "conclusion": "failure",
            "completed_at": "2026-08-27T00:00:00Z",
            "html_url": "https://example.invalid/run/9",
        }
    ]
    GREEN_RUN = [
        {
            "status": "completed",
            "conclusion": "success",
            "completed_at": "2026-08-27T00:00:00Z",
            "html_url": "https://example.invalid/run/1",
        }
    ]

    def test_a_forged_completion_whose_live_run_failed_is_returned_to_pending(self) -> None:
        # The headline. On `016d94ba` this body's entry is skipped, the label
        # is cleared, and the forged `[complete]` line survives the run.
        body, gh_calls = self.run_over([ci_entry(**self.FORGED)], runs=self.FAILED_RUN)
        self.assertIsNotNone(body, "the run wrote no body at all")
        self.assertIn(f"- [pending-ci] {CI_ITEM}", body)
        self.assertNotIn(f"- [complete] {CI_ITEM}", body)
        self.assertIn("concluded failure", body)
        self.assertIn("https://example.invalid/run/9", body)
        self.assertFalse(self.cleared(gh_calls), gh_calls)

    def test_a_forged_completion_naming_a_check_that_does_not_exist_is_undone(self) -> None:
        # The other way a forgery shows: an item naming a check nobody runs.
        # An answered query that came back empty is the case that says the
        # check does not exist, which is what `check_known` is for.
        body, gh_calls = self.run_over([ci_entry(**self.FORGED)], runs=[])
        self.assertIn(f"- [pending-ci] {CI_ITEM}", body)
        self.assertIn("may not match a check on this repository", body)
        self.assertFalse(self.cleared(gh_calls), gh_calls)

    def test_a_run_that_has_not_finished_says_nothing_and_writes_nothing(self) -> None:
        # An indefinite answer -- a check mid-re-run -- cannot unsay a
        # completion, so the entry keeps what it records and the body is not
        # rewritten (#1778, round 2). The forged line therefore survives this
        # run, and clears nothing: it is absent from what this run verified,
        # so the label stays. The next definite answer undoes it.
        body, gh_calls = self.run_over(
            [ci_entry(**self.FORGED)], runs=[{"status": "in_progress", "conclusion": None}]
        )
        self.assertIsNone(body, "an indefinite answer rewrote the body")
        self.assertFalse(self.cleared(gh_calls), gh_calls)

    def test_a_genuine_completion_stays_complete_and_still_clears_the_label(self) -> None:
        # The control, and the property that says the change costs an honest
        # body nothing: the same recorded entry, a green live run.
        body, gh_calls = self.run_over([ci_entry(**self.FORGED)], runs=self.GREEN_RUN)
        self.assertIn(f"- [complete] {CI_ITEM}", body)
        self.assertIn(f'"verified_head_sha": "{HEAD}"', body)
        self.assertIn("https://example.invalid/run/1", body)
        self.assertTrue(self.cleared(gh_calls), gh_calls)

    def test_an_honest_body_the_run_confirms_is_returned_byte_for_byte(self) -> None:
        """"Unchanged" asserted as BYTES, not as logical completion.

        The control above shows the entry is still complete and the label
        still clears, which is a claim about what the body MEANS. What an
        author notices is whether their description was rewritten, and that
        is a claim about its characters -- so it is asserted as characters
        (#1778, round 2).

        The entry here already records what this run confirms, detail and
        proof URL included, so the re-render reproduces the body it was given.
        """
        detail = f"`Web CI` green on head {HEAD[:12]} — https://example.invalid/run/1"
        entry = dict(
            ci_entry(status="complete", verified_head_sha=HEAD),
            detail=detail,
            check_name="Web CI",
            proof_url="https://example.invalid/run/1",
        )
        source = body_with_entries([entry])
        written: list[str] = []
        pr = pr_payload(source, labels=["blocked:evidence"])
        gh_calls: list[list[str]] = []
        with (
            mock.patch.object(
                verify,
                "_gh_json",
                side_effect=lambda args, env: pr if any("pulls/321" in a for a in args) else None,
            ),
            mock.patch.object(verify, "check_runs_for", return_value=self.GREEN_RUN),
            mock.patch.object(
                verify,
                "_write_pr_body",
                side_effect=lambda n, b, e: written.append(b) or True,
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})
        # The strongest form of "unchanged": the description is not written at
        # all, so not a character of the author's body moves.
        self.assertEqual(written, [], "an honest body was rewritten")
        self.assertTrue(self.cleared(gh_calls), gh_calls)
        # And the re-render of those entries is the body it was handed, which
        # is why nothing needed writing.
        self.assertEqual(
            verify.update_evidence_entries(source, {}),
            source,
        )

    def test_a_completion_is_re_read_even_when_the_recorded_sha_matches(self) -> None:
        # The condition that was doing the skipping, asserted directly rather
        # than only through the seam.
        entries = [ci_entry(**self.FORGED)]
        self.assertEqual(
            verify.ci_entries_needing_verification(entries, HEAD), [(1, "Web CI")]
        )
        # And an entry the lane cannot name a check for is still not its
        # business -- the fail-closed rule #1120 set, unchanged.
        self.assertEqual(
            verify.ci_entries_needing_verification(
                [{"index": 1, "item": "a screenshot of the sidebar", "status": "complete"}], HEAD
            ),
            [],
        )

    def test_the_clear_counts_what_this_run_verified_and_not_what_the_body_says(self) -> None:
        # The second half of the hole. Even with the entries re-verified, a
        # clear computed from the recorded entries would pass a body whose
        # `ci` entry this run never confirmed -- which is what happens when
        # the check-run lookup itself fails.
        entries = [ci_entry(**self.FORGED)]
        self.assertFalse(verify.should_clear_blocked_label(entries, HEAD, verified={}))
        self.assertTrue(
            verify.should_clear_blocked_label(
                entries,
                HEAD,
                verified={
                    1: {
                        "status": "complete",
                        "verified_head_sha": HEAD,
                        "check_name": "Web CI",
                    }
                },
            )
        )
        # A verdict for a DIFFERENT check does not count, however complete it
        # is: looked up by index alone, a decoy naming any green check cleared
        # the label on a red one (#1778, round 2).
        self.assertFalse(
            verify.should_clear_blocked_label(
                entries,
                HEAD,
                verified={
                    1: {"status": "complete", "verified_head_sha": HEAD, "check_name": "Docs"}
                },
            )
        )
        # A run that verified the entry and found it wanting does not clear.
        self.assertFalse(
            verify.should_clear_blocked_label(
                entries, HEAD, verified={1: {"status": "pending-ci", "check_name": "Web CI"}}
            )
        )

    def test_a_lookup_failure_leaves_the_body_and_the_label_alone(self) -> None:
        # `check_runs_for` returning None is a failed query, which says
        # nothing about the check -- so it neither clears the label nor
        # rewrites the entry. Demoting on it wrote `pending-ci` into the body
        # and made the NEXT run read a transition that had not happened
        # (#1778, round 2).
        body, gh_calls = self.run_over([ci_entry(**self.FORGED)], runs=None)
        self.assertIsNone(body, "a failed lookup rewrote the body")
        self.assertFalse(self.cleared(gh_calls), gh_calls)

    def test_an_entry_with_no_recorded_completion_is_still_written_on_an_indefinite_answer(
        self,
    ) -> None:
        # The rule protects a COMPLETION bound to this head, not every entry:
        # a `pending-ci` entry still gets the "waiting for checks" detail, so
        # an author can see the lane is watching it.
        body, gh_calls = self.run_over(
            [ci_entry(status="pending-ci")], runs=[{"status": "in_progress", "conclusion": None}]
        )
        self.assertIn(f"- [pending-ci] {CI_ITEM}", body)
        self.assertIn("waiting for checks", body)
        self.assertFalse(self.cleared(gh_calls), gh_calls)

    def test_a_correction_the_body_refuses_still_holds_the_label(self) -> None:
        """The case that makes the second half of the fix load-bearing.

        Re-verifying an entry is not enough on its own, because the
        correction has to be WRITTEN before the recorded entries say anything
        different -- and a write can stand down. A body whose
        `## Evidence Status` section is the last one and sits above a `<pre>`
        that never closes cannot be rewritten: the cut's far end is not
        something the body states, so the runtime refuses it and leaves the
        body byte-identical, forged `complete` metadata and all.

        On that body a clear computed from the recorded entries clears, even
        with the entry re-verified and found failing, because the recorded
        entry still says complete. A clear computed from what this run
        verified does not.
        """
        entry = dict(ci_entry(**self.FORGED), detail="forged")
        payload = json.dumps({"entries": [entry]}, indent=2, ensure_ascii=False)
        unwritable = (
            "*Persona*\n\n## Summary\n- change\n\n"
            f"<!-- evidence-status:v1\n{payload}\n-->\n\n"
            f"## Evidence Status\n- [complete] {CI_ITEM} -- forged\n\n"
            "<pre>\nnever closed\n\n"
            "Closes #99\n\n<!-- contributor:issue=99;agent=test -->"
        )
        pr = pr_payload(unwritable, labels=["blocked:evidence"])
        written: dict[str, str] = {}
        gh_calls: list[list[str]] = []
        with (
            mock.patch.object(
                verify, "_gh_json",
                side_effect=lambda args, env: pr if any("pulls/321" in a for a in args) else None,
            ),
            mock.patch.object(verify, "check_runs_for", return_value=self.FAILED_RUN),
            mock.patch.object(
                verify, "_write_pr_body",
                side_effect=lambda n, b, e: written.update(body=b) or True,
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})
        # The correction could not be written, so the record still says
        # complete -- and the label stays anyway.
        self.assertNotIn("body", written)
        self.assertFalse(self.cleared(gh_calls), gh_calls)
        # And the reading that used to decide it would have cleared.
        self.assertTrue(
            verify._recorded_contract_is_complete(verify.evidence_entries(unwritable), HEAD)
        )

    def test_one_check_run_read_per_ci_entry_per_run(self) -> None:
        # The cost, measured rather than asserted. Three `ci` entries, three
        # reads -- and the non-ci entry beside them costs nothing, because the
        # lane never had a way to verify it.
        entries = [
            ci_entry(index=1, **self.FORGED),
            ci_entry(index=2, **self.FORGED),
            ci_entry(index=3, **self.FORGED),
            {"index": 4, "item": "a screenshot of the sidebar", "status": "complete",
             "detail": "uploaded", "kind": "screenshot"},
        ]
        body = body_with_entries(entries)
        pr = pr_payload(body, labels=["blocked:evidence"])
        reads: list[tuple[str, str]] = []

        with (
            mock.patch.object(
                verify, "_gh_json",
                side_effect=lambda args, env: pr if any("pulls/321" in a for a in args) else None,
            ),
            mock.patch.object(
                verify, "check_runs_for",
                side_effect=lambda name, sha, env: reads.append((name, sha)) or self.GREEN_RUN,
            ),
            mock.patch.object(verify, "_write_pr_body", return_value=True),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(verify, "_gh", return_value=True),
        ):
            verify.process_pr(321, {})
        self.assertEqual(reads, [("Web CI", HEAD)] * 3)


class TheSuiteCanExpressASequenceTests(unittest.TestCase):
    """A two-run fixture, because the defects this round found have a time axis (#1778, round 2).

    Every other test in this file is one `process_pr` call on a fresh body,
    and every fixture assigns distinct indices and names one check through one
    constant. So a defect whose signature is "this run writes a body that
    makes the NEXT run behave wrongly" passed by construction, and one did:
    a transient lookup failure demoted a genuine completion, wrote it, and the
    run after read a transition that had not happened.

    `two_runs` feeds the body the first run wrote back into the second, which
    is what the workflow does on the next completed check suite.
    """

    GREEN = [
        {
            "status": "completed",
            "conclusion": "success",
            "completed_at": "2026-08-27T00:00:00Z",
            "html_url": "https://example.invalid/run/1",
        }
    ]
    REJECTION = [
        {
            "user": {"login": "workspace-agents[bot]"},
            "state": CHANGES_REQUESTED,
            "commit_id": HEAD,
            "submitted_at": "2026-08-27T01:00:00Z",
        }
    ]

    def one_run(self, body: str, runs, *, labels, reviews):
        """One `process_pr` over this body, reporting what it wrote and did."""
        pr = pr_payload(body, labels=list(labels))
        written: dict[str, str] = {}
        gh_calls: list[list[str]] = []

        def fake_gh_json(args, env):
            if any(arg.endswith("/reviews") for arg in args):
                return reviews
            if any("pulls/321" in arg for arg in args):
                return pr
            return None

        with (
            mock.patch.object(verify, "_gh_json", side_effect=fake_gh_json),
            mock.patch.object(
                verify, "check_runs_for", side_effect=lambda name, sha, env: runs(name)
            ),
            mock.patch.object(
                verify,
                "_write_pr_body",
                side_effect=lambda number, new_body, env: written.update(body=new_body) or True,
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})
        return written.get("body", body), gh_calls

    @staticmethod
    def dispatched(gh_calls) -> bool:
        return any(REVIEW_WORKFLOW in " ".join(args) for args in gh_calls)

    @staticmethod
    def cleared(gh_calls) -> bool:
        return ["pr", "edit", "321", "--remove-label", "blocked:evidence"] in gh_calls

    @staticmethod
    def cleared(gh_calls) -> bool:
        return ["pr", "edit", "321", "--remove-label", "blocked:evidence"] in gh_calls

    def two_runs(self, entries, first, second, *, labels=(), reviews=None):
        """Run, feed the written body AND the label state back, run again.

        The label state carries across because the workflow does: run 1 can
        remove `blocked:evidence`, and a run 2 that still saw it set was
        answering a question about a pull request that no longer exists
        (#1778, round 3).
        """
        body = body_with_entries(entries)
        carried = list(labels)
        body, first_calls = self.one_run(body, first, labels=carried, reviews=reviews or [])
        if ["pr", "edit", "321", "--remove-label", "blocked:evidence"] in first_calls:
            carried = [name for name in carried if name != "blocked:evidence"]
        body, second_calls = self.one_run(body, second, labels=carried, reviews=reviews or [])
        return body, first_calls, second_calls

    def test_the_second_run_sees_the_label_the_first_removed(self) -> None:
        # The fixture's own property, asserted so it cannot quietly stop
        # carrying: run 1 clears the label, run 2 is not asked to clear it
        # again because it is no longer there.
        forged = [ci_entry(status="complete", verified_head_sha=HEAD)]
        _, first, second = self.two_runs(
            forged, lambda name: self.GREEN, lambda name: self.GREEN,
            labels=["blocked:evidence"],
        )
        self.assertTrue(self.cleared(first), first)
        self.assertFalse(self.cleared(second), "run 2 cleared a label run 1 had removed")

    def test_a_transient_failure_does_not_make_the_next_run_see_a_transition(self) -> None:
        """The regression against main (#1778, round 2).

        A genuine completion, a lookup that fails, then a lookup that
        recovers. The first run used to demote the entry and write it, so the
        second read `was_complete=False, now_complete=True` and spent a slot
        of the review budget on a transition that never happened. On main
        both runs were no-ops.
        """
        genuine = [
            dict(
                ci_entry(status="complete", verified_head_sha=HEAD),
                detail="`Web CI` green on head aaaaaaaaaaaa",
                check_name="Web CI",
            )
        ]
        body, first, second = self.two_runs(
            genuine,
            lambda name: None,
            lambda name: self.GREEN,
            labels=[],
            reviews=self.REJECTION,
        )
        self.assertIn(f"- [complete] {CI_ITEM}", body)
        self.assertFalse(self.dispatched(first), first)
        self.assertFalse(
            self.dispatched(second), "the second run saw a transition the first invented"
        )

    def test_a_genuine_completion_re_verified_twice_stays_put(self) -> None:
        # The control on the same axis: two runs, both green, nothing moves
        # and no review is asked for.
        genuine = [
            dict(
                ci_entry(status="complete", verified_head_sha=HEAD),
                detail="`Web CI` green on head aaaaaaaaaaaa",
                check_name="Web CI",
            )
        ]
        body, first, second = self.two_runs(
            genuine,
            lambda name: self.GREEN,
            lambda name: self.GREEN,
            labels=[],
            reviews=self.REJECTION,
        )
        self.assertIn(f"- [complete] {CI_ITEM}", body)
        self.assertFalse(self.dispatched(first), first)
        self.assertFalse(self.dispatched(second), second)

    def test_a_definite_failure_still_undoes_a_forged_completion_across_two_runs(self) -> None:
        # The gap this pull request closes, on the time axis: the forged entry
        # is undone by the first definite answer and stays undone.
        forged = [ci_entry(status="complete", verified_head_sha=HEAD)]
        failed = [
            {
                "status": "completed",
                "conclusion": "failure",
                "completed_at": "2026-08-27T00:00:00Z",
                "html_url": "https://example.invalid/run/9",
            }
        ]
        body, first, second = self.two_runs(
            forged, lambda name: failed, lambda name: failed, labels=["blocked:evidence"]
        )
        self.assertIn(f"- [pending-ci] {CI_ITEM}", body)
        self.assertNotIn(f"- [complete] {CI_ITEM}", body)
        self.assertFalse(self.cleared(first), first)
        self.assertFalse(self.cleared(second), second)


class TwoEntriesAtOneIndexAreNotActedOnTests(unittest.TestCase):
    """A decoy entry reusing an index clears the label on a red check (#1778, round 2).

    No race and no forged status: a contract with one red required check and a
    second entry at the same index naming any green one, with the green entry
    written last. `should_clear_blocked_label` looked the verdict up by index
    alone and never compared it to the check the entry names, and `process_pr`
    handed the clear the unfiltered updates map while the write path narrowed
    it. The green verdict overwrote the red one at index 1 and cleared the
    label.

    Two entries at one index are two answers to one requirement, and which a
    verdict belongs to is decided by the order they happen to be written in.
    Neither is acted on.
    """

    RED_ITEM = CI_ITEM
    GREEN_ITEM = "CI: `Docs` green on the PR head"

    def entries(self):
        return [
            {
                "index": 1,
                "item": self.RED_ITEM,
                "status": "pending-ci",
                "detail": "waiting for checks",
                "kind": "ci",
            },
            {
                "index": 1,
                "item": self.GREEN_ITEM,
                "status": "pending-ci",
                "detail": "waiting for checks",
                "kind": "ci",
            },
        ]

    def test_the_decoy_contract_neither_verifies_nor_clears(self) -> None:
        body = body_with_entries(self.entries())
        pr = pr_payload(body, labels=["blocked:evidence"])
        reads: list[str] = []
        gh_calls: list[list[str]] = []
        written: dict[str, str] = {}

        def runs(name, sha, env):
            reads.append(name)
            conclusion = "failure" if name == "Web CI" else "success"
            return [
                {
                    "status": "completed",
                    "conclusion": conclusion,
                    "completed_at": "2026-08-27T00:00:00Z",
                    "html_url": "https://example.invalid/run/1",
                }
            ]

        with (
            mock.patch.object(
                verify,
                "_gh_json",
                side_effect=lambda args, env: pr if any("pulls/321" in a for a in args) else None,
            ),
            mock.patch.object(verify, "check_runs_for", side_effect=runs),
            mock.patch.object(
                verify,
                "_write_pr_body",
                side_effect=lambda n, b, e: written.update(body=b) or True,
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})

        self.assertNotIn(
            ["pr", "edit", "321", "--remove-label", "blocked:evidence"],
            gh_calls,
            "the label was cleared on a red required check",
        )
        self.assertEqual(reads, [], "a contract it cannot read was verified anyway")
        self.assertNotIn("body", written)

    def test_a_collision_of_any_kinds_is_named_rather_than_resolved(self) -> None:
        """Inverted from round 2, where this test asserted the defect (#1778, round 3).

        It read "a non-ci entry sharing an index is not this", which is how a
        mixed-kind index passed the guard and one green run manufactured a
        completion on a line no check covers. What is ambiguous is which entry
        the verdict belongs to; the kinds of the colliding entries change
        nothing about that.
        """
        self.assertEqual(verify.colliding_indexes(self.entries()), [1])
        # A `ci` entry and a non-`ci` entry at one index IS a collision --
        # the assertion this test used to make in reverse.
        self.assertEqual(
            verify.colliding_indexes(
                [ci_entry(index=1), ci_entry(index=2), {"index": 1, "item": DIFF_ITEM}]
            ),
            [1],
        )
        # Two non-`ci` entries at one index are one too.
        self.assertEqual(
            verify.colliding_indexes(
                [{"index": 3, "item": DIFF_ITEM}, {"index": 3, "item": "a screenshot"}]
            ),
            [3],
        )
        # Distinct indices are not, whatever the kinds.
        self.assertEqual(
            verify.colliding_indexes(
                [ci_entry(index=1), {"index": 2, "item": DIFF_ITEM}, {"index": 3, "item": "x"}]
            ),
            [],
        )

    def test_all_three_readers_take_one_definition_of_an_index(self) -> None:
        # The mechanism, asserted directly: the guard, the write's narrowing
        # and the clear read the same grouping, so none of them can be right
        # about an index while another is wrong.
        mixed = [
            ci_entry(index=1),
            {"index": 1, "item": DIFF_ITEM, "status": "pending-ci", "detail": "waiting"},
        ]
        self.assertEqual(sorted(verify.entries_by_index(mixed)), [1])
        self.assertEqual(len(verify.entries_by_index(mixed)[1]), 2)
        self.assertEqual(verify.colliding_indexes(mixed), [1])
        # An index more than one entry claims has no single check name, so the
        # write's narrowing drops its updates too.
        update = {1: {"status": "complete", "check_name": "Web CI"}}
        for label, order in (
            ("the non-ci entry last", mixed),
            # The order that matters: keyed on the LAST entry, this one hands
            # back the `ci` check name and the update lands on both lines.
            ("the ci entry last", list(reversed(mixed))),
        ):
            with self.subTest(order=label):
                self.assertEqual(
                    verify._updates_targeting_unchanged_entries(
                        body_with_entries(order), update
                    ),
                    {},
                    label,
                )
        # And an entry claiming no readable index is invisible to all three.
        self.assertIsNone(verify.usable_entry_index({"item": CI_ITEM}))
        self.assertIsNone(verify.usable_entry_index({"index": "1e9999"}))
        self.assertEqual(verify.colliding_indexes([{"item": CI_ITEM}, {"item": CI_ITEM}]), [])

    def test_a_verdict_for_another_check_never_counts(self) -> None:
        # The comparison on its own, since the duplicate guard stops the seam
        # test short of it: a verdict is the entry's only if it names the
        # entry's check.
        entries = [ci_entry(index=1, status="complete", verified_head_sha=HEAD)]
        for name, clears in (("Web CI", True), ("Docs", False), ("", False)):
            with self.subTest(check_name=name):
                self.assertEqual(
                    verify.should_clear_blocked_label(
                        entries,
                        HEAD,
                        verified={
                            1: {
                                "status": "complete",
                                "verified_head_sha": HEAD,
                                "check_name": name,
                            }
                        },
                    ),
                    clears,
                )

    def test_the_clear_takes_the_same_narrowed_map_the_write_takes(self) -> None:
        # An update whose target index no longer names the check it was
        # computed for does not land in the body, so it may not count toward
        # the clear either.
        body = body_with_entries([ci_entry(index=1, status="complete", verified_head_sha=HEAD)])
        stale = {1: {"status": "complete", "verified_head_sha": HEAD, "check_name": "Docs"}}
        self.assertEqual(verify._updates_targeting_unchanged_entries(body, stale), {})


class AMixedKindIndexManufacturesACompletionTests(unittest.TestCase):
    """One index carrying two kinds let a green run invent a completion (#1778, round 3; #1784).

    The round-2 guard counted `ci` entries only, so a `ci` entry and a
    non-`ci` entry at one index passed it — and `update_evidence_entries`
    applies `updates[index]` to EVERY entry at that index. One green `Web CI`
    run rewrote a `pending-ci` `diff` entry into a complete `ci` one bound to
    the head, and the label cleared. Both entries start `pending-ci`; nothing
    is typed by hand, and the shape is present on main.

    What made it reachable is that three readers disagreed about what an
    index is. They take one definition now.
    """

    GREEN = [
        {
            "status": "completed",
            "conclusion": "success",
            "completed_at": "2026-08-27T00:00:00Z",
            "html_url": "https://example.invalid/run/1",
        }
    ]
    CI = dict(ci_entry(index=1))
    DIFF = {"index": 1, "item": DIFF_ITEM, "status": "pending-ci", "detail": "waiting", "kind": "diff"}

    def run_over(self, entries):
        body = body_with_entries([dict(entry) for entry in entries])
        pr = pr_payload(body, labels=["blocked:evidence"])
        written: dict[str, str] = {}
        gh_calls: list[list[str]] = []
        reads: list[str] = []
        with (
            mock.patch.object(
                verify,
                "_gh_json",
                side_effect=lambda args, env: pr if any("pulls/321" in a for a in args) else None,
            ),
            mock.patch.object(
                verify, "check_runs_for", side_effect=lambda n, s, e: reads.append(n) or self.GREEN
            ),
            mock.patch.object(
                verify, "_write_pr_body", side_effect=lambda n, b, e: written.update(body=b) or True
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})
        return written.get("body"), gh_calls, reads

    ORDERS = (
        ("the non-ci entry last", "CI", "DIFF"),
        ("the ci entry last", "DIFF", "CI"),
    )

    def ordered(self, first: str, second: str) -> list[dict[str, object]]:
        return [getattr(self, first), getattr(self, second)]

    def test_neither_order_makes_a_check_run_read(self) -> None:
        """The pre-write guard's own signature, and the only one it owns.

        With the in-loop guard gone, what this guard is FOR is avoiding work:
        a contract the lane cannot read is not worth a check-run lookup. The
        WRITE is refused by the narrowing, so a test asserting "no body was
        written" passes with this guard deleted and is a test wearing the
        narrowing's name (#1778, round 4).

        So this fails by observing a read.
        """
        for label, first, second in self.ORDERS:
            with self.subTest(order=label):
                _, _, reads = self.run_over(self.ordered(first, second))
                self.assertEqual(reads, [], f"{label}: a check run was read for a contract it cannot read")

    def test_neither_order_writes_or_clears(self) -> None:
        # The outcome, which two guards hold between them: the pre-write one
        # stops the reads and the narrowing stops the write. Neither mutant
        # reddens this alone, and that is what it documents -- the property,
        # not the mechanism.
        for label, first, second in self.ORDERS:
            with self.subTest(order=label):
                body, gh_calls, _ = self.run_over(self.ordered(first, second))
                self.assertIsNone(body, f"{label}: a contract it cannot read was written")
                self.assertNotIn(
                    ["pr", "edit", "321", "--remove-label", "blocked:evidence"],
                    gh_calls,
                    f"{label}: the label was cleared",
                )

    def test_the_order_that_used_to_manufacture_one_is_the_ci_last_order(self) -> None:
        # Named so the record says which half was live: with the `ci` entry
        # last the narrowing kept the update and the write landed it on both
        # lines; with it first the narrowing dropped the update and only the
        # clear was at risk. Two halves of one path, not two guards.
        self.assertEqual(verify.colliding_indexes([self.DIFF, self.CI]), [1])
        self.assertEqual(verify.colliding_indexes([self.CI, self.DIFF]), [1])

    def test_an_honest_mixed_contract_at_distinct_indexes_is_untouched(self) -> None:
        # The control: two kinds are perfectly ordinary as long as each entry
        # has its own index.
        body, gh_calls, reads = self.run_over([self.CI, dict(self.DIFF, index=2)])
        self.assertEqual(reads, ["Web CI"])
        self.assertIsNotNone(body)
        self.assertIn("- [complete] ", body)


class TheNarrowingRefusesACollisionOnTheRetryReadTests(unittest.TestCase):
    """What refuses a collision that arrives mid-flight, named (#1778, round 4).

    `_apply_ci_updates` re-reads the live body on a retry — an owner edited
    the description between this run's read and its write — and re-applies
    the updates to whatever comes back. A twin entry injected there named the
    same check, so the narrowing kept the update and the write landed a
    `[complete]` on both lines.

    Round 5 moved the refusal into `update_evidence_entries` itself, so the
    OUTCOME below is now held by the writer and this test stays green with
    the narrowing broken; `test_all_three_readers_take_one_definition_of_an_index`
    is what fails then. The narrowing is kept because it keeps a stale
    verdict off an entry an owner RETARGETED, which is not a collision and
    which no refusal covers.

    `_updates_targeting_unchanged_entries` is what refuses it now: keyed on
    the one definition of an index, a colliding index has no single check
    name, so every update aimed at it is dropped and the loop returns the
    body untouched. Round 3 added a second guard inside the loop for the same
    condition and this test could not tell them apart — it went red only when
    both were broken. This test fails when the narrowing alone is broken,
    which is the isolation each guard owes; the in-loop guard has its own
    test now, on the case only it reaches (a collision at an index this run
    holds no update for), because round 4 read a surviving mutant as
    redundancy when it was a fixture the suite could not build (#1778,
    round 5):
    the pre-write guard is covered by `test_neither_order_makes_a_check_run_read`
    (which asserts no check-run READS, the thing only it can stop).
    """

    GREEN = [
        {
            "status": "completed",
            "conclusion": "success",
            "completed_at": "2026-08-27T00:00:00Z",
            "html_url": "https://example.invalid/run/1",
        }
    ]

    def test_the_narrowing_drops_every_update_aimed_at_the_injected_index(self) -> None:
        clean = body_with_entries([ci_entry(index=1)])
        injected = body_with_entries(
            [ci_entry(index=1), dict(ci_entry(index=1), detail="a second line the owner added")]
        )
        pr = pr_payload(clean, labels=["blocked:evidence"])
        reads = {"n": 0}
        written: dict[str, str] = {}
        gh_calls: list[list[str]] = []

        def fake_gh_json(args, env):
            if not any("pulls/321" in arg for arg in args):
                return None
            reads["n"] += 1
            # 1: `process_pr`'s own read, clean. 2 onward: the retry's read,
            # by which time the description carries the collision.
            pr["body"] = clean if reads["n"] == 1 else injected
            return pr

        with (
            mock.patch.object(verify, "_gh_json", side_effect=fake_gh_json),
            mock.patch.object(verify, "check_runs_for", return_value=self.GREEN),
            mock.patch.object(
                verify, "_write_pr_body", side_effect=lambda n, b, e: written.update(body=b) or True
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})

        self.assertNotIn("body", written, "a collision arriving mid-flight was written")
        self.assertNotIn(
            ["pr", "edit", "321", "--remove-label", "blocked:evidence"], gh_calls, gh_calls
        )

    def test_an_unchanged_body_on_the_retry_read_still_writes(self) -> None:
        # The control: the guard re-running must not stop an ordinary write.
        clean = body_with_entries([ci_entry(index=1)])
        pr = pr_payload(clean, labels=["blocked:evidence"])
        written: dict[str, str] = {}
        with (
            mock.patch.object(
                verify,
                "_gh_json",
                side_effect=lambda args, env: pr if any("pulls/321" in a for a in args) else None,
            ),
            mock.patch.object(verify, "check_runs_for", return_value=self.GREEN),
            mock.patch.object(
                verify, "_write_pr_body", side_effect=lambda n, b, e: written.update(body=b) or True
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(verify, "_gh", return_value=True),
        ):
            verify.process_pr(321, {})
        self.assertIn("- [complete] ", written.get("body", ""))


class TheInLoopGuardCoversWhatTheNarrowingCannotSeeTests(unittest.TestCase):
    """The case that made the in-loop guard look redundant, and was not (#1778, round 5).

    The writer is unconditionally dangerous: `update_evidence_entries` has no
    notion of a collision and applies `updates[index]` to EVERY entry carrying
    that index, so every safety property in this subsystem belongs to a
    caller, and it holds only while every caller refuses a collision on every
    body it hands in.

    The narrowing refuses a collision only at an index this run HOLDS an
    update for -- it works by dropping updates, so an index it holds none for
    is invisible to it. A run over `{1: ci pending-ci, 2: diff complete}`
    holds one update, for index 1; a twin injected at index 2 on the retry
    read reaches neither the pre-write guard (which had its turn on the first
    body) nor the narrowing (which has nothing to drop), and the run wrote the
    body and cleared the label with the collision standing.

    Round 4 deleted the in-loop guard because its mutant survived. A
    surviving mutant means the code is redundant OR the suite cannot reach
    the case it covers, and only the second was true: every collision fixture
    landed on the update's own index.
    """

    GREEN = [
        {
            "status": "completed",
            "conclusion": "success",
            "completed_at": "2026-08-27T00:00:00Z",
            "html_url": "https://example.invalid/run/1",
        }
    ]
    OTHER = {
        "index": 2,
        "item": DIFF_ITEM,
        "status": "complete",
        "detail": "the diff shows it",
        "kind": "diff",
    }

    def run_with_injection(self, injected_entries):
        clean = body_with_entries([ci_entry(index=1), dict(self.OTHER)])
        injected = body_with_entries(injected_entries)
        pr = pr_payload(clean, labels=["blocked:evidence"])
        reads = {"n": 0}
        written: dict[str, str] = {}
        gh_calls: list[list[str]] = []

        def fake_gh_json(args, env):
            if not any("pulls/321" in arg for arg in args):
                return None
            reads["n"] += 1
            # 1: `process_pr`'s own read, clean. 2 onward: the live read the
            # write path makes, by which time the owner's edit has landed.
            pr["body"] = clean if reads["n"] == 1 else injected
            return pr

        said = io.StringIO()
        with (
            contextlib.redirect_stderr(said),
            mock.patch.object(verify, "_gh_json", side_effect=fake_gh_json),
            mock.patch.object(verify, "check_runs_for", return_value=self.GREEN),
            mock.patch.object(
                verify, "_write_pr_body", side_effect=lambda n, b, e: written.update(body=b) or True
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})
        return written, gh_calls, said.getvalue()

    def test_a_collision_at_an_index_this_run_holds_no_update_for_is_not_written(self) -> None:
        """The outcome, which `update_evidence_entries` now holds on its own.

        This is the property, and after round 5's decision it is not this
        guard's signature: the writer refuses a colliding body itself, so this
        stays green with the in-loop guard deleted. It is kept as the
        end-to-end statement of what the run does, and the test below is what
        fails when only this guard is gone.
        """
        written, gh_calls, _ = self.run_with_injection(
            [
                ci_entry(index=1),
                dict(self.OTHER),
                dict(self.OTHER, detail="a second line the owner added at the same index"),
            ]
        )
        self.assertNotIn("body", written, "a body carrying a collision was written")
        self.assertNotIn(
            ["pr", "edit", "321", "--remove-label", "blocked:evidence"], gh_calls, gh_calls
        )

    def test_the_lane_names_the_collision_in_its_own_voice(self) -> None:
        """The in-loop guard's own signature, which is diagnosis (#1778, round 5).

        With the refusal in the writer, what this guard adds is the sentence
        an operator reads in the lane's log, naming the PR and the indexes,
        before a write attempt nobody needs. That is worth keeping and worth
        testing for what it is, rather than for a safety property it no longer
        owns alone.
        """
        _, _, said = self.run_with_injection(
            [
                ci_entry(index=1),
                dict(self.OTHER),
                dict(self.OTHER, detail="a second line the owner added at the same index"),
            ]
        )
        self.assertIn("PR #321: evidence entries share index(es) 2", said)

    def test_the_same_body_without_the_twin_is_written_as_before(self) -> None:
        # The control: the guard re-running refuses collisions, not edits.
        written, _, _ = self.run_with_injection(
            [ci_entry(index=1), dict(self.OTHER, detail="the owner reworded this")]
        )
        self.assertIn("- [complete] ", written.get("body", ""))


class AStoodDownWriteDecidesTheLabelOnTheLiveBodyTests(unittest.TestCase):
    """The live body was fetched and dropped (#1778, round 5; the stand-down half of #1786).

    `_apply_ci_updates` read the live PR to decide whether to say anything
    about a stand-down, then returned the body it STARTED from, and
    `process_pr` decided `blocked:evidence` on that. So an owner adding a
    requirement mid-run had the label taken off against a live body recording
    an unmet one -- this lane having fetched the truth and discarded it,
    which is worse than main's ignorance, not better.

    Every refused-write fixture before this one held the live body constant,
    so none of them could see it.
    """

    GREEN = [
        {
            "status": "completed",
            "conclusion": "success",
            "completed_at": "2026-08-27T00:00:00Z",
            "html_url": "https://example.invalid/run/1",
        }
    ]

    def settled_entry(self) -> dict[str, object]:
        """An entry already recording exactly what a green run confirms.

        Which is what makes the write a stand-down: the re-render reproduces
        the body it was handed, so `new_body == body` and the loop returns
        before it writes anything.
        """
        return dict(
            ci_entry(index=1, status="complete", verified_head_sha=HEAD),
            detail=f"`Web CI` green on head {HEAD[:12]} — https://example.invalid/run/1",
            check_name="Web CI",
            proof_url="https://example.invalid/run/1",
        )

    def test_a_requirement_added_mid_run_keeps_the_label(self) -> None:
        settled = body_with_entries([self.settled_entry()])
        # What the owner has since added, live on the PR.
        live = body_with_entries(
            [
                self.settled_entry(),
                {
                    "index": 2,
                    "item": DIFF_ITEM,
                    "status": "pending-ci",
                    "detail": "waiting on the owner",
                    "kind": "diff",
                },
            ]
        )
        pr = pr_payload(settled, labels=["blocked:evidence"])
        reads = {"n": 0}
        gh_calls: list[list[str]] = []
        written: list[str] = []

        def fake_gh_json(args, env):
            if not any("pulls/321" in arg for arg in args):
                return None
            reads["n"] += 1
            pr["body"] = settled if reads["n"] == 1 else live
            return pr

        with (
            mock.patch.object(verify, "_gh_json", side_effect=fake_gh_json),
            mock.patch.object(verify, "check_runs_for", return_value=self.GREEN),
            mock.patch.object(
                verify, "_write_pr_body", side_effect=lambda n, b, e: written.append(b) or True
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})

        self.assertGreater(reads["n"], 1, "the live body was never read")
        self.assertEqual(written, [], "this is the stand-down path; nothing should be written")
        self.assertNotIn(
            ["pr", "edit", "321", "--remove-label", "blocked:evidence"],
            gh_calls,
            "the label was cleared against a live body recording an unmet requirement",
        )

    def run_with_live(self, live_body: str | None, *, live_head: str = HEAD):
        """One run whose second PR read answers differently from its first."""
        settled = body_with_entries([self.settled_entry()])
        pr = pr_payload(settled, labels=["blocked:evidence"])
        reads = {"n": 0}
        gh_calls: list[list[str]] = []
        written: list[str] = []

        def fake_gh_json(args, env):
            if not any("pulls/321" in arg for arg in args):
                return None
            reads["n"] += 1
            if reads["n"] > 1:
                pr["body"] = settled if live_body is None else live_body
                pr["head"] = {"sha": live_head}
            return pr

        with (
            mock.patch.object(verify, "_gh_json", side_effect=fake_gh_json),
            mock.patch.object(verify, "check_runs_for", return_value=self.GREEN),
            mock.patch.object(
                verify, "_write_pr_body", side_effect=lambda n, b, e: written.append(b) or True
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})
        return reads["n"], written, gh_calls

    def cleared(self, gh_calls) -> bool:
        return ["pr", "edit", "321", "--remove-label", "blocked:evidence"] in gh_calls

    def test_an_emptied_description_is_a_body_rather_than_a_failed_read(self) -> None:
        """An owner deleting their description mid-run (#1778, round 7).

        `current_body or body` read an empty live body as a read that told us
        nothing and fell back to the copy this run started from -- so the
        clear was decided on a body the PR no longer has, and the label came
        off a description with no contract in it at all.
        """
        reads, written, gh_calls = self.run_with_live("")
        self.assertGreater(reads, 1, "the live body was never read")
        self.assertEqual(written, [], "this is the stand-down path")
        self.assertFalse(self.cleared(gh_calls), "the label was cleared against an empty body")

    def test_a_head_that_moved_mid_run_takes_no_decision_at_all(self) -> None:
        """The byte-identical stand-down returned BEFORE the head check.

        So a push between this run's read and its write had the label decided
        on the body from before the push -- the conclusions belong to a commit
        the pull request has left.
        """
        reads, written, gh_calls = self.run_with_live(None, live_head="b" * 40)
        self.assertGreater(reads, 1)
        self.assertEqual(written, [])
        self.assertFalse(self.cleared(gh_calls), "the label was cleared after the head moved")

    def test_a_live_body_that_still_says_complete_still_clears(self) -> None:
        # The control: reading the live body is not a reason to stop clearing.
        settled = body_with_entries([self.settled_entry()])
        pr = pr_payload(settled, labels=["blocked:evidence"])
        gh_calls: list[list[str]] = []
        with (
            mock.patch.object(
                verify,
                "_gh_json",
                side_effect=lambda args, env: pr if any("pulls/321" in a for a in args) else None,
            ),
            mock.patch.object(verify, "check_runs_for", return_value=self.GREEN),
            mock.patch.object(verify, "_write_pr_body", return_value=True),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})
        self.assertIn(["pr", "edit", "321", "--remove-label", "blocked:evidence"], gh_calls)


class TheClearRefusesACollidingIndexTooTests(unittest.TestCase):
    """One definition of an index, two definitions of which entries COUNT (#1778, round 5).

    Round 3 widened the duplicate guard to any kind. `should_clear_blocked_label`
    did not widen with it: it skips a non-`ci` entry BEFORE it ever reads an
    index, so two complete non-`ci` entries at one index answered "every entry
    complete, no ci entry unverified" and the label came off -- zero check-run
    reads, no write, and a clear on a contract no reader can tell apart.
    """

    TWIN = {
        "index": 1,
        "item": DIFF_ITEM,
        "status": "complete",
        "detail": "the diff shows it",
        "kind": "diff",
    }

    def test_two_complete_non_ci_entries_at_one_index_keep_the_label(self) -> None:
        entries = [dict(self.TWIN), dict(self.TWIN, detail="and the owner said so again")]
        self.assertEqual(verify.colliding_indexes(entries), [1])
        self.assertFalse(verify.should_clear_blocked_label(entries, HEAD, verified={}))

    def test_the_same_two_entries_at_distinct_indexes_still_clear(self) -> None:
        entries = [dict(self.TWIN), dict(self.TWIN, index=2)]
        self.assertEqual(verify.colliding_indexes(entries), [])
        self.assertTrue(verify.should_clear_blocked_label(entries, HEAD, verified={}))


class OneRuleForWhichIndexAnythingCanActOnTests(unittest.TestCase):
    """Three validity rules over one field, reduced to two named ones (#1778, round 7).

    The identity rule answers what an entry CLAIMS -- any integer, so
    two entries at index 0 are a collision the write must refuse. Whether
    anything can ACT on the claim is a second question with one answer: an
    index numbers a line in a rendered list and the first is 1. This lane
    looked up a check for an index-0 entry while the review-response lane told
    the author about none, which is one contract read two ways.
    """

    def identity(self):
        """The private identity rule, reached the way an acting site would have to.

        It lives beside its one caller behind an underscore now, so this test
        names where it is rather than pretending it is part of the surface
        (#1778, round 8).
        """
        return sys.modules["evidence"]._claimed_index

    def test_an_index_below_one_is_claimed_but_not_actionable(self) -> None:
        for index in (0, -1):
            with self.subTest(index=index):
                entry = {"index": index, "item": CI_ITEM, "status": "pending-ci", "detail": "d"}
                self.assertEqual(self.identity()(entry), index)
                self.assertIsNone(verify.usable_entry_index(entry))

    def test_the_verifier_looks_up_no_check_for_a_line_nothing_renders(self) -> None:
        for index in (0, -2):
            with self.subTest(index=index):
                entries = [{"index": index, "item": CI_ITEM, "status": "pending-ci", "detail": "d"}]
                self.assertEqual(verify.ci_entries_needing_verification(entries, HEAD), [])

    def test_the_response_lane_takes_the_same_definition(self) -> None:
        response = load_module(
            "factory_review_response_indexes", REPO_ROOT / "scripts" / "factory-review-response.py"
        )
        self.assertIs(response._entry_index, verify.usable_entry_index)
        for index in (0, -1):
            self.assertIsNone(response._entry_index({"index": index}))
        self.assertEqual(response._entry_index({"index": 2}), 2)

    def test_a_collision_below_one_is_still_a_collision(self) -> None:
        # The identity rule stays wide: the write fans `updates[0]` across
        # every entry claiming 0, so the guard has to see two of them.
        entries = [
            {"index": 0, "item": CI_ITEM, "status": "pending-ci", "detail": "d"},
            {"index": 0, "item": DIFF_ITEM, "status": "pending-ci", "detail": "d"},
        ]
        self.assertEqual(verify.colliding_indexes(entries), [0])


class ADecisionIsTakenOnWhatThePullRequestHoldsNowTests(unittest.TestCase):
    """Every return in the write loop hands back a body the label is decided on (#1778, round 8).

    Round 7 moved the live body's extraction above two of the returns. The
    narrowing's own return sat above the READ, so an owner retargeting the one
    `ci` entry mid-run had `blocked:evidence` cleared after two pull request
    reads, zero check-run verifications and zero writes -- this lane deciding
    on a body the pull request no longer has.

    Driven through the builder that can express a contract and an entries list
    disagreeing, which is the fixture shape every defect of this kind lives in.
    """

    GREEN = [
        {
            "status": "completed",
            "conclusion": "success",
            "completed_at": "2026-08-27T00:00:00Z",
            "html_url": "https://example.invalid/run/1",
        }
    ]
    OTHER_CHECK = "CI: `macOS CI` green on the PR head"

    def run_over(self, first: str, live: str):
        pr = pr_payload(first, labels=["blocked:evidence"])
        reads = {"n": 0}
        gh_calls: list[list[str]] = []
        written: list[str] = []

        def fake_gh_json(args, env):
            if not any("pulls/321" in arg for arg in args):
                return None
            reads["n"] += 1
            pr["body"] = first if reads["n"] == 1 else live
            return pr

        with (
            mock.patch.object(verify, "_gh_json", side_effect=fake_gh_json),
            mock.patch.object(verify, "check_runs_for", return_value=self.GREEN),
            mock.patch.object(
                verify, "_write_pr_body", side_effect=lambda n, b, e: written.append(b) or True
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})
        return reads["n"], written, gh_calls

    def cleared(self, gh_calls) -> bool:
        return ["pr", "edit", "321", "--remove-label", "blocked:evidence"] in gh_calls

    def settled(self, item: str = CI_ITEM) -> dict[str, object]:
        """An entry already recording what a green `Web CI` run confirms."""
        return dict(
            ci_entry(index=1, status="complete", verified_head_sha=HEAD),
            item=item,
            detail=f"`Web CI` green on head {HEAD[:12]} — https://example.invalid/run/1",
            check_name="Web CI",
            proof_url="https://example.invalid/run/1",
        )

    def test_an_entry_retargeted_mid_run_keeps_the_label(self) -> None:
        # The run verifies `Web CI` green and would clear on the body it read
        # first. Mid-run the owner retargets that one entry to another check,
        # which this run has verified nothing about -- so the update is
        # dropped, nothing is written, and the label must be decided on what
        # the pull request holds now.
        contract = [CI_ITEM]
        first = body_with_contract(contract, [self.settled()])
        live = body_with_contract(contract, [dict(self.settled(item=self.OTHER_CHECK))])
        reads, written, gh_calls = self.run_over(first, live)
        self.assertGreater(reads, 1, "the live body was never read")
        self.assertEqual(written, [], "an update for a check the entry no longer names was written")
        self.assertFalse(
            self.cleared(gh_calls),
            "the label was cleared on a body whose one requirement this run never verified",
        )

    def test_the_same_contract_unchanged_still_clears(self) -> None:
        # The control: reading the live body is not a reason to stop clearing.
        contract = [CI_ITEM]
        settled = body_with_contract(
            contract,
            [
                dict(
                    ci_entry(index=1, status="complete", verified_head_sha=HEAD),
                    detail=f"`Web CI` green on head {HEAD[:12]} — https://example.invalid/run/1",
                    check_name="Web CI",
                    proof_url="https://example.invalid/run/1",
                )
            ],
        )
        reads, written, gh_calls = self.run_over(settled, settled)
        self.assertEqual(written, [])
        self.assertTrue(self.cleared(gh_calls), gh_calls)

    def test_a_head_that_moves_on_the_retry_path_takes_no_decision(self) -> None:
        """The ordering that reached the head check below a return (#1778, round 8).

        Read, and the owner retargets the one `ci` entry: the body changed at
        the same head, so the loop takes the live body and tries again. The
        owner then pushes. On the second read the head has moved AND the
        narrowing drops every update — and that return handed the caller a
        body to decide `blocked:evidence` on, at a head this run verified
        nothing about, while this function's own rule is that a moved head is
        no decision at all.

        The head check sits directly after the read now, above every return.
        """
        contract = [CI_ITEM]
        # Unverified to begin with, so the first attempt has a write to make
        # and the loop can reach a second one.
        first = body_with_contract(contract, [ci_entry(index=1)])
        # Retargeted to a kind this lane cannot verify and records as
        # complete, which is what makes the clear reachable: a `ci` entry
        # pointed at another check is never counted complete without a
        # verification, so it could not show the defect.
        retargeted = body_with_contract(
            contract,
            [
                {
                    "index": 1,
                    "item": DIFF_ITEM,
                    "status": "complete",
                    "detail": "the diff shows it",
                    "kind": "diff",
                }
            ],
        )
        pr = pr_payload(first, labels=["blocked:evidence"])
        reads = {"n": 0}
        gh_calls: list[list[str]] = []
        written: list[str] = []

        def fake_gh_json(args, env):
            if not any("pulls/321" in arg for arg in args):
                return None
            reads["n"] += 1
            if reads["n"] == 1:
                pr["body"], pr["head"] = first, {"sha": HEAD}
            elif reads["n"] == 2:
                # The retarget, at the head this run is about: the body
                # changed, so the loop takes it and tries again.
                pr["body"], pr["head"] = retargeted, {"sha": HEAD}
            else:
                # And then the owner pushes. On this attempt the narrowing
                # has nothing left to apply AND the head has moved.
                pr["body"], pr["head"] = retargeted, {"sha": "b" * 40}
            return pr

        with (
            mock.patch.object(verify, "_gh_json", side_effect=fake_gh_json),
            mock.patch.object(verify, "check_runs_for", return_value=self.GREEN),
            mock.patch.object(
                verify, "_write_pr_body", side_effect=lambda n, b, e: written.append(b) or True
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})

        self.assertGreaterEqual(reads["n"], 3, "the run never reached the moved head")
        self.assertEqual(gh_calls, [], "a label was touched at a head this run never verified")

    def test_the_narrowings_return_hands_back_this_read_and_not_the_previous_one(self) -> None:
        """Two owner edits across the retry reads (#1778, round 9).

        Round 8 said this could not be constructed, because on a retry the
        body in hand was already a live read. It was -- the PREVIOUS one. The
        ordering that separates them needs a second edit:

        - read 0 records a pending `ci` entry at 1, so the run has a write to
          make;
        - the owner retargets index 1 to a complete `diff` entry, so read 1
          differs at the same head and the loop takes it and retries;
        - the owner then adds a second `pending-ci` `ci` entry at index 2;
        - read 2 sees that body, and the narrowing -- asked about read 1's
          body, where nothing this run concluded still applies -- returns.

        Handing back the body in hand means handing back read 1, whose one
        entry is complete, and the label comes off a pull request that now
        records an unmet requirement. Handing back the live body means
        handing back read 2, and it stays.
        """
        contract = [CI_ITEM]
        retargeted = {
            "index": 1,
            "item": DIFF_ITEM,
            "status": "complete",
            "detail": "the diff shows it",
            "kind": "diff",
        }
        added = {
            "index": 2,
            "item": "CI: `Other CI` green on the PR head",
            "status": "pending-ci",
            "detail": "waiting",
            "kind": "ci",
        }
        first = body_with_contract(contract, [ci_entry(index=1)])
        after_retarget = body_with_contract(contract, [retargeted])
        after_addition = body_with_contract(contract, [retargeted, added])
        pr = pr_payload(first, labels=["blocked:evidence"])
        reads = {"n": 0}
        gh_calls: list[list[str]] = []
        written: list[str] = []

        def fake_gh_json(args, env):
            if not any("pulls/321" in arg for arg in args):
                return None
            reads["n"] += 1
            pr["head"] = {"sha": HEAD}
            pr["body"] = (
                first
                if reads["n"] == 1
                else after_retarget
                if reads["n"] == 2
                else after_addition
            )
            return pr

        with (
            mock.patch.object(verify, "_gh_json", side_effect=fake_gh_json),
            mock.patch.object(verify, "check_runs_for", return_value=self.GREEN),
            mock.patch.object(
                verify, "_write_pr_body", side_effect=lambda n, b, e: written.append(b) or True
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})

        self.assertGreaterEqual(reads["n"], 3, "the run never reached the second edit")
        self.assertEqual(written, [], "an update nothing in hand still applies to was written")
        self.assertFalse(
            self.cleared(gh_calls),
            "the label was cleared on the read BEFORE the one this return was taken from",
        )

    def test_the_collision_return_hands_back_this_read_too(self) -> None:
        """The one return round 9's property did not pin (#1778, round 10).

        The collision branch returns the live body like every other return,
        and it looked unpinnable because a colliding body never clears
        anyway — the clear refuses a colliding index of its own accord. The
        two answers separate when the collision is in the body IN HAND and
        the pull request has since been FIXED:

        - read 0 records a pending `ci` entry, so the run has a write to make;
        - the owner gives two entries one index, so the retry takes that body;
        - the owner then fixes it, leaving one complete `diff` entry;
        - the next attempt's collision check fires on the body in hand and
          returns.

        Returning the live body decides on the fixed contract and the label
        comes off; returning the body in hand decides on the collision and it
        stays. Measured both ways in a disposable worktree: cleared here, not
        cleared under the mutant.
        """
        diff_complete = {
            "index": 1,
            "item": DIFF_ITEM,
            "status": "complete",
            "detail": "the diff shows it",
            "kind": "diff",
        }
        colliding = body_with_contract(
            [CI_ITEM], [self.settled(), diff_complete]
        )
        fixed = body_with_contract([CI_ITEM], [diff_complete])
        first = body_with_contract([CI_ITEM], [ci_entry(index=1)])
        pr = pr_payload(first, labels=["blocked:evidence"])
        reads = {"n": 0}
        gh_calls: list[list[str]] = []
        written: list[str] = []

        def fake_gh_json(args, env):
            if not any("pulls/321" in arg for arg in args):
                return None
            reads["n"] += 1
            pr["head"] = {"sha": HEAD}
            pr["body"] = (
                first if reads["n"] == 1 else colliding if reads["n"] == 2 else fixed
            )
            return pr

        with (
            mock.patch.object(verify, "_gh_json", side_effect=fake_gh_json),
            mock.patch.object(verify, "check_runs_for", return_value=self.GREEN),
            mock.patch.object(
                verify, "_write_pr_body", side_effect=lambda n, b, e: written.append(b) or True
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(
                verify, "_gh", side_effect=lambda args, env: gh_calls.append(args) or True
            ),
        ):
            verify.process_pr(321, {})

        self.assertGreaterEqual(reads["n"], 3, "the run never reached the fixed contract")
        self.assertTrue(
            self.cleared(gh_calls),
            "the label was decided on the colliding body rather than on what the PR holds",
        )

    def test_a_requirement_deleted_from_the_metadata_is_not_seen_here(self) -> None:
        """What the clear quantifies over, asserted rather than assumed.

        The verifier reads the description's metadata and never the contract,
        so a `pending-ci` entry deleted from the metadata is a requirement
        this gate cannot see -- the clear reads what survives. That is #1783's
        family, it is identical on main, and it is named in the docstring and
        the body rather than fixed here.
        """
        contract = [CI_ITEM, DIFF_ITEM]
        deleted = body_with_contract(
            contract,
            [
                dict(
                    ci_entry(index=1, status="complete", verified_head_sha=HEAD),
                    detail=f"`Web CI` green on head {HEAD[:12]} — https://example.invalid/run/1",
                    check_name="Web CI",
                    proof_url="https://example.invalid/run/1",
                )
            ],
        )
        self.assertIn(DIFF_ITEM, deleted, "the contract still asks for it")
        self.assertNotIn(
            DIFF_ITEM,
            json.dumps(verify.evidence_entries(deleted)),
            "the metadata no longer records it",
        )
        _, _, gh_calls = self.run_over(deleted, deleted)
        self.assertTrue(
            self.cleared(gh_calls),
            "documented, not desired: the clear reads the metadata and a deleted entry is "
            "invisible to it",
        )


class TheIdentityRuleIsNotReachableFromASiteThatActsTests(unittest.TestCase):
    """The criterion decides in code, and the static test is the second line (#1778, round 8).

    The apply loop asked the IDENTITY rule while acting, so an `{"index": 0}`
    entry had its hidden metadata flipped to complete while the line a reader
    sees stayed `[pending-ci]` -- body changed, nothing announced. Two rules
    over one field is right; applying the wrong one at a site that acts is
    what a name an acting site can reach by habit invites.

    The rule lives behind an underscore beside its one caller now, so reaching
    it from an acting site means reaching past a visible boundary into another
    module. That is the property; the test below names the intent.
    """

    def test_an_acting_site_reads_no_key_it_has_not_checked(self) -> None:
        """The property, not the private name (#1778, round 10).

        `entries_by_index` is public and applies the IDENTITY rule, and the
        verifier imports it — so a guard that greps for `_claimed_index` says
        nothing about a future acting use of the public grouping. The property
        is that a key an acting site reads out of that grouping has been
        through `usable_entry_index` first.

        Asked of behaviour rather than of text: the grouping is handed entries
        whose indexes nothing can act on, and every acting seam is driven over
        the same body. None of them may touch those entries.
        """
        evidence = sys.modules["evidence"]
        unusable = [
            {"index": value, "item": CI_ITEM, "status": "complete", "detail": "d", "kind": "ci"}
            for value in (0, -1, True, 1.0, "1")
        ]
        # The identity rule still groups the ones it can read -- that is what
        # it is for, since two entries at one unusable index are still a
        # collision. It reads 0 and -1 and rejects `True`, `1.0` and `"1"`,
        # because an index is an int and a bool is not one.
        self.assertEqual(sorted(evidence.entries_by_index(unusable)), [-1, 0])
        # And no acting seam takes one.
        self.assertEqual(verify.ci_entries_needing_verification(unusable, HEAD), [])
        self.assertFalse(verify.should_clear_blocked_label(unusable, HEAD, verified={}))
        body = body_with_contract([CI_ITEM], unusable)
        self.assertEqual(
            evidence.update_evidence_entries(body, {0: {"status": "complete", "detail": "x"}}),
            body,
            "the write acted on an index nothing renders",
        )

    def test_no_module_that_acts_imports_the_identity_rule(self) -> None:
        tracked = subprocess.run(
            ["git", "ls-files", "*.py"],
            cwd=REPO_ROOT, capture_output=True, text=True, check=True,
        ).stdout.split()
        self.assertGreater(len(tracked), 50, "the enumeration found almost nothing")
        reaching = {
            f"{path}:{number}"
            for path in tracked
            if not path.startswith("scripts/tests/")
            and path != ".agents/skills/cofounder-contributor/scripts/evidence.py"
            for number, line in enumerate(
                (REPO_ROOT / path).read_text(encoding="utf-8").splitlines(), 1
            )
            if "_claimed_index" in line
        }
        self.assertEqual(reaching, set(), "an acting site reached past the boundary")

    def test_the_only_caller_of_the_identity_rule_is_the_collision_grouping(self) -> None:
        evidence = sys.modules["evidence"]
        source = Path(evidence.__file__).read_text(encoding="utf-8")
        callers = [
            line.strip()
            for line in source.splitlines()
            if "_claimed_index(" in line and not line.strip().startswith("def ")
        ]
        self.assertEqual(len(callers), 2, callers)
        self.assertTrue(all("index = _claimed_index(entry)" in line for line in callers), callers)

    def test_an_index_nothing_renders_is_not_acted_on(self) -> None:
        evidence = sys.modules["evidence"]
        entry = {"index": 0, "item": "release approval", "status": "pending-ci",
                 "detail": "waiting", "kind": "manual"}
        # `lines=` given explicitly, because the visible line IS the thing
        # under test here: the defect was the metadata moving to complete
        # while this line stayed as it is (#1778, round 10).
        body = body_with_contract(
            ["release approval"],
            [entry],
            lines=["- [pending-ci] release approval -- waiting"],
        )
        said: list[str] = []
        written = evidence.update_evidence_entries(
            body, {0: {"status": "complete", "detail": "done"}}, announcements=said
        )
        self.assertEqual(written, body, "the metadata moved while the visible line did not")

    def test_a_visible_line_disagreeing_with_its_metadata_is_expressible(self) -> None:
        """What `lines=` is for, demonstrated rather than claimed (#1778, round 10).

        `body_with_entries` derives the visible line FROM the entry, so a body
        whose page says one thing and whose metadata says another was not a
        fixture this suite could write — and that disagreement is the shape
        the lane's defects keep taking. Here the metadata records a complete
        `ci` entry while the line a reader sees still says `pending-ci`, which
        is what an owner's hand edit to the block leaves behind.
        """
        recorded = dict(
            ci_entry(index=1, status="complete", verified_head_sha=HEAD),
            detail=f"`Web CI` green on head {HEAD[:12]} — https://example.invalid/run/1",
            check_name="Web CI",
            proof_url="https://example.invalid/run/1",
        )
        body = body_with_contract(
            [CI_ITEM],
            [recorded],
            lines=[f"- [pending-ci] {CI_ITEM} -- waiting for checks"],
        )
        self.assertIn('"status": "complete"', body, "the metadata says complete")
        self.assertIn("- [pending-ci]", body, "the page says pending")
        self.assertNotIn("- [complete]", body)
        # And the lane reads the metadata, which is the thing worth knowing:
        # the clear counts what the block records, not what the page shows.
        self.assertTrue(
            verify.should_clear_blocked_label(
                verify.evidence_entries(body),
                HEAD,
                verified={
                    1: {
                        "status": "complete",
                        "verified_head_sha": HEAD,
                        "check_name": "Web CI",
                    }
                },
            )
        )

    def test_no_entry_that_renders_no_line_counts_toward_a_clear(self) -> None:
        """An index nothing can act on is a requirement with nothing on the page.

        The int-only rule went in for the acting path and stopped at the kind
        check in the clear, which asks for an index only after deciding an
        entry is `ci`. So a complete `diff` entry at `true`, `1.0`, `"1"`,
        `0`, `-1` or `null` took `blocked:evidence` off on its own, with no
        line anywhere for the requirement it claimed to satisfy (#1778,
        round 10).
        """
        for value in (True, 1.0, "1", 0, -1, None, "1\n<!--"):
            with self.subTest(index=value):
                entry = {
                    "index": value,
                    "item": DIFF_ITEM,
                    "status": "complete",
                    "detail": "the diff shows it",
                    "kind": "diff",
                }
                self.assertIsNone(verify.usable_entry_index(entry), "the premise")
                self.assertFalse(
                    verify.should_clear_blocked_label([entry], HEAD, verified={}),
                    f"index {value!r} cleared the label with no line on the page",
                )
        # The control: the same entry at an index that renders still clears.
        self.assertTrue(
            verify.should_clear_blocked_label(
                [
                    {
                        "index": 1,
                        "item": DIFF_ITEM,
                        "status": "complete",
                        "detail": "the diff shows it",
                        "kind": "diff",
                    }
                ],
                HEAD,
                verified={},
            )
        )

    def test_a_float_and_a_bool_are_not_indexes(self) -> None:
        evidence = sys.modules["evidence"]
        for value in (1.9, 1.0, True, False, "1"):
            with self.subTest(index=value):
                self.assertIsNone(evidence._claimed_index({"index": value}), value)
                self.assertIsNone(evidence.usable_entry_index({"index": value}), value)
        self.assertEqual(evidence._claimed_index({"index": 1}), 1)


class VerdictDefinitenessTests(unittest.TestCase):
    """Which lookups say something about a check, and which fail to (#1778, round 2)."""

    def test_a_completed_run_and_an_empty_answer_are_definite(self) -> None:
        self.assertTrue(
            verify.verdict_is_definite(
                [{"status": "completed", "conclusion": "failure", "completed_at": "x"}]
            )
        )
        # An answered query that came back empty says the check does not exist.
        self.assertTrue(verdict := verify.verdict_is_definite([]))
        self.assertTrue(verdict)

    def test_a_failed_lookup_and_an_unfinished_run_are_not(self) -> None:
        self.assertFalse(verify.verdict_is_definite(None))
        self.assertFalse(
            verify.verdict_is_definite([{"status": "in_progress", "conclusion": None}])
        )


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

        # The entry is re-verified now, green, so the clear is reached on its
        # merits -- and still declines, because the label is not the machine's.
        with (
            mock.patch.object(verify, "_gh_json", return_value=pr),
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
                verify,
                "_gh_json",
                # Two reads: one per attempt, and the second is what the label
                # is decided on. The loop reads the live pull request before
                # anything in it can return, so the attempt that drops every
                # update returns what the pull request holds now rather than
                # the copy this run started from (#1778, round 8) -- one more
                # read on this path than before, and it is the read that makes
                # the decision honest.
                side_effect=[
                    pr_payload(retargeted_body, head_sha=HEAD),
                    pr_payload(retargeted_body, head_sha=HEAD),
                ],
            ) as gh_json,
            mock.patch.object(verify, "_write_pr_body") as write,
        ):
            result = verify._apply_ci_updates(321, HEAD, body, updates, {})

        self.assertEqual(gh_json.call_count, 2)
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


class HostileIndexTests(unittest.TestCase):
    """A PR-editable index must not take the verifier down.

    `1e9999` parses as infinity and `int()` of that raises OverflowError,
    which the reads here caught no more than the shared ones did.
    """

    def body(self) -> str:
        payload = json.dumps(
            {
                "entries": [
                    {
                        "index": 1e9999,
                        "item": "CI: `check-links` green on the PR head",
                        "status": "pending-ci",
                        "kind": "ci",
                    }
                ]
            }
        )
        return "## Summary\n\n<!-- evidence-status:v1\n" + payload + "\n-->\n"

    def test_the_verifier_skips_it_rather_than_raising(self) -> None:
        entries = verify.evidence_entries(self.body())
        self.assertEqual(verify.ci_entries_needing_verification(entries, "abc1234"), [])

    def test_the_update_targeting_check_returns_rather_than_raising(self) -> None:
        # It cannot read the index, so the entry contributes no check name.
        # What matters is that it answers at all: the read used to raise and
        # take the verifier with it.
        self.assertIsInstance(
            verify._updates_targeting_unchanged_entries(
                self.body(), {1: {"status": "complete", "detail": "d"}}
            ),
            dict,
        )


class TheVerifierSaysWhatItCouldNotCarryTests(unittest.TestCase):
    """This lane rewrites the author's section too, so it owes them the same note (#1740).

    `update_evidence_entries` returns a body and nothing else, so what the
    re-render dropped was said through `log()` -- the Actions step log, which
    the author of the dropped text does not read. The verifier now carries the
    announcements out of the write and says them on the pull request it just
    wrote, after the write and never before it.
    """

    def carried_note(self, *, write_succeeds: bool = True) -> list[list[str]]:
        """The notes the verifier posted while completing one green check."""
        # A continuation under the status line: the re-render replaces the line
        # from the entries in hand, and the author's second line goes with it.
        body = body_with_entries([ci_entry()]).replace(
            "-- waiting for checks\n",
            "-- waiting for checks\n  and the rest of what the author wrote\n",
        )
        pr = pr_payload(body, labels=[])
        posted: list[list[str]] = []

        with (
            mock.patch.object(
                verify, "_gh_json", side_effect=lambda args, env: pr if any("pulls/321" in a for a in args) else None
            ),
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
            mock.patch.object(verify, "_write_pr_body", return_value=write_succeeds),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(verify, "_gh", return_value=True),
            mock.patch.object(
                verify,
                "post_uncarried_notes",
                side_effect=lambda pr_number, persona, notes, head, env: posted.append(list(notes)) or True,
            ),
        ):
            verify.process_pr(321, {})
        return posted

    def test_the_author_is_told_on_the_pull_request_what_the_write_dropped(self) -> None:
        posted = self.carried_note()
        self.assertEqual(len(posted), 1, posted)
        self.assertEqual(len(posted[0]), 1, posted[0])
        self.assertIn("continuing the status line", posted[0][0])

    def test_nothing_is_said_when_the_body_write_did_not_land(self) -> None:
        # A note about text missing from a body nobody wrote names a loss that
        # did not happen: the section is still whole on the pull request.
        self.assertEqual(self.carried_note(write_succeeds=False), [])

    def stood_down_note(self, *, head_moves: bool = False) -> list[list[str]]:
        """The notes the verifier posted on a body whose write stands down.

        `head_moves` answers the live read inside `_apply_ci_updates` with a
        head the author pushed after the body was sampled.
        """
        # A raw HTML block of kinds 1 to 5 under the heading: CommonMark runs
        # it to the end of the document, so the write cannot say where the
        # section ends, stands the whole body down, and returns it
        # byte-identical.
        body = body_with_entries([ci_entry()]).replace(
            "\n\n## Validation\n",
            "\n\n<pre>\nthe run log nobody closed\n\n## Validation\n",
            1,
        )
        pr = pr_payload(body, labels=[])
        moved = pr_payload(body, head_sha=OTHER_HEAD, labels=[])
        posted: list[list[str]] = []
        written: list[str] = []
        reads: list[str] = []

        def read_pr(args, env):
            if not any("pulls/321" in a for a in args):
                return None
            reads.append("pr")
            return moved if head_moves and len(reads) > 1 else pr

        with (
            mock.patch.object(verify, "_gh_json", side_effect=read_pr),
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
            mock.patch.object(
                verify, "_write_pr_body", side_effect=lambda *a, **k: written.append(a[1]) or True
            ),
            mock.patch.object(verify, "blocked_label_applied_by_factory", return_value=True),
            mock.patch.object(verify, "_gh", return_value=True),
            mock.patch.object(
                verify,
                "post_uncarried_notes",
                side_effect=lambda pr_number, persona, notes, head, env: posted.append(list(notes)) or True,
            ),
        ):
            verify.process_pr(321, {})
        return posted, written

    def test_a_stand_down_is_said_even_though_the_body_did_not_change(self) -> None:
        # `_apply_ci_updates` returned on `new_body == body` before it posted.
        # A stand-down IS an unchanged body -- the status this run resolved is
        # not written either -- so the one case the author most needs telling
        # about was the one case that said nothing (#1740, round 3).
        posted, written = self.stood_down_note()
        self.assertEqual(written, [])
        self.assertEqual(len(posted), 1, posted)
        self.assertEqual(len(posted[0]), 1, posted[0])
        self.assertIn("left as written", posted[0][0])

    def test_a_stand_down_at_a_head_that_has_moved_is_not_said(self) -> None:
        # The stand-down post returned before the live read the writing path
        # makes, so a push between sampling the body and saying what the write
        # dropped filed the note under a stale head. A head that moved is
        # silence, and the next check_suite event says it against the head it
        # belongs to (#1740, round 4).
        posted, written = self.stood_down_note(head_moves=True)
        self.assertEqual(written, [])
        self.assertEqual(posted, [])


if __name__ == "__main__":
    unittest.main()
