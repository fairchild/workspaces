#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py==4.2.0"]
# ///
"""Verify live named CI satisfies review evidence without trusting author claims.

The fixtures exercise the real preparation/accounting/approval path, with only
GitHub and model I/O replaced. Authoring validation and non-CI gates stay strict.
"""
from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / ".agents/skills/cofounder-contributor/scripts"
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("run_contributor", SCRIPTS / "run-contributor.py")
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)
evidence = sys.modules["evidence"]
github = sys.modules["github_state"]
execution = sys.modules["execution"]
telemetry = sys.modules["telemetry"]

HEAD, BASE = "a" * 40, "b" * 40
CI = "CI: `Optional Widget CI` green on the PR head"
MANUAL = "Owner must approve the terminal screenshot"
PR_BODY = "Closes #99\n\n<!-- contributor:issue=99;agent=april-clearwater -->"
ISSUE = {"number": 99, "body": f"## Requested Evidence\n- {CI}"}
PR = {"number": 42, "body": PR_BODY, "headRefOid": HEAD, "baseRefOid": BASE}


def run(identifier=10, status="completed", conclusion="success", head=HEAD, name="Optional Widget CI"):
    return {"id": identifier, "name": name, "head_sha": head, "status": status,
            "conclusion": conclusion, "html_url": f"https://github.com/fairchild/workspaces/runs/{identifier}"}


def resolve(runs):
    with mock.patch.object(evidence, "check_runs_for", return_value=runs):
        return evidence.resolve_named_ci_evidence([CI], HEAD, {})


class NamedCheckTests(unittest.TestCase):
    def test_newest_unfinished_run_supersedes_old_success(self):
        facts = resolve([run(), run(11, "in_progress", None)])
        self.assertEqual(facts[0]["status"], "pending")
        self.assertEqual(facts[0]["run_id"], 11)
        self.assertEqual(facts[0]["head_sha"], HEAD)

    def test_missing_unavailable_failed_pending_and_stale_are_distinct(self):
        cases = [(None, "unavailable"), ([], "missing"), ([run(conclusion="failure")], "failed"),
                 ([run(status="queued", conclusion=None)], "pending"), ([run(head=BASE)], "unavailable")]
        for runs, status in cases:
            with self.subTest(status=status): self.assertEqual(resolve(runs)[0]["status"], status)
        self.assertEqual(resolve([run(head=BASE)])[0]["reason"], "invalid_or_stale_run")

    def test_deduplicates_fetches_without_losing_contract_indexes(self):
        with mock.patch.object(evidence, "check_runs_for", return_value=[run()]) as fetch:
            facts = evidence.resolve_named_ci_evidence([MANUAL, CI, CI], HEAD, {})
        fetch.assert_called_once_with("Optional Widget CI", HEAD, {})
        self.assertEqual([fact["index"] for fact in facts], [2, 3])
        self.assertEqual([fact["item"] for fact in facts], [CI, CI])

    def test_invalid_head_never_queries_a_different_commit(self):
        with mock.patch.object(evidence, "check_runs_for") as fetch:
            facts = evidence.resolve_named_ci_evidence([CI], "main", {})
        fetch.assert_not_called()
        self.assertEqual(facts[0]["status"], "unavailable")

    def test_green_body_silent_is_satisfied_only_in_review(self):
        original = PR_BODY
        accounting, errors = evidence.validate_evidence_accounting(original, [CI], review_ci=resolve([run()]))
        self.assertEqual(errors, [])
        self.assertEqual(accounting["complete_items"], [CI])
        self.assertEqual(accounting["missing_items"], [])
        self.assertTrue(evidence.validate_evidence_accounting(original, [CI])[1])
        self.assertEqual(original, PR_BODY)

    def test_nonci_original_index_and_human_gate_survive_overlay(self):
        entries = {"entries": [{"index": 2, "item": MANUAL, "status": "blocked", "detail": "Owner sign-off is outstanding"}]}
        body = f"## Evidence Status\n- [blocked] {MANUAL} -- Owner sign-off is outstanding\n\n<!-- evidence-status:v1\n{json.dumps(entries)}\n-->\n\n## Validation\nBlocked on evidence"
        accounting, errors = evidence.validate_evidence_accounting(body, [CI, MANUAL], review_ci=resolve([run()]))
        self.assertEqual(errors, [])
        self.assertEqual(accounting["complete_items"], [CI])
        self.assertEqual(accounting["blocked_items"], [MANUAL])
        self.assertIsNotNone(evidence.review_evidence_gate_error("approve", accounting, [], images_inspected=True))
        self.assertEqual(json.loads(body.split('<!-- evidence-status:v1\n')[1].split('\n-->')[0])["entries"][0]["index"], 2)

    def test_green_ci_does_not_clear_nonci_missing_or_malformed_metadata(self):
        for body, requested in ((PR_BODY, [CI, MANUAL]), ("## Evidence Status\nthis is malformed", [CI]),
                                ('<!-- evidence-status:v1\n{"entries": "bad"}\n-->\n## Evidence Status\n', [CI])):
            with self.subTest(body=body):
                self.assertTrue(evidence.validate_evidence_accounting(body, requested, review_ci=resolve([run()]))[1])

    def test_named_ci_does_not_satisfy_compound_human_signoff(self):
        for item in (CI + "; Owner must approve", CI + "; manual approval required"):
            with mock.patch.object(evidence, "check_runs_for", return_value=[run()]) as fetch:
                facts = evidence.resolve_named_ci_evidence([item], HEAD, {})
            fetch.assert_called_once()
            self.assertEqual(facts[0]["status"], "satisfied")
            self.assertFalse(facts[0]["automatic_completion"])
            self.assertTrue(evidence.validate_evidence_accounting(PR_BODY, [item], review_ci=facts)[1])

    def test_runtime_success_does_not_erase_duplicate_contract_errors(self):
        with mock.patch.object(evidence, "check_runs_for", return_value=[run()]):
            facts = evidence.resolve_named_ci_evidence([CI, CI], HEAD, {})
        errors = evidence.validate_evidence_accounting(PR_BODY, [CI, CI], review_ci=facts)[1]
        self.assertTrue(any("same item more than once" in error for error in errors))

    def test_review_completion_accepts_only_a_whole_single_check(self):
        for item, name in ((CI, "Optional Widget CI"), ("The `check-links` check passes on the PR head", "check-links"),
                           ("`Web CI / test` job successful on this PR", "Web CI / test"),
                           ("`Lint, Test, Build` workflow passed on the head commit", "Lint, Test, Build"),
                           ("CI: `Web CI` (required branch protection) is green", "Web CI"),
                           ("CI: `Web CI` must finish on the exact PR head and stay green", "Web CI")):
            self.assertEqual(evidence._review_ci_check_name(item), name)
        for item in ("CI: `Security CI` and `Optional Widget CI` green on the PR head",
                     CI + "; `swift test` passes", CI + " and local tests pass", CI + ". Also inspect the terminal."):
            self.assertIsNone(evidence._review_ci_check_name(item))
            # Existing authoring classification is intentionally unchanged.
            self.assertEqual(evidence._evidence_item_kind(item), "ci")
            with mock.patch.object(evidence, "check_runs_for", return_value=[run()]) as fetch:
                facts = evidence.resolve_named_ci_evidence([item], HEAD, {})
            self.assertTrue(fetch.called)
            self.assertTrue(facts)
            self.assertTrue(all(not fact["automatic_completion"] for fact in facts))

    def test_verification_collects_coordinated_names_without_treating_tests_as_checks(self):
        for connector in (" and ", ", ", ", and ", " & "):
            item = "CI: `Security CI`" + connector + "`Optional Widget CI` green on the PR head"
            self.assertEqual(evidence._verification_ci_check_names(item), ["Optional Widget CI", "Security CI"])
        self.assertEqual(evidence._verification_ci_check_names(CI + "; `swift test` passes"), ["Optional Widget CI"])

    def test_overlay_does_not_complete_a_compound_from_a_single_check_fact(self):
        item = CI + "; `swift test` passes"
        fact = {**resolve([run()])[0], "item": item}
        accounting, errors = evidence.validate_evidence_accounting(PR_BODY, [item], review_ci=[fact])
        self.assertTrue(errors)
        self.assertEqual(accounting["complete_items"], [])

    def test_skipped_or_neutral_is_not_green(self):
        for conclusion in ("skipped", "neutral", "cancelled"):
            self.assertEqual(resolve([run(conclusion=conclusion)])[0]["status"], "failed")
        self.assertEqual(resolve([run(conclusion=None)])[0]["status"], "unavailable")


class ReviewPipelineTests(unittest.TestCase):
    def prepared(self, body=PR_BODY, runs=None):
        pr = {**PR, "body": body}
        task = json.dumps({"selected_item": {"number": 42}, "review_head_sha": HEAD, "review_base_sha": BASE})
        payload = runner.UntrustedGitHubPayload(source_type="issue", identifier="99", author_login="fairchild", trust_level=runner.ActorTrustLevel.OWNER, body=ISSUE["body"])
        with mock.patch.object(runner, "review_comments", return_value=[]), mock.patch.object(runner, "repo_owner_name", return_value=("fairchild", "workspaces")), mock.patch.object(runner, "fetch_detailed_pull_request", return_value=pr), mock.patch.object(runner, "fetch_review_checks", return_value=[]), mock.patch.object(runner, "publish_review_preparation"), mock.patch.object(evidence, "check_runs_for", return_value=runs):
            return runner.prepare_action_review(task, [payload], {}, ROOT, reviewer="april", dry_run=True)

    def test_named_nonrequired_check_reaches_model_input_and_stable_digest(self):
        prepared = self.prepared(runs=[run()])
        self.addCleanup(prepared.cleanup)
        expected = {"index": 1, "item": CI, "automatic_completion": True, "check_name": "Optional Widget CI", "head_sha": HEAD,
                    "status": "satisfied", "run_id": 10, "url": "https://github.com/fairchild/workspaces/runs/10",
                    "conclusion": "success", "reason": "latest_completed"}
        self.assertEqual(prepared.facts["required_checks"], [])
        self.assertEqual(prepared.facts["named_ci_evidence"], [expected])
        choice = runner.SelectionChoice(selection_kind="review_pr", number=42, reason="review")
        transcript = runner.phase_task_for_selection(choice, json.dumps({"review_evidence": prepared.model_context()}), [], message="")
        with mock.patch.object(runner, "run_claude", return_value="output") as model, mock.patch.object(runner, "validate_output", return_value=(0, '{"action":"review_pr"}', "")):
            runner.run_action_phase("system", transcript, {}, {}, mode="cli", tools="Read,Grep,Glob", cwd=ROOT, write_scope=None, max_attempts=1)
        self.assertIn(json.dumps(expected), model.call_args.args[1])
        reworded = self.prepared(body="## Summary\nDifferent prose\n\n" + PR_BODY, runs=[run()])
        self.addCleanup(reworded.cleanup)
        self.assertEqual(prepared.input_digest, reworded.input_digest)
        pending = self.prepared(runs=[run(11, "queued", None)])
        self.addCleanup(pending.cleanup)
        self.assertEqual(pending.status, "ready")
        self.assertNotEqual(prepared.input_digest, pending.input_digest)

    def approve(self, *, body=PR_BODY, runs=None, run_sequence=None, requested=None):
        pr = {**PR, "body": body}
        issue = ISSUE if requested is None else {"number": 99, "body": "## Requested Evidence\n" + "\n".join('- ' + item for item in requested)}
        state = {"pull_requests": [pr], "issues": [issue]}
        action = json.dumps({"action": "review_pr", "pr_number": 42, "verdict": "approve", "body": "Approve based on the current named check", "persona": "April"})
        with mock.patch.object(github, "repo_owner_name", return_value=("fairchild", "workspaces")), mock.patch.object(github, "fetch_work_state", return_value=state), mock.patch.object(execution, "repo_owner_name", return_value=("fairchild", "workspaces")), mock.patch.object(execution, "fetch_detailed_issue", return_value=issue), mock.patch.object(execution, "_pr_body_and_head", return_value=(body, HEAD)), mock.patch.object(execution, "_factory_expected_pr_head_is_current", return_value=True), mock.patch.object(evidence, "check_runs_for", return_value=runs, side_effect=run_sequence) as checks, mock.patch.object(runner, "run_checked") as post, mock.patch.object(execution, "detect_bot_login", return_value=""), mock.patch.object(runner, "_complete_diff_evidence_after_approval"), mock.patch.object(runner, "_update_mergeable_label"):
            result = runner.route_action(action, False, {"FACTORY_EXPECTED_PR_HEAD_SHA": HEAD})
        return result, post, checks

    def test_green_named_check_with_silent_body_reaches_approval(self):
        for body in (PR_BODY, "Closes #99\n\n## Evidence\nThe named checks are available in GitHub."):
            with self.subTest(factory_marker="contributor:" in body):
                result, post, checks = self.approve(body=body, runs=[run()])
                self.assertEqual(result, 0)
                post.assert_called_once()
                self.assertIn("event=APPROVE", post.call_args.args[0])
                self.assertIn("commit_id=" + HEAD, post.call_args.args[0])
                self.assertEqual(checks.call_count, 2)

    def test_fresh_pending_rerun_blocks_even_after_green_accounting(self):
        result, post, checks = self.approve(run_sequence=[[run()], [run(), run(11, "in_progress", None)]])
        self.assertEqual(result, 1)
        post.assert_not_called()
        self.assertEqual(checks.call_count, 2)

    def test_red_or_missing_cannot_be_overridden_by_complete_body_attestation(self):
        entries = {"entries": [{"index": 1, "item": CI, "status": "complete", "detail": "green earlier"}]}
        body = PR_BODY + f'\n\n## Evidence Status\n- [complete] {CI} -- green earlier\n\n<!-- evidence-status:v1\n{json.dumps(entries)}\n-->'
        for runs in ([], None, [run(conclusion="failure")], [run(head=BASE)]):
            with self.subTest(runs=runs):
                result, post, _ = self.approve(body=body, runs=runs)
                self.assertEqual(result, 1)
                post.assert_not_called()

    def complete_body(self, item):
        entries = {"entries": [{"index": 1, "item": item, "status": "complete", "detail": "Recorded explicit evidence for every obligation"}]}
        return PR_BODY + f'\n\n## Evidence Status\n- [complete] {item} -- Recorded explicit evidence for every obligation\n\n<!-- evidence-status:v1\n{json.dumps(entries)}\n-->'

    def test_human_qualification_does_not_hide_a_now_failed_named_check(self):
        for qualifier in ("manual approval required", "Owner must approve"):
            item = "CI: `Web CI` green on the PR head; " + qualifier
            result, post, checks = self.approve(body=self.complete_body(item), requested=[item],
                                              runs=[run(name="Web CI", conclusion="failure")])
            self.assertEqual(result, 1)
            post.assert_not_called()
            self.assertEqual(checks.call_count, 2)
            self.assertEqual({call.args[0] for call in checks.call_args_list}, {"Web CI"})

    def test_legacy_single_check_forms_keep_live_verification_and_completion(self):
        for item in ("CI: `Web CI` (required branch protection) is green",
                     "CI: `Web CI` must finish on the exact PR head and stay green"):
            for body in (PR_BODY, self.complete_body(item)):
                with self.subTest(item=item, body=body):
                    result, post, checks = self.approve(body=body, requested=[item], runs=[run(name="Web CI")])
                    self.assertEqual(result, 0)
                    post.assert_called_once()
                    self.assertEqual(checks.call_count, 2)

    def test_live_verification_does_not_depend_on_automatic_completion_grammar(self):
        item = "CI: `Web CI` (required branch protection) is green"
        with mock.patch.object(evidence, "_review_ci_check_name", return_value=None):
            result, post, checks = self.approve(body=self.complete_body(item), requested=[item], runs=[run(name="Web CI")])
        self.assertEqual(result, 0)
        post.assert_called_once()
        self.assertEqual(checks.call_count, 2)

    def test_two_named_checks_are_both_verified_when_one_is_missing(self):
        item = "CI: `Security CI` and `Optional Widget CI` green on the PR head"
        for body in (PR_BODY, self.complete_body(item), self.complete_body(item).replace('<!-- contributor:issue=99;agent=april-clearwater -->', '')):
            with self.subTest(body=body):
                result, post, checks = self.approve(body=body, requested=[item],
                    run_sequence=lambda name, *_: [run()] if name == "Optional Widget CI" else [])
                self.assertEqual(result, 1)
                post.assert_not_called()
                self.assertEqual({call.args[0] for call in checks.call_args_list}, {"Security CI", "Optional Widget CI"})

    def test_silent_mixed_ci_and_test_item_is_not_automatically_completed(self):
        item = CI + "; `swift test` passes"
        result, post, checks = self.approve(requested=[item], runs=[run()])
        self.assertEqual(result, 1)
        post.assert_not_called()
        checks.assert_called_once()
        self.assertEqual(checks.call_args.args[0], "Optional Widget CI")

    def test_complete_mixed_evidence_preserves_live_check_guard(self):
        item = CI + "; `swift test` passes"
        for conclusion, expected in (("failure", 1), ("success", 0)):
            result, post, checks = self.approve(body=self.complete_body(item), requested=[item],
                                              runs=[run(conclusion=conclusion)])
            self.assertEqual(result, expected)
            self.assertEqual(checks.call_count, 2)
            self.assertEqual(post.call_count, int(expected == 0))

    def test_nonci_omission_still_blocks_approval(self):
        result, post, _ = self.approve(runs=[run()], requested=[CI, MANUAL])
        self.assertEqual(result, 1)
        post.assert_not_called()


class ReadTokenTests(unittest.TestCase):
    def test_only_check_api_reads_use_the_workflow_token(self):
        env = {"GH_TOKEN": "app-publisher-fixture", "FACTORY_CHECKS_TOKEN": "workflow-reader-fixture", "PATH": "/usr/bin:/bin"}
        with mock.patch.object(evidence, "run_optional", return_value='{"check_runs":[]}') as read:
            evidence.check_runs_for("Optional Widget CI", HEAD, env)
        self.assertEqual(read.call_args.kwargs["env"]["GH_TOKEN"], "workflow-reader-fixture")
        self.assertNotIn("FACTORY_CHECKS_TOKEN", read.call_args.kwargs["env"])
        self.assertEqual(env["GH_TOKEN"], "app-publisher-fixture")
        with mock.patch.object(github.subprocess, "run", return_value=mock.Mock(returncode=0, stdout="[]", stderr="")) as required:
            github.fetch_review_checks(42, env)
        self.assertEqual(required.call_args.kwargs["env"]["GH_TOKEN"], "workflow-reader-fixture")
        self.assertNotIn("GH_TOKEN", runner.sanitized_claude_env(env))
        self.assertNotIn("FACTORY_CHECKS_TOKEN", runner.sanitized_claude_env(env))
        self.assertEqual(telemetry.redact_secrets("workflow-reader-fixture", env), "[REDACTED]")

    def test_workflow_grants_read_capability_without_changing_app_publisher(self):
        workflow = (ROOT / ".github/workflows/factory-review-execute.yml").read_text()
        self.assertIn("  checks: read\n", workflow)
        self.assertEqual(workflow.count("FACTORY_CHECKS_TOKEN: ${{ github.token }}"), 2)
        for job in ("april", "plat"):
            permissions = workflow.split(f"  {job}:\n", 1)[1].split("    if:", 1)[0]
            self.assertIn("checks: read", permissions)
            self.assertIn("actions: read", permissions)
            self.assertNotIn(": write", permissions)
        for step in ("Run April counterpart review", "Run Plat counterpart review"):
            content = workflow.split('- name: ' + step, 1)[1].split('\n      - ', 1)[0]
            self.assertIn("GH_TOKEN: ${{ steps.app-token.outputs.token }}", content)
            self.assertIn("FACTORY_CHECKS_TOKEN: ${{ github.token }}", content)


if __name__ == "__main__":
    unittest.main()
