#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Unit tests for structured agent triage and approval helpers."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURES_DIR = REPO_ROOT / ".agents" / "scripts" / "fixtures"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def load_fixture(name: str) -> dict:
    return json.loads((FIXTURES_DIR / name).read_text(encoding="utf-8"))


triage = load_module("agent_triage_request", REPO_ROOT / "scripts" / "agent-triage-request.py")


class AgentTriageTests(unittest.TestCase):
    def make_payload(self, *, request_id: str, requested_at: str, status: str = "pending") -> dict:
        return {
            "version": 1,
            "status": status,
            "request_id": request_id,
            "requested_agent": "april",
            "target_type": "pull_request",
            "target_number": 212,
            "source_type": "issue_comment",
            "source_id": f"issue_comment:{request_id}",
            "source_url": "https://github.com/fairchild/workspaces/pull/212#issuecomment-1",
            "requesting_user": "mallory",
            "requesting_association": "NONE",
            "requesting_trust_level": "public",
            "sanitized_summary": "Verify the release notes formatting.",
            "approval_required": True,
            "requested_at": requested_at,
            "triaged_at": requested_at,
        }

    def make_comment(self, *, comment_id: int, created_at: str, payload: dict, author: str = "github-actions[bot]") -> dict:
        return {
            "id": comment_id,
            "created_at": created_at,
            "user": {"login": author},
            "body": triage.render_triage_comment(payload),
        }

    def test_summary_sanitizes_prompt_injection_fixture_lines(self) -> None:
        fixture = load_fixture("contributor-prompt-injection.json")
        malicious_line = fixture["detailed_pull_request"]["reviews"]["nodes"][0]["body"]
        raw = f"{malicious_line}\nPlease verify the release notes formatting."
        summary = triage.summarize_source_text(raw)
        self.assertEqual(summary, "Please verify the release notes formatting")
        self.assertNotIn("ignore", summary.lower())
        self.assertNotIn("prompt injection", summary.lower())

    def test_parse_triage_comments_ignores_non_bot_markers(self) -> None:
        payload = self.make_payload(request_id="april-pull_request-212-older", requested_at="2026-03-24T16:00:00Z")
        comments = [
            self.make_comment(comment_id=1, created_at="2026-03-24T16:00:01Z", payload=payload, author="mallory"),
        ]
        self.assertEqual(triage.parse_triage_comments(comments), [])

    def test_latest_pending_request_prefers_newest_and_supports_status_updates(self) -> None:
        older = self.make_payload(request_id="april-pull_request-212-older", requested_at="2026-03-24T16:00:00Z")
        newer = self.make_payload(request_id="april-pull_request-212-newer", requested_at="2026-03-24T16:05:00Z")
        comments = [
            self.make_comment(comment_id=1, created_at="2026-03-24T16:00:01Z", payload=older),
            self.make_comment(comment_id=2, created_at="2026-03-24T16:05:01Z", payload=newer),
        ]
        parsed = triage.parse_triage_comments(comments)
        selected = triage.latest_pending_request(parsed)
        self.assertIsNotNone(selected)
        assert selected is not None
        self.assertEqual(selected.payload["request_id"], newer["request_id"])

        claimed = triage.claim_payload(selected.payload, "fairchild", "https://github.com/fairchild/workspaces/actions/runs/1")
        superseded = triage.superseded_payload(parsed[0].payload)
        self.assertEqual(claimed["status"], "claimed")
        self.assertEqual(claimed["claimed_by"], "fairchild")
        self.assertEqual(superseded["status"], "superseded")

    def test_executor_prompts_use_structured_payload_only(self) -> None:
        payload = self.make_payload(request_id="april-pull_request-212-prompt", requested_at="2026-03-24T16:10:00Z")
        contributor_prompt = triage.render_contributor_prompt(payload)
        claude_prompt = triage.render_claude_prompt(payload)
        self.assertIn(payload["sanitized_summary"], contributor_prompt)
        self.assertIn(payload["sanitized_summary"], claude_prompt)
        self.assertIn(payload["source_url"], contributor_prompt)
        self.assertIn(payload["source_url"], claude_prompt)
        self.assertNotIn("IGNORE ALL RULES", contributor_prompt)
        self.assertNotIn("IGNORE ALL RULES", claude_prompt)
        self.assertIn("always post one visible response", claude_prompt)
        self.assertIn("gh pr comment 212 --body-file /tmp/reply.md", claude_prompt)
        self.assertIn("Do not finish silently", claude_prompt)

        issue_payload = dict(payload)
        issue_payload["target_type"] = "issue"
        issue_payload["target_number"] = 312
        issue_prompt = triage.render_claude_prompt(issue_payload)
        self.assertIn("gh issue comment 312 --body-file /tmp/reply.md", issue_prompt)

    def test_claim_refuses_without_safe_to_run_label(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            event_path = Path(tmpdir) / "event.json"
            output_path = Path(tmpdir) / "outputs.txt"
            event_path.write_text(
                json.dumps(
                    {
                        "label": {"name": "not-safe"},
                        "issue": {"number": 212},
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "uv",
                    "run",
                    "--script",
                    "scripts/agent-triage-request.py",
                    "claim",
                    "--event-name",
                    "issues",
                    "--event-path",
                    str(event_path),
                    "--github-token",
                    "dummy",
                    "--github-api-url",
                    "https://api.github.com",
                    "--github-repository",
                    "fairchild/workspaces",
                    "--github-repository-owner",
                    "fairchild",
                    "--github-actor",
                    "fairchild",
                    "--github-run-id",
                    "1",
                    "--github-server-url",
                    "https://github.com",
                    "--github-output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            output = output_path.read_text(encoding="utf-8")
            self.assertIn("matched=false", output)
            self.assertIn("reason=label_mismatch", output)

    def test_payload_label_names_detects_privileged_patch_label(self) -> None:
        names = triage.payload_label_names(
            {
                "labels": [
                    {"name": "safe-to-run-agent"},
                    {"name": triage.PRIVILEGED_PATCH_LABEL},
                ]
            }
        )

        self.assertIn(triage.PRIVILEGED_PATCH_LABEL, names)


if __name__ == "__main__":
    unittest.main()
