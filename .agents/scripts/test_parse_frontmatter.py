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


if __name__ == "__main__":
    unittest.main()
