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


class CheckRunResolutionTests(unittest.TestCase):
    def test_missing_run_stays_pending(self) -> None:
        update = verify.entry_update_for_check_run("Web CI", HEAD, None)
        self.assertEqual(update["status"], "pending-ci")
        self.assertIn("no completed run of `Web CI`", str(update["detail"]))

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
                "latest_completed_check_run",
                return_value={"conclusion": "success", "html_url": "https://example.invalid/run/1"},
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
                "latest_completed_check_run",
                return_value={"conclusion": "success", "html_url": "https://example.invalid/run/1"},
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
                    mock.patch.object(verify, "latest_completed_check_run") as lookup,
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
