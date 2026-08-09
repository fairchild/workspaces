#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Contract tests for the subprocess-timeout tripwire (#1234)."""

from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "check-subprocess-timeouts.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


tripwire = load_module("check_subprocess_timeouts", SCRIPT)


def run_tripwire(root: Path) -> tuple[int, str]:
    stdout, stderr = io.StringIO(), io.StringIO()
    with redirect_stdout(stdout), redirect_stderr(stderr):
        code = tripwire.main(["--root", str(root)])
    return code, stdout.getvalue() + stderr.getvalue()


class SyntheticTreeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def write(self, relative: str, content: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def test_untimed_call_is_flagged_with_line_number(self) -> None:
        self.write(
            "Sources/App/Untimed.swift",
            "import Foundation\n\nlet r = try await ProcessRunner.run(\n"
            '    executable: "/usr/bin/true",\n    arguments: []\n)\n',
        )
        code, output = run_tripwire(self.root)
        self.assertEqual(code, 1)
        self.assertIn("Sources/App/Untimed.swift:3", output)

    def test_timed_call_passes(self) -> None:
        self.write(
            "Sources/App/Timed.swift",
            "let r = try await ProcessRunner.run(\n"
            '    executable: "/usr/bin/true",\n    timeout: 30\n)\n',
        )
        code, _ = run_tripwire(self.root)
        self.assertEqual(code, 0)

    def test_allowlisted_file_may_omit_timeout(self) -> None:
        self.write(
            "Sources/WorkspaceManagerCore/Services/LumeCLIRunner.swift",
            'let r = try await ProcessRunner.run(executable: "/usr/bin/true")\n',
        )
        code, _ = run_tripwire(self.root)
        self.assertEqual(code, 0)

    def test_timeout_inside_nested_call_does_not_count(self) -> None:
        self.write(
            "Sources/App/Nested.swift",
            "let r = try await ProcessRunner.run(\n"
            "    executable: resolve(timeout: 5),\n    arguments: []\n)\n",
        )
        code, output = run_tripwire(self.root)
        self.assertEqual(code, 1)
        self.assertIn("Sources/App/Nested.swift:1", output)

    def test_timeout_at_top_level_with_nested_arguments_counts(self) -> None:
        self.write(
            "Sources/App/NestedOK.swift",
            "let r = try await ProcessRunner.run(\n"
            '    executable: "/usr/bin/git",\n'
            '    arguments: ["log", format(count)],\n'
            "    timeout: budget(for: repo)\n)\n",
        )
        code, _ = run_tripwire(self.root)
        self.assertEqual(code, 0)

    def test_mentions_in_comments_and_strings_are_ignored(self) -> None:
        self.write(
            "Sources/App/CommentOnly.swift",
            "// `ProcessRunner.run(executable:)` hangs without a timeout\n"
            "/* ProcessRunner.run( */\n"
            'let hint = "ProcessRunner.run(executable: x)"\n'
            'let doc = """\n    ProcessRunner.run(executable: y)\n    """\n',
        )
        code, _ = run_tripwire(self.root)
        self.assertEqual(code, 0)

    def test_timeout_inside_string_does_not_satisfy_check(self) -> None:
        self.write(
            "Sources/App/StringTimeout.swift",
            'let r = try await ProcessRunner.run(executable: "timeout: 30")\n',
        )
        code, output = run_tripwire(self.root)
        self.assertEqual(code, 1)
        self.assertIn("Sources/App/StringTimeout.swift:1", output)

    def test_missing_sources_directory_is_an_error(self) -> None:
        code, output = run_tripwire(self.root)
        self.assertEqual(code, 2)
        self.assertIn("no Sources/ directory", output)


class RepoTests(unittest.TestCase):
    def test_repo_is_green(self) -> None:
        code, output = run_tripwire(REPO_ROOT)
        self.assertEqual(code, 0, output)

    def test_allowlist_entries_exist_in_repo(self) -> None:
        # A renamed file silently drops out of the allowlist; this keeps the
        # list pointing at real files so that failure mode stays loud.
        for relative in sorted(tripwire.ALLOWLIST):
            self.assertTrue((REPO_ROOT / relative).is_file(), relative)


if __name__ == "__main__":
    unittest.main()
