#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Release requests resume their own PR and preserve repository approval rules."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_entrypoint", ROOT / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseEntrypointTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.prs = [{"number": 9, "state": "OPEN", "url": "https://github.com/fairchild/workspaces/pull/9"}]
        self.pr = {**self.prs[0], "headRefOid": "a" * 40, "files": [{"path": p} for p in release.METADATA], "body": "<!-- release-entrypoint:0.28.0 -->"}

    def command(self, *args, **kwargs):
        self.calls.append(args)
        if args[:3] == ("gh", "repo", "view"):
            return "fairchild/workspaces"
        if args[:2] == ("gh", "api"):
            return json.dumps({"tag_name": "v0.27.0", "html_url": "https://github.com/fairchild/workspaces/releases/tag/v0.27.0"})
        if args[:2] == ("git", "log"):
            return "feat: new capability"
        if args[:3] == ("gh", "pr", "list"):
            return json.dumps(self.prs)
        if args[:3] == ("gh", "pr", "view"):
            return json.dumps(self.pr)
        return ""

    def invoke(self, *args):
        with patch.object(sys, "argv", ["release.py", "--version", "0.28.0", *args]), patch.object(release, "run", side_effect=self.command), contextlib.redirect_stdout(io.StringIO()) as output:
            release.main()
        return output.getvalue()

    def test_existing_request_enables_auto_merge_for_exact_head_without_admin(self):
        self.invoke()
        mutation = [a for a in self.calls if a[:3] == ("gh", "pr", "merge")]
        self.assertEqual(mutation, [("gh", "pr", "merge", "9", "--repo", "fairchild/workspaces", "--auto", "--squash", "--match-head-commit", "a" * 40)])
        self.assertFalse(any(a[:2] == ("git", "tag") or a[:2] == ("gh", "release") for a in self.calls))

    def test_merged_metadata_does_not_create_another_request_or_tag(self):
        self.prs[0]["state"] = "MERGED"
        self.assertIn("already merged", self.invoke())
        self.assertFalse(any(a[:3] in (("gh", "pr", "merge"), ("gh", "pr", "create")) for a in self.calls))

    def test_foreign_branch_content_cannot_gain_auto_merge(self):
        self.pr["files"].append({"path": "Sources/Unexpected.swift"})
        with self.assertRaisesRegex(ValueError, "metadata-only"):
            self.invoke()
        self.assertFalse(any(a[:3] == ("gh", "pr", "merge") for a in self.calls))

    def test_foreign_pr_identity_cannot_gain_auto_merge(self):
        self.pr["body"] = "Someone else's branch"
        with self.assertRaisesRegex(ValueError, "metadata-only"):
            self.invoke()

    def test_closed_or_ambiguous_request_is_not_recreated(self):
        self.prs[0]["state"] = "CLOSED"
        with self.assertRaisesRegex(ValueError, "closed"):
            self.invoke()
        self.prs.append(dict(self.prs[0]))
        with self.assertRaisesRegex(ValueError, "Multiple"):
            self.invoke()

    def test_status_is_read_only_and_dry_run_does_not_open_pr(self):
        for option in ("--status", "--dry-run"):
            self.calls.clear()
            self.invoke(option)
            self.assertFalse(any(a[:3] in (("gh", "pr", "create"), ("gh", "pr", "merge")) for a in self.calls))


if __name__ == "__main__":
    unittest.main()
