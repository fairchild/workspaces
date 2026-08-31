#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for the release notes Sparkle shows in the update dialog.

Sparkle renders the appcast item <description> verbatim, so whatever
generate-sparkle-appcast.sh emits is what a user reads when they choose Check
for Updates. These tests pin two things: the inline markdown the changelog uses
renders to HTML rather than reaching the dialog as literal asterisks and
backticks (#1343), and verify-sparkle-appcast.swift fails a release whose notes
still carry raw markup.

Safe to run without network, secrets, UI access, or live GitHub mutation. The
renderer runs through the script's --notes-only mode, which needs no DMG, app
bundle, or signing key. Tests that shell out to Swift skip off macOS.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
GENERATOR = REPO_ROOT / "scripts" / "generate-sparkle-appcast.sh"
VERIFIER = REPO_ROOT / "scripts" / "verify-sparkle-appcast.swift"
CHANGELOG = REPO_ROOT / "CHANGELOG.md"

# What "unrendered" looks like in the dialog. Kept in step with
# unrenderedMarkdownMarkers in verify-sparkle-appcast.swift.
RAW_MARKDOWN_MARKERS = ("**", "`", "](")


def render(section: str, version: str = "9.9.9") -> str:
    """The release-notes HTML for a changelog section, as the appcast embeds it."""
    with tempfile.TemporaryDirectory() as tmpdir:
        changelog = Path(tmpdir) / "CHANGELOG.md"
        changelog.write_text(
            f"# Changelog\n\n## [{version}] - 2026-01-01\n\n{textwrap.dedent(section).strip()}\n",
            encoding="utf-8",
        )
        return render_from(changelog, version)


def render_from(changelog: Path, version: str) -> str:
    result = subprocess.run(
        [str(GENERATOR), "--notes-only", "--version", version, "--changelog", str(changelog)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(f"--notes-only failed for {version}: {result.stderr}")
    return result.stdout


class InlineMarkdownRenderingTests(unittest.TestCase):
    """The subset the changelog actually writes reaches Sparkle as HTML."""

    def test_bold_code_and_links_render(self) -> None:
        html = render(
            "Gains a **Recent** arrangement with a `repo / workspace` "
            "breadcrumb, see [the docs](https://example.com/docs)."
        )

        self.assertIn("<strong>Recent</strong>", html)
        self.assertIn("<code>repo / workspace</code>", html)
        self.assertIn('<a href="https://example.com/docs">the docs</a>', html)

    def test_markdown_renders_inside_headings_and_list_items(self) -> None:
        html = render(
            """
            ### Added
            - pin workspaces to a **Pinned** section (#1339)
            - cap lingering pages in `SurfaceStore` (#849)
            """
        )

        self.assertIn("<li>pin workspaces to a <strong>Pinned</strong> section (#1339)</li>", html)
        self.assertIn("<li>cap lingering pages in <code>SurfaceStore</code> (#849)</li>", html)

    def test_nested_and_repeated_spans_render(self) -> None:
        html = render("Both **bold with `code` inside** and `SurfaceStore` plus `TileTreeStore`.")

        self.assertIn("<strong>bold with <code>code</code> inside</strong>", html)
        self.assertIn("<code>SurfaceStore</code>", html)
        self.assertIn("<code>TileTreeStore</code>", html)

    def test_soft_wrapped_prose_becomes_one_paragraph(self) -> None:
        """Changelog prose wraps for GitHub; a <p> per source line renders the
        intro as a column of fragments in the update dialog."""
        html = render(
            """
            The sidebar gains a **Recent** arrangement: a flat list of
            the workspaces you are actually working in, each row carrying
            its repo as a breadcrumb.
            """
        )

        self.assertEqual(html.count("<p>"), 1)
        self.assertIn(
            "<p>The sidebar gains a <strong>Recent</strong> arrangement: a flat list of "
            "the workspaces you are actually working in, each row carrying "
            "its repo as a breadcrumb.</p>",
            html,
        )

    def test_blank_line_starts_a_new_paragraph(self) -> None:
        html = render(
            """
            First paragraph.

            Second paragraph.
            """
        )

        self.assertEqual(html.count("<p>"), 2)


class UnsupportedMarkupTests(unittest.TestCase):
    """Markup the renderer does not claim stays literal rather than being guessed at."""

    def test_unpaired_markers_stay_literal(self) -> None:
        html = render("Unclosed **bold and a lone ` backtick.")

        self.assertIn("Unclosed **bold and a lone ` backtick.", html)
        self.assertNotIn("<strong>", html)
        self.assertNotIn("<code>", html)

    def test_single_asterisk_and_underscore_are_not_emphasis(self) -> None:
        html = render("Single *asterisk* and _underscore_ pass through.")

        self.assertIn("Single *asterisk* and _underscore_ pass through.", html)
        self.assertNotIn("<em>", html)

    def test_non_web_link_schemes_stay_literal(self) -> None:
        """Sparkle renders the description in a web view, so only http(s) and
        mailto become anchors."""
        html = render("Bad scheme [click](javascript:alert(1)) and [f](file:///etc/passwd).")

        self.assertNotIn("<a ", html)
        self.assertIn("[click](javascript:alert(1))", html)
        self.assertIn("[f](file:///etc/passwd)", html)


class HTMLEscapingTests(unittest.TestCase):
    """Escaping runs before rendering, so emitted tags are the only markup."""

    def test_html_in_the_changelog_is_neutralized(self) -> None:
        html = render('An <script>alert("x")</script> tag & an ampersand.')

        self.assertIn("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;", html)
        self.assertIn("&amp; an ampersand", html)
        self.assertNotIn("<script>", html)

    def test_link_url_is_escaped_in_the_href(self) -> None:
        html = render("See [it](https://example.com/a?x=1&y=2).")

        self.assertIn('<a href="https://example.com/a?x=1&amp;y=2">it</a>', html)

    def test_html_inside_a_code_span_is_neutralized(self) -> None:
        html = render("Run `<script>` carefully.")

        self.assertIn("<code>&lt;script&gt;</code>", html)


class ChangelogIsAppcastSafeTests(unittest.TestCase):
    """Every section of the real changelog renders without leftover markup.

    The acceptance case for #1343 is the v0.25.0 intro, but the guard is
    repo-wide: a future section that reaches for markup this renderer does not
    support fails here rather than in a user's update dialog.
    """

    def changelog_versions(self) -> list[str]:
        versions = [
            line.split("[", 1)[1].split("]", 1)[0]
            for line in CHANGELOG.read_text(encoding="utf-8").splitlines()
            if line.startswith("## [") and "] - " in line
        ]
        self.assertGreater(len(versions), 1, "CHANGELOG.md has no parseable version sections")
        return versions

    def test_v0_25_0_intro_renders_the_reported_markup(self) -> None:
        html = render_from(CHANGELOG, "0.25.0")

        self.assertIn("<strong>Recent</strong>", html)
        self.assertIn("<strong>pinned</strong>", html)
        self.assertIn("<code>repo / workspace</code>", html)

    def test_no_section_leaves_raw_markdown(self) -> None:
        for version in self.changelog_versions():
            with self.subTest(version=version):
                html = render_from(CHANGELOG, version)
                for marker in RAW_MARKDOWN_MARKERS:
                    self.assertNotIn(
                        marker,
                        html,
                        f"CHANGELOG.md [{version}] renders with literal {marker!r}, which Sparkle "
                        "would show verbatim in the update dialog",
                    )


class VerifierRejectsUnrenderedMarkdownTests(unittest.TestCase):
    """verify-sparkle-appcast.swift is the release-time gate for the same rule."""

    # RFC 8032 Ed25519 test vector 1: signature over an empty message, matching
    # the empty DMG below, so the run reaches the release-notes check.
    PUBLIC_KEY = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
    SIGNATURE = (
        "5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7"
        "rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw=="
    )

    def setUp(self) -> None:
        if sys.platform != "darwin" or shutil.which("swift") is None:
            self.skipTest("verify-sparkle-appcast.swift imports CryptoKit, which is Apple-only")

    def run_verifier(self, notes: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            dmg = tmp / "WorkSpaces-9.9.9.dmg"
            dmg.write_bytes(b"")
            appcast = tmp / "appcast.xml"
            appcast.write_text(
                f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:version>999</sparkle:version>
      <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
      <enclosure url="https://example.com/WorkSpaces-9.9.9.dmg" sparkle:edSignature="{self.SIGNATURE}" length="0" />
      <description><![CDATA[
{notes}
      ]]></description>
    </item>
  </channel>
</rss>
""",
                encoding="utf-8",
            )
            return subprocess.run(
                [
                    str(VERIFIER),
                    "--appcast",
                    str(appcast),
                    "--dmg",
                    str(dmg),
                    "--public-key",
                    self.PUBLIC_KEY,
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

    def test_rendered_notes_pass(self) -> None:
        result = self.run_verifier(
            "        <h2>WorkSpaces 9.9.9</h2>\n"
            "        <p>A <strong>Recent</strong> arrangement and a <code>breadcrumb</code>.</p>"
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_raw_bold_fails_the_release(self) -> None:
        result = self.run_verifier("        <p>A **Recent** arrangement.</p>")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrendered markdown **bold**", result.stderr)

    def test_raw_code_span_fails_the_release(self) -> None:
        result = self.run_verifier("        <p>A `breadcrumb` in the row.</p>")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrendered markdown `code`", result.stderr)

    def test_raw_link_fails_the_release(self) -> None:
        result = self.run_verifier("        <p>See [the docs](https://example.com).</p>")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrendered markdown [text](url)", result.stderr)

    def test_missing_release_notes_fail_the_release(self) -> None:
        result = self.run_verifier("")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no release-notes", result.stderr)


class NotesOnlyModeTests(unittest.TestCase):
    """--notes-only previews a release without a DMG, app bundle, or signing key."""

    def test_requires_a_version(self) -> None:
        result = subprocess.run(
            [str(GENERATOR), "--notes-only"],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--notes-only requires --version", result.stderr)

    def test_unknown_version_is_an_error(self) -> None:
        result = subprocess.run(
            [str(GENERATOR), "--notes-only", "--version", "0.0.0-nope"],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not contain release notes", result.stderr)


if __name__ == "__main__":
    unittest.main()
