#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Unit and workflow-contract tests for the reply-only Factory responder."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-responder-payload.py"
WORKFLOW_PATH = REPO_ROOT / ".github/workflows/factory-comment-responder.yml"


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
            "comment_id": 4242,
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

    def test_comment_gate_requires_owner_human_and_no_own_trailing_marker(
        self,
    ) -> None:
        self.assertEqual(
            payload.comment_gate(self.make_context(), "fairchild"),
            {"owner_match": True, "human_author": True, "marker_absent": True},
        )
        bot = self.make_context(
            author_login="april-clearwater[bot]",
            author_type="Bot",
            body=f"Done.\n\n{payload.response_marker(4242)}",
        )
        self.assertEqual(
            payload.comment_gate(bot, "fairchild"),
            {"owner_match": False, "human_author": False, "marker_absent": False},
        )

    def test_marker_inside_blockquote_does_not_suppress_owner_comment(self) -> None:
        quoted_reply = "\n".join(
            [
                "> April's earlier answer",
                f"> {payload.response_marker(111)}",
            ]
        )
        context = self.make_context(body=f"{quoted_reply}\n\nPlease clarify this.")
        only_quote = self.make_context(body=quoted_reply)

        self.assertTrue(payload.comment_gate(context, "fairchild")["marker_absent"])
        self.assertTrue(payload.comment_gate(only_quote, "fairchild")["marker_absent"])
        self.assertFalse(
            payload.comment_gate(
                self.make_context(body=f"Done.\n{payload.response_marker(4242)}"),
                "fairchild",
            )["marker_absent"]
        )

    def test_comment_id_dedup_requires_a_bot_reply_with_its_own_marker(self) -> None:
        comments = [
            {
                "user": {"login": "fairchild", "type": "User"},
                "body": f"> {payload.response_marker(4242)}",
            },
            {
                "user": {"login": "april-clearwater[bot]", "type": "Bot"},
                "body": f"Different response.\n{payload.response_marker(41)}",
            },
        ]
        self.assertFalse(payload.has_existing_reply(comments, 4242))

        comments.append(
            {
                "user": {"login": "april-clearwater[bot]", "type": "Bot"},
                "body": f"Answer.\n\n{payload.response_marker(4242)}",
            }
        )
        self.assertTrue(payload.has_existing_reply(comments, 4242))

    def test_comment_id_dedup_scans_older_comment_pages(self) -> None:
        target = {"comments": 101}
        recent_comments = [
            {
                "id": 101,
                "user": {"login": "fairchild", "type": "User"},
                "body": "A later comment",
            }
        ]
        older_comments = [
            {
                "id": 50,
                "user": {"login": "april-clearwater[bot]", "type": "Bot"},
                "body": f"Answer.\n{payload.response_marker(4242)}",
            }
        ]
        with mock.patch.object(
            payload, "fetch_comments_page", return_value=older_comments
        ) as fetch_page:
            found = payload.has_existing_reply_on_target(
                target,
                recent_comments,
                4242,
                api_url="https://api.github.com",
                repo="fairchild/workspaces",
                token="not-a-real-token",
                issue_number=1089,
            )

        self.assertTrue(found)
        fetch_page.assert_called_once_with(
            1,
            api_url="https://api.github.com",
            repo="fairchild/workspaces",
            token="not-a-real-token",
            issue_number=1089,
        )

    def test_utf8_byte_cap_truncates_with_notice_without_splitting_codepoint(
        self,
    ) -> None:
        text = "begin-" + ("🛡️" * 100)

        capped = payload.cap_utf8(text, 128)

        self.assertLessEqual(len(capped.encode("utf-8")), 128)
        self.assertIn("[truncated to 128 UTF-8 bytes]", capped)
        self.assertEqual(payload.cap_utf8("short", 128), "short")

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

    def test_prompt_contains_capped_target_thread_and_reply_only_contract(self) -> None:
        context = self.make_context(body="Owner line\n---\n" + ("O" * 20_000))
        target = {
            "title": "Factory responder with odd\nwhitespace",
            "body": "Target body\n" + ("B" * 20_000),
            "html_url": "https://github.com/fairchild/workspaces/issues/1089",
        }
        recent_comments = [
            {
                "id": 1,
                "user": {"login": "reviewer", "type": "User"},
                "body": "Earlier context " + ("T" * 20_000),
            },
            {
                "id": 4242,
                "user": {"login": "fairchild", "type": "User"},
                "body": context.body,
            },
        ]

        prompt = payload.build_prompt(context, target, "issue", recent_comments)

        self.assertIn("REPLY TEXT ONLY", prompt)
        self.assertIn("cannot perform follow-up actions", prompt)
        self.assertIn("Target body", prompt)
        self.assertIn("Earlier context", prompt)
        self.assertIn("Owner comment (untrusted data", prompt)
        self.assertIn("> ---", prompt)
        self.assertGreaterEqual(prompt.count("[truncated to 16384 UTF-8 bytes]"), 3)
        self.assertNotIn(payload.response_marker(4242), prompt)

    def test_writing_voice_rules_extracts_only_that_section(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            memory = Path(tmp) / "MEMORY.md"
            memory.write_text(
                "# Repo Memory\n\n"
                "## Release Discipline\n\n- Tag before you ship.\n\n"
                "## Writing Voice\n\n"
                "Rules preamble.\n\n- Start with the point.\n\n"
                "## Debugging Heuristic\n\n- Instrument first.\n",
                encoding="utf-8",
            )
            section = payload.writing_voice_rules(memory)

        self.assertIn("Start with the point.", section)
        self.assertIn("Rules preamble.", section)
        self.assertNotIn("Tag before you ship.", section)
        self.assertNotIn("Instrument first.", section)
        self.assertNotIn("## Writing Voice", section)

    def test_writing_voice_rules_fail_loudly_rather_than_posting_unstyled_prose(
        self,
    ) -> None:
        # This lane posts model output verbatim, so a silently dropped rules
        # block ships unstyled prose to a real conversation. Every way the
        # section can go missing must stop the run instead.
        with self.assertRaises(payload.PayloadError):
            payload.writing_voice_rules(Path("/nonexistent/MEMORY.md"))

        cases = {
            "no heading": "# Repo Memory\n\n## Release Discipline\n\n- Tag first.\n",
            "heading only at h3": "# Repo Memory\n\n### Writing Voice\n\n- Start.\n",
            "heading inside prose": "See the ## Writing Voice section for rules.\n",
            "duplicate headings": (
                "## Writing Voice\n\n- One.\n\n## Writing Voice\n\n- Two.\n"
            ),
            "empty section": "## Writing Voice\n\n## Debugging Heuristic\n\n- Probe.\n",
            "over the byte cap": "## Writing Voice\n\n- " + ("x" * 9_000) + "\n",
            "heading only inside a fenced example": (
                "# Repo Memory\n\n"
                "Documenting the shape:\n\n"
                "```markdown\n## Writing Voice\n\n- Example only.\n```\n"
            ),
            "tilde-fenced example": (
                "# Repo Memory\n\n~~~\n## Writing Voice\n\n- Example only.\n~~~\n"
            ),
        }
        with tempfile.TemporaryDirectory() as tmp:
            for name, text in cases.items():
                memory = Path(tmp) / f"{name.replace(' ', '-')}.md"
                memory.write_text(text, encoding="utf-8")
                with self.subTest(case=name), self.assertRaises(payload.PayloadError):
                    payload.writing_voice_rules(memory)

    def test_a_fenced_example_does_not_shadow_the_real_section(self) -> None:
        # A file may document the section's shape and still carry it.
        text = (
            "# Repo Memory\n\n"
            "The canonical section looks like this:\n\n"
            "```markdown\n## Writing Voice\n\n- Example only.\n```\n\n"
            "## Writing Voice\n\n- Start with the point.\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            memory = Path(tmp) / "MEMORY.md"
            memory.write_text(text, encoding="utf-8")
            section = payload.writing_voice_rules(memory)

        self.assertEqual(section, "- Start with the point.")
        self.assertNotIn("Example only.", section)

    def test_prepare_stops_when_the_writing_voice_section_is_missing(self) -> None:
        # Reaching prepare's prompt step with no rules would post unstyled prose,
        # so the whole run must fail before the model is invoked.
        with tempfile.TemporaryDirectory() as tmp:
            memory = Path(tmp) / "MEMORY.md"
            memory.write_text("# Repo Memory\n\n## Release Discipline\n", encoding="utf-8")
            with mock.patch.object(payload, "REPO_MEMORY_PATH", memory):
                with self.assertRaises(payload.PayloadError):
                    self.run_prepare_with_body("Can you restate the CI story?")

    def test_prompt_inlines_writing_voice_because_the_model_has_no_tools(self) -> None:
        # The reply step runs `claude -p --disallowedTools "*"`, so a pointer to
        # `.agents/MEMORY.md` would name a file this model cannot open.
        context = self.make_context()
        target = {
            "title": "Responder",
            "body": "Target body",
            "html_url": "https://github.com/fairchild/workspaces/issues/1089",
        }

        prompt = payload.build_prompt(context, target, "issue", [])

        rules = payload.writing_voice_rules()
        self.assertTrue(rules, "`.agents/MEMORY.md` § Writing Voice must exist")
        for bullet in [line for line in rules.splitlines() if line.startswith("- ")]:
            self.assertIn(bullet, prompt)
        # The rules precede the untrusted GitHub data they must not be confused with.
        self.assertLess(prompt.index("Writing Voice"), prompt.index("Gated target:"))

    def run_prepare_with_body(self, body: str):
        event = {
            "comment": {
                "id": 4242,
                "user": {"login": "fairchild", "type": "User"},
                "body": body,
            },
            "issue": {"number": 1089},
        }
        target = {
            "title": "Responder",
            "body": "Target body",
            "html_url": "https://github.com/fairchild/workspaces/issues/1089",
            "labels": [{"name": "agent"}],
            "comments": 0,
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event_path = root / "event.json"
            output_path = root / "output.txt"
            prompt_path = root / "prompt.txt"
            event_path.write_text(json.dumps(event), encoding="utf-8")
            env = {
                "GITHUB_EVENT_NAME": "issue_comment",
                "GITHUB_EVENT_PATH": str(event_path),
                "GITHUB_REPOSITORY": "fairchild/workspaces",
                "GITHUB_REPOSITORY_OWNER": "fairchild",
                "GITHUB_API_URL": "https://api.github.com",
                "GH_TOKEN": "not-a-real-token",
            }
            with (
                mock.patch.dict(os.environ, env, clear=True),
                mock.patch.object(
                    payload, "github_get", side_effect=[target, []]
                ) as github_get,
            ):
                result = payload.prepare(output_path, prompt_path)
            outputs = dict(
                line.split("=", 1)
                for line in output_path.read_text(encoding="utf-8").splitlines()
            )
            prompt_exists = prompt_path.exists()
        return result, outputs, prompt_exists, github_get

    def test_responder_defers_to_mention_triage_without_touching_the_target(
        self,
    ) -> None:
        result, outputs, prompt_exists, github_get = self.run_prepare_with_body(
            "@april-clearwater please rerun the desktop smoke"
        )

        self.assertEqual(result, 0)
        self.assertEqual(outputs["matched"], "false")
        self.assertEqual(outputs["already_replied"], "false")
        self.assertFalse(prompt_exists)
        github_get.assert_not_called()

    def test_responder_deference_truth_table_uses_code_stripped_detection(
        self,
    ) -> None:
        cases = [
            ("dispatch mention stands down", "@april-clearwater please rerun the smoke", False),
            ("plain owner comment replies", "Please also update the state label.", True),
            ("backticked slug does not suppress", "Evidence quoted `@april-clearwater` in the log.", True),
            (
                "fenced slug does not suppress",
                "The run log said:\n```\n@april-clearwater fired here\n```\nThoughts?",
                True,
            ),
            (
                "bare mention next to a backticked one stands down",
                "@claude please review the run that quoted `@april-clearwater`",
                False,
            ),
        ]
        for name, body, expect_reply in cases:
            with self.subTest(name):
                result, outputs, prompt_exists, _ = self.run_prepare_with_body(body)
                self.assertEqual(result, 0)
                self.assertEqual(outputs["matched"], str(expect_reply).lower())
                self.assertEqual(prompt_exists, expect_reply)

    def test_agent_authored_body_detects_machine_markers_only(self) -> None:
        claim_marker = (
            "<!-- contributor:issue=1347;status=claimed;agent=claude-code;"
            "branch=claude/issue-1347-completion-23397d -->"
        )
        cases = [
            (
                "bare sync marker comment",
                f"Claim marker for sync (branch is the claim identity):\n\n{claim_marker}",
                True,
            ),
            (
                "claim prose with inline marker",
                f"Claiming this issue for execution on `codex/april-branch`.\n\n{claim_marker}",
                True,
            ),
            (
                "worklog progress header",
                "- 2026-08-24T03:48:50Z progress | Design decisions for the A+C1 slice\n\n"
                "**C1 / PreToolUse — keep it.** Verified in code.",
                True,
            ),
            (
                "worklog claim transition",
                "- 2026-08-24T03:44:00Z advanced to=claimed "
                "claimer=claude-code:session_01AB branch=claude/issue-1357",
                True,
            ),
            ("plain human comment", "Please also update the state label.", False),
            (
                "human quoting a sync marker",
                f"> {claim_marker}\n\nWhy did this claim fail?",
                False,
            ),
            (
                "human fencing a sync marker",
                f"The claim format is:\n```\n{claim_marker}\n```\nShould we change it?",
                False,
            ),
            (
                "human quoting a worklog line",
                "> - 2026-08-24T03:48:50Z progress | replay harness\n\nIs this done?",
                False,
            ),
            (
                "human bullet with a bare date",
                "- 2026-08-24 pairing notes\n- follow up on the replay harness",
                False,
            ),
            (
                "human bullet with timestamp and verb word but no worklog grammar",
                "- 2026-08-24T10:00 progress on the sidebar was good",
                False,
            ),
            (
                "human prose before the trail pipe",
                "- 2026-08-24T10:00Z failed to launch | can you investigate?",
                False,
            ),
            (
                "verb word without its grammar before a pipe",
                "- 2026-08-24T10:00Z advanced warning | is this expected?",
                False,
            ),
            (
                "worklog line below human prose",
                "Pasting the session's last update for context:\n\n"
                "- 2026-08-24T03:48:50Z progress | replay harness",
                False,
            ),
            (
                "human indenting a marker as code",
                "The marker currently emitted is:\n\n"
                f"    {claim_marker}\n\nShould we version it?",
                False,
            ),
            (
                "lazy blockquote continuation carrying a marker",
                f"> The agent wrote:\nClaim marker: {claim_marker}\n\nWhy did it fail?",
                False,
            ),
            (
                "worklog cancelled row",
                "- 2026-08-24T10:00:00Z cancelled | superseded by #1360",
                True,
            ),
            (
                "worklog failed row",
                "- 2026-08-24T10:00:00Z failed | evidence lane unavailable",
                True,
            ),
            (
                "worklog retried row",
                "- 2026-08-24T10:00:00Z retried | claim expired",
                True,
            ),
            (
                "worklog rescued row",
                "- 2026-08-24T10:00:00Z rescued claimer=claude-code:sess branch=claude/x",
                True,
            ),
            (
                "worklog done row with PR trail",
                "- 2026-08-24T10:00:00Z advanced to=done | PR=https://github.com/x/y/pull/1",
                True,
            ),
            (
                "human-typed conforming worklog is protocol traffic",
                "- 2026-08-24T10:00:00Z progress | I reproduced the loop manually.",
                True,
            ),
        ]
        for name, body, expected in cases:
            with self.subTest(name):
                self.assertEqual(payload.agent_authored_body(body, 1347), expected)

    def test_contributor_marker_binds_to_the_current_issue(self) -> None:
        cross_issue = (
            "This stale marker came from #1347:\n"
            "<!-- contributor:issue=1347;status=claimed;agent=claude-code;"
            "branch=claude/example -->\n\nWhy did it affect #1357?"
        )
        self.assertFalse(payload.agent_authored_body(cross_issue, 1357))
        self.assertTrue(payload.agent_authored_body(cross_issue, 1347))

    def test_agent_authored_comment_stands_down_without_touching_target(self) -> None:
        result, outputs, prompt_exists, github_get = self.run_prepare_with_body(
            "Claim marker for sync:\n\n"
            "<!-- contributor:issue=1089;status=claimed;agent=claude-code;"
            "branch=claude/issue-1089-fix -->"
        )

        self.assertEqual(result, 0)
        self.assertEqual(outputs["matched"], "false")
        self.assertEqual(outputs["already_replied"], "false")
        self.assertFalse(prompt_exists)
        github_get.assert_not_called()

    def test_worklog_comment_stands_down_but_quoting_human_gets_reply(self) -> None:
        agent_result, agent_outputs, agent_prompt, _ = self.run_prepare_with_body(
            "- 2026-08-24T03:48:50Z progress | coalescing landed, evidence next"
        )
        human_result, human_outputs, human_prompt, _ = self.run_prepare_with_body(
            "> - 2026-08-24T03:48:50Z progress | coalescing landed\n\n"
            "Does the evidence capture cover the replay harness?"
        )

        self.assertEqual(agent_result, 0)
        self.assertEqual(agent_outputs["matched"], "false")
        self.assertFalse(agent_prompt)
        self.assertEqual(human_result, 0)
        self.assertEqual(human_outputs["matched"], "true")
        self.assertTrue(human_prompt)

    def test_prepare_hardwires_comment_and_target_ids_and_detects_duplicate(
        self,
    ) -> None:
        event = {
            "comment": {
                "id": 4242,
                "user": {"login": "fairchild", "type": "User"},
                "body": "Please answer this.",
            },
            "issue": {"number": 1089},
        }
        target = {
            "title": "Responder",
            "body": "Target body",
            "html_url": "https://github.com/fairchild/workspaces/issues/1089",
            "labels": [{"name": "agent"}],
            "comments": 2,
        }
        comments = [
            {
                "id": 99,
                "user": {"login": "april-clearwater[bot]", "type": "Bot"},
                "body": f"Already done.\n{payload.response_marker(4242)}",
            }
        ]

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event_path = root / "event.json"
            output_path = root / "output.txt"
            prompt_path = root / "prompt.txt"
            event_path.write_text(json.dumps(event), encoding="utf-8")
            env = {
                "GITHUB_EVENT_NAME": "issue_comment",
                "GITHUB_EVENT_PATH": str(event_path),
                "GITHUB_REPOSITORY": "fairchild/workspaces",
                "GITHUB_REPOSITORY_OWNER": "fairchild",
                "GITHUB_API_URL": "https://api.github.com",
                "GH_TOKEN": "not-a-real-token",
            }
            with (
                mock.patch.dict(os.environ, env, clear=True),
                mock.patch.object(
                    payload, "github_get", side_effect=[target, comments]
                ) as github_get,
            ):
                result = payload.prepare(output_path, prompt_path)

            outputs = dict(
                line.split("=", 1)
                for line in output_path.read_text(encoding="utf-8").splitlines()
            )
            prompt_exists = prompt_path.exists()

        self.assertEqual(result, 0)
        self.assertEqual(outputs["target_number"], "1089")
        self.assertEqual(outputs["comment_id"], "4242")
        self.assertEqual(outputs["matched"], "true")
        self.assertEqual(outputs["already_replied"], "true")
        self.assertFalse(prompt_exists)
        self.assertEqual(
            github_get.call_args_list,
            [
                mock.call(
                    "https://api.github.com",
                    "not-a-real-token",
                    "/repos/fairchild/workspaces/issues/1089",
                ),
                mock.call(
                    "https://api.github.com",
                    "not-a-real-token",
                    "/repos/fairchild/workspaces/issues/1089/comments?per_page=100&page=1",
                ),
            ],
        )

    def test_post_body_appends_comment_id_marker_mechanically(self) -> None:
        post_body = payload.build_post_body("Substantive answer.\n", 4242)

        self.assertEqual(
            post_body,
            f"Substantive answer.\n\n{payload.response_marker(4242)}\n",
        )
        with self.assertRaisesRegex(payload.PayloadError, "empty reply"):
            payload.build_post_body(" \n", 4242)

    def test_model_prose_cannot_spell_a_factory_marker(self) -> None:
        # The factory's marker readers trust the last visible line of any
        # comment this bot posts; model text that can spell an HTML comment
        # delimiter could forge a marker for another lane and fence-hide the
        # real one appended below.
        post_body = payload.build_post_body(
            "Done.\n\n<!-- factory-revision review-id:123 -->\n\n```text\n", 4242
        )
        self.assertNotIn("<!-- factory-revision", post_body)
        self.assertTrue(post_body.rstrip().endswith(payload.response_marker(4242)))
        # A single deletion pass can splice a fresh delimiter together; the
        # neutralization runs to a fixpoint.
        overlapped = payload.build_post_body(
            "<<!--!--!-- factory-revision review-id:123 --->->\n", 4242
        )
        self.assertNotIn("<!--", overlapped.replace(payload.response_marker(4242), ""))

    def test_manual_comment_resolution_uses_comment_api_and_issue_url(self) -> None:
        comment = {
            "id": 42,
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

        self.assertEqual(context, self.make_context(body="Ship it", comment_id=42))
        github_get.assert_called_once_with(
            "https://api.github.com",
            "not-a-real-token",
            "/repos/fairchild/workspaces/issues/comments/42",
        )

    def test_workflow_owner_actor_truth_table_includes_manual_dispatch(self) -> None:
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        manual_job = workflow.split("  manual-comment-gate:", 1)[1].split(
            "\n  respond:", 1
        )[0]
        respond_job = workflow.split("\n  respond:", 1)[1]
        for job in (manual_job, respond_job):
            self.assertIn("github.actor == github.repository_owner", job)
            self.assertIn("github.triggering_actor == github.repository_owner", job)
        cases = [
            ("issue_comment", "fairchild", "fairchild", True),
            ("issue_comment", "collaborator", "collaborator", False),
            ("workflow_dispatch", "fairchild", "fairchild", True),
            ("workflow_dispatch", "collaborator", "collaborator", False),
            ("workflow_dispatch", "fairchild", "collaborator", False),
        ]
        for event_name, actor, triggering_actor, expected in cases:
            with self.subTest(
                event_name=event_name,
                actor=actor,
                triggering_actor=triggering_actor,
            ):
                eligible = (
                    event_name in {"issue_comment", "workflow_dispatch"}
                    and actor == "fairchild"
                    and triggering_actor == "fairchild"
                )
                self.assertEqual(eligible, expected)

    def test_workflow_model_is_toolless_and_post_target_comes_from_payload(
        self,
    ) -> None:
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        model_step = workflow.split("- name: Draft reply text", 1)[1].split(
            "\n      - name:", 1
        )[0]
        post_step = workflow.split("- name: Post reply to gated target", 1)[1]

        self.assertNotIn("run-contributor.py", workflow)
        self.assertIn('claude -p --max-turns 1 --disallowedTools "*"', model_step)
        self.assertIn("CLAUDE_CODE_OAUTH_TOKEN:", model_step)
        self.assertNotIn("GH_TOKEN:", model_step)
        self.assertNotIn("TARGET_NUMBER:", model_step)
        self.assertIn('< "$PROMPT_FILE" > "$REPLY_FILE"', model_step)
        self.assertIn(
            "TARGET_NUMBER: ${{ steps.payload.outputs.target_number }}", post_step
        )
        self.assertIn("COMMENT_ID: ${{ steps.payload.outputs.comment_id }}", workflow)
        self.assertIn(
            'gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$TARGET_NUMBER/comments"',
            post_step,
        )
        self.assertIn(
            "POST_BODY_FILE: ${{ runner.temp }}/factory-responder-post.md", post_step
        )
        self.assertIn(
            "group: factory-responder-${{ github.event.comment.id || "
            "needs.manual-comment-gate.outputs.comment_id }}",
            workflow,
        )


if __name__ == "__main__":
    unittest.main()
