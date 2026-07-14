#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Unit tests for Factory owner-comment gating and directed-message framing."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-responder-payload.py"


def load_module():
    spec = importlib.util.spec_from_file_location(
        "factory_responder_payload", SCRIPT_PATH
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


payload = load_module()


class FactoryCommentResponderTests(unittest.TestCase):
    def make_context(self, **overrides):
        values = {
            "author_login": "fairchild",
            "author_type": "User",
            "body": "Please also update the state label.",
            "issue_number": 1089,
        }
        values.update(overrides)
        return payload.CommentContext(**values)

    def test_parse_comment_id_accepts_same_repo_conversation_url(self) -> None:
        self.assertEqual(
            payload.parse_comment_id(
                "https://github.com/fairchild/workspaces/pull/99#issuecomment-1234",
                "fairchild/workspaces",
                "https://github.com",
            ),
            1234,
        )

    def test_parse_comment_id_rejects_another_repository(self) -> None:
        with self.assertRaisesRegex(payload.PayloadError, "current repository"):
            payload.parse_comment_id(
                "https://github.com/other/workspaces/issues/99#issuecomment-1234",
                "fairchild/workspaces",
                "https://github.com",
            )

    def test_comment_gate_requires_owner_human_and_absent_marker(self) -> None:
        self.assertEqual(
            payload.comment_gate(self.make_context(), "fairchild"),
            {"owner_match": True, "human_author": True, "marker_absent": True},
        )
        bot = self.make_context(
            author_login="april-clearwater[bot]",
            author_type="Bot",
            body=f"Done. {payload.RESPONSE_MARKER}",
        )
        self.assertEqual(
            payload.comment_gate(bot, "fairchild"),
            {"owner_match": False, "human_author": False, "marker_absent": False},
        )

    def test_factory_target_filter_uses_type_specific_labels(self) -> None:
        issue = {"labels": [{"name": "agent"}]}
        pull_request = {
            "pull_request": {"url": "https://api.github.test/pulls/1"},
            "labels": [{"name": "author:april"}],
        }
        non_factory_issue = {"labels": [{"name": "author:april"}]}
        non_factory_pr = {"pull_request": {}, "labels": [{"name": "agent"}]}

        self.assertEqual(payload.factory_target_type(issue), "issue")
        self.assertEqual(payload.factory_target_type(pull_request), "pull_request")
        self.assertIsNone(payload.factory_target_type(non_factory_issue))
        self.assertIsNone(payload.factory_target_type(non_factory_pr))

    def test_message_matches_runtime_envelope_and_contains_required_instruction(
        self,
    ) -> None:
        context = self.make_context(body="First line\n---\nSecond line")
        target = {
            "title": "Factory responder\nwith odd whitespace",
            "html_url": "https://github.com/fairchild/workspaces/issues/1089",
        }

        message = payload.build_message(context, target, "issue")

        self.assertTrue(
            message.startswith("@fairchild mentioned you in issue #1089\n---\n")
        )
        self.assertIn("The repository owner commented on issue #1089", message)
        self.assertIn(
            "Thread URL: https://github.com/fairchild/workspaces/issues/1089", message
        )
        self.assertIn("> ---", message)
        self.assertEqual(message.splitlines().count("---"), 2)
        self.assertIn(
            f"End any comment you post with the HTML marker {payload.RESPONSE_MARKER}",
            message,
        )

    def test_manual_comment_resolution_uses_comment_api_and_issue_url(self) -> None:
        comment = {
            "user": {"login": "fairchild", "type": "User"},
            "body": "Ship it",
            "issue_url": "https://api.github.com/repos/fairchild/workspaces/issues/1089",
            "html_url": "https://github.com/fairchild/workspaces/issues/1089#issuecomment-42",
        }
        with mock.patch.object(
            payload, "github_get", return_value=comment
        ) as github_get:
            context = payload.comment_from_url(
                "https://github.com/fairchild/workspaces/issues/1089#issuecomment-42",
                api_url="https://api.github.com",
                server_url="https://github.com",
                repo="fairchild/workspaces",
                token="not-a-real-token",
            )

        self.assertEqual(context, self.make_context(body="Ship it"))
        github_get.assert_called_once_with(
            "https://api.github.com",
            "not-a-real-token",
            "/repos/fairchild/workspaces/issues/comments/42",
        )


if __name__ == "__main__":
    unittest.main()
