#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for the YAML frontmatter parser."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


fm = load_module(
    "parse_frontmatter",
    REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "parse-frontmatter.py",
)


class ParseFrontmatterTests(unittest.TestCase):
    def test_simple_frontmatter(self) -> None:
        text = "---\naction: comment\ndiscussion_number: 44\n---\n\nHello world"
        metadata, body = fm.parse_frontmatter(text)
        self.assertEqual(metadata, {"action": "comment", "discussion_number": 44})
        self.assertEqual(body, "Hello world")

    def test_all_value_types(self) -> None:
        text = (
            "---\n"
            "str_bare: hello\n"
            'str_quoted: "hello: world"\n'
            "num: 42\n"
            "neg_num: -7\n"
            "bool_t: true\n"
            "bool_f: false\n"
            "null_v: null\n"
            'list_v: [a, "b: c"]\n'
            "---\n\n"
            "Body"
        )
        metadata, body = fm.parse_frontmatter(text)
        self.assertEqual(metadata["str_bare"], "hello")
        self.assertEqual(metadata["str_quoted"], "hello: world")
        self.assertEqual(metadata["num"], 42)
        self.assertEqual(metadata["neg_num"], -7)
        self.assertIs(metadata["bool_t"], True)
        self.assertIs(metadata["bool_f"], False)
        self.assertIsNone(metadata["null_v"])
        self.assertEqual(metadata["list_v"], ["a", "b: c"])
        self.assertEqual(body, "Body")

    def test_empty_body(self) -> None:
        text = "---\naction: plan\n---"
        metadata, body = fm.parse_frontmatter(text)
        self.assertEqual(metadata["action"], "plan")
        self.assertEqual(body, "")

    def test_empty_body_trailing_newline(self) -> None:
        text = "---\naction: plan\n---\n"
        metadata, body = fm.parse_frontmatter(text)
        self.assertEqual(body, "")

    def test_quoted_string_with_colons(self) -> None:
        text = '---\npersona: "April Clearwater, Application Lead"\n---\n\nBody'
        metadata, body = fm.parse_frontmatter(text)
        self.assertEqual(metadata["persona"], "April Clearwater, Application Lead")

    def test_single_quoted_string(self) -> None:
        text = "---\ntitle: 'hello world'\n---\n"
        metadata, body = fm.parse_frontmatter(text)
        self.assertEqual(metadata["title"], "hello world")

    def test_bare_string_with_spaces(self) -> None:
        text = "---\npersona: April Clearwater, Application Lead\n---\n"
        metadata, body = fm.parse_frontmatter(text)
        self.assertEqual(metadata["persona"], "April Clearwater, Application Lead")

    def test_multiline_quoted_string(self) -> None:
        text = (
            "---\n"
            "action: execute_issue\n"
            'commit_message: "Fix something\n'
            "\n"
            "More details about the fix.\n"
            "\n"
            'Fixes #42"\n'
            "issue_number: 42\n"
            "---\n"
            "\n"
            "Body"
        )
        metadata, body = fm.parse_frontmatter(text)
        self.assertEqual(metadata["action"], "execute_issue")
        self.assertIn("Fix something", metadata["commit_message"])
        self.assertIn("More details", metadata["commit_message"])
        self.assertIn("Fixes #42", metadata["commit_message"])
        self.assertEqual(metadata["issue_number"], 42)
        self.assertEqual(body, "Body")

    def test_multiline_quoted_string_with_preamble(self) -> None:
        text = (
            "The implementation is complete.\n"
            "\n"
            "---\n"
            "action: execute_issue\n"
            "persona: April Clearwater\n"
            "issue_number: 116\n"
            'pr_title: "Fix status colors"\n'
            'commit_message: "Fix status colors\n'
            "\n"
            "Add severity enum.\n"
            "\n"
            'Fixes #116"\n'
            "---\n"
            "\n"
            "## Summary\n"
            "\n"
            "Details here."
        )
        metadata, body = fm.parse_frontmatter(text)
        self.assertEqual(metadata["action"], "execute_issue")
        self.assertEqual(metadata["issue_number"], 116)
        self.assertIn("Fix status colors", metadata["commit_message"])
        self.assertIn("Fixes #116", metadata["commit_message"])
        self.assertIn("Summary", body)

    def test_multiline_with_escaped_quotes(self) -> None:
        """Escaped quotes inside a multi-line string must not close it early."""
        text = (
            "---\n"
            'commit_message: "He said \\"hello\\"\n'
            'and then \\"goodbye\\""\n'
            "issue_number: 1\n"
            "---\n"
        )
        metadata, _ = fm.parse_frontmatter(text)
        self.assertIn('said \\"hello\\"', metadata["commit_message"])
        self.assertIn('goodbye\\"', metadata["commit_message"])
        self.assertEqual(metadata["issue_number"], 1)

    def test_unterminated_multiline_raises(self) -> None:
        """A multi-line quoted string that never closes must raise."""
        text = (
            "---\n"
            'commit_message: "This never closes\n'
            "more text\n"
            "---\n"
        )
        with self.assertRaises(ValueError):
            fm.parse_frontmatter(text)

    def test_closed_quote_with_trailing_whitespace(self) -> None:
        """Trailing whitespace after a closing quote must not trigger multi-line."""
        text = '---\ntitle: "hello world"  \n---\n'
        metadata, _ = fm.parse_frontmatter(text)
        self.assertEqual(metadata["title"], "hello world")

    def test_no_frontmatter_raises(self) -> None:
        with self.assertRaises(ValueError):
            fm.parse_frontmatter("just plain text")

    def test_no_closing_delimiter_raises(self) -> None:
        with self.assertRaises(ValueError):
            fm.parse_frontmatter("---\nkey: value\nno closing")

    def test_empty_inline_list(self) -> None:
        text = "---\nlabels: []\n---\n"
        metadata, _ = fm.parse_frontmatter(text)
        self.assertEqual(metadata["labels"], [])

    def test_single_item_inline_list(self) -> None:
        text = "---\nlabels: [enhancement]\n---\n"
        metadata, _ = fm.parse_frontmatter(text)
        self.assertEqual(metadata["labels"], ["enhancement"])

    def test_block_list_values(self) -> None:
        text = (
            "---\n"
            "blocked_by:\n"
            "  - 1\n"
            "  - 2\n"
            "requested_evidence:\n"
            '  - "swift test"\n'
            '  - "screenshot"\n'
            "---\n"
        )
        metadata, _ = fm.parse_frontmatter(text)
        self.assertEqual(metadata["blocked_by"], [1, 2])
        self.assertEqual(metadata["requested_evidence"], ["swift test", "screenshot"])


class ParseMultiDocumentTests(unittest.TestCase):
    def test_peter_planner_format(self) -> None:
        text = (
            "---\n"
            "action: plan\n"
            "discussion_number: 44\n"
            "milestone_name: null\n"
            "---\n"
            "\n"
            "---\n"
            'title: "First issue title"\n'
            "labels: [enhancement]\n"
            "priority: 1\n"
            "---\n"
            "\n"
            "## Context\n"
            "Body one\n"
            "\n"
            "---\n"
            'title: "Second issue title"\n'
            'labels: [enhancement, "area: ui"]\n'
            "priority: 2\n"
            "---\n"
            "\n"
            "## Context\n"
            "Body two"
        )
        docs = fm.parse_multi_document(text)
        self.assertEqual(len(docs), 3)

        header, header_body = docs[0]
        self.assertEqual(header["action"], "plan")
        self.assertEqual(header["discussion_number"], 44)
        self.assertIsNone(header["milestone_name"])
        self.assertEqual(header_body, "")

        issue1_meta, issue1_body = docs[1]
        self.assertEqual(issue1_meta["title"], "First issue title")
        self.assertEqual(issue1_meta["labels"], ["enhancement"])
        self.assertEqual(issue1_meta["priority"], 1)
        self.assertIn("Body one", issue1_body)

        issue2_meta, issue2_body = docs[2]
        self.assertEqual(issue2_meta["title"], "Second issue title")
        self.assertEqual(issue2_meta["labels"], ["enhancement", "area: ui"])
        self.assertEqual(issue2_meta["priority"], 2)
        self.assertIn("Body two", issue2_body)

    def test_multi_document_with_block_list_metadata(self) -> None:
        text = (
            "---\n"
            "action: plan\n"
            "discussion_number: 110\n"
            "milestone_name: null\n"
            "---\n"
            "\n"
            "---\n"
            'title: "Issue title"\n'
            'labels: [enhancement, "area: ui"]\n'
            "priority: 1\n"
            "blocked_by:\n"
            "  - 7\n"
            "requested_evidence:\n"
            '  - "swift build"\n'
            '  - "swift test"\n'
            "---\n"
            "\n"
            "## Context\n"
            "Body\n"
        )
        docs = fm.parse_multi_document(text)
        self.assertEqual(len(docs), 2)
        issue_meta, issue_body = docs[1]
        self.assertEqual(issue_meta["blocked_by"], [7])
        self.assertEqual(issue_meta["requested_evidence"], ["swift build", "swift test"])
        self.assertIn("Body", issue_body)

    def test_single_document_via_multi(self) -> None:
        text = "---\naction: comment\n---\n\nBody text"
        docs = fm.parse_multi_document(text)
        self.assertEqual(len(docs), 1)
        self.assertEqual(docs[0][0]["action"], "comment")
        self.assertEqual(docs[0][1], "Body text")

    def test_body_with_hr_in_code_fence(self) -> None:
        text = (
            "---\n"
            "action: plan\n"
            "---\n"
            "\n"
            "---\n"
            "title: Issue\n"
            "---\n"
            "\n"
            "```markdown\n"
            "---\n"
            "```\n"
            "\n"
            "After fence"
        )
        docs = fm.parse_multi_document(text)
        self.assertEqual(len(docs), 2)
        self.assertIn("---", docs[1][1])
        self.assertIn("After fence", docs[1][1])

    def test_body_with_standalone_hr(self) -> None:
        """A bare --- in the body (not followed by YAML) is kept as body text."""
        text = (
            "---\n"
            "title: Issue\n"
            "---\n"
            "\n"
            "Before\n"
            "\n"
            "---\n"
            "\n"
            "After"
        )
        docs = fm.parse_multi_document(text)
        self.assertEqual(len(docs), 1)
        self.assertIn("Before", docs[0][1])
        self.assertIn("---", docs[0][1])
        self.assertIn("After", docs[0][1])

    def test_no_frontmatter_raises(self) -> None:
        with self.assertRaises(ValueError):
            fm.parse_multi_document("plain text with no delimiters")


class ReviewMetadataTests(unittest.TestCase):
    def test_block_mappings_lists_and_json_flow_are_review_only(self):
        for field, value, expected in (
            ("image_observations", '\n  - artifact_id: image-1\n    observation: "The label says: ready."',
             [{"artifact_id": "image-1", "observation": "The label says: ready."}]),
            ("image_observations", ' [{"artifact_id": "image-1", "observation": "Ready"}]',
             [{"artifact_id": "image-1", "observation": "Ready"}]),
            ("review_findings", '\n  version: 1\n  head_sha: abc\n  findings:\n    - category: code-defect\n      target: sample.py:4\n      requested_change: Keep focus',
             {"version": 1, "head_sha": "abc", "findings": [{"category": "code-defect", "target": "sample.py:4", "requested_change": "Keep focus"}]}),
        ):
            with self.subTest(field=field, value=value):
                metadata, _ = fm.parse_frontmatter(f"---\n{field}:{value}\n---\nReview")
                self.assertEqual(metadata[field], expected)
        metadata, _ = fm.parse_frontmatter('---\nlabels: [bug, "area: ui"]\n---')
        self.assertEqual(metadata["labels"], ["bug", "area: ui"])

    def test_duplicate_keys_indentation_and_bounds_fail_closed(self):
        values = [
            '\n  version: 1\n  version: 2',
            ' {"version": 1, "version": 2}',
            '\n  version: 1\n   head_sha: abc',
            '\n\tversion: 1',
            ' ' + '[' * 8 + '0' + ']' * 8,
            '\n' + '\n'.join('  ' * (i + 1) + f'level_{i}:' for i in range(8)),
            ' ' + '{"observation": "' + 'a' * 65536 + '"}',
            '\n' + '\n'.join('  key_%d: value' % i for i in range(257)),
        ]
        for value in values:
            with self.subTest(value=value[:80]), self.assertRaises(ValueError):
                fm.parse_frontmatter(f"---\nreview_findings:{value}\n---\nReview")
        with self.assertRaises(ValueError):
            fm.parse_frontmatter('---\nimage_observations: []\nimage_observations: []\n---')


if __name__ == "__main__":
    unittest.main()
