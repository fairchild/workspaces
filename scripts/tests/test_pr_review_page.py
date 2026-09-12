#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Contract tests for the per-PR review page generator.

Intent: hold the shape a reader depends on -- five sections in a fixed order,
hunks filed under the sentence that explains them, evidence images shown rather
than linked -- and the one destructive thing the generator does, editing a PR
body, held to inserting a single line and leaving every other byte alone.

Everything builds from recorded fixtures (`fixtures/pr-review-page/`), so no
test here reaches the network, `gh`, or a live PR.
"""

from __future__ import annotations

import importlib.util
import re
import sys
import unittest
import unittest.mock
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "pr-review-page.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "pr-review-page"
SPECIMEN = FIXTURES / "1602"
SYNTHETIC = FIXTURES / "synthetic"


def _load_generator():
    """The generator module, or None while it does not exist yet.

    Returning None rather than raising at import keeps the red run readable:
    every test reports the missing script by name instead of the whole file
    erroring out on a traceback.
    """
    if not SCRIPT_PATH.is_file():
        return None
    spec = importlib.util.spec_from_file_location("pr_review_page", SCRIPT_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    # Registered before execution because `@dataclass` resolves annotations
    # through `sys.modules[cls.__module__]`, which is not there yet otherwise.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


pr_review_page = _load_generator()


class GeneratorTestCase(unittest.TestCase):
    # Building a page renders its diagram, and where `mmdc` is installed that is
    # a real browser render. Unmodified builds are shared across tests so the
    # suite pays for two of them rather than one per assertion.
    _pages: dict[Path, str] = {}

    def setUp(self) -> None:
        if pr_review_page is None:
            self.fail(f"the generator does not exist yet: {SCRIPT_PATH}")

    def page(self, fixture: Path) -> str:
        if fixture not in self._pages:
            self._pages[fixture] = pr_review_page.build_page(pr_review_page.load_fixture(fixture))
        return self._pages[fixture]

    def source(self, fixture: Path):
        return pr_review_page.load_fixture(fixture)


class PageShape(GeneratorTestCase):
    def test_the_five_sections_appear_in_the_reading_order(self) -> None:
        page = self.page(SPECIMEN)
        positions = []
        for heading in pr_review_page.SECTIONS:
            index = page.find(heading)
            self.assertNotEqual(index, -1, f"section missing from the page: {heading}")
            positions.append(index)
        self.assertEqual(
            positions,
            sorted(positions),
            f"sections are out of order: {pr_review_page.SECTIONS}",
        )
        self.assertEqual(len(pr_review_page.SECTIONS), 5)

    def test_the_page_carries_no_external_asset_but_mermaid(self) -> None:
        page = self.page(SPECIMEN)
        self.assertNotIn("<link", page, "a stylesheet link means the page is not self-contained")
        for src in re.findall(r'<script[^>]+src="([^"]+)"', page):
            self.assertTrue(
                src.startswith("https://cdnjs.cloudflare.com/"),
                f"unexpected external script: {src}",
            )

    def test_pr_body_markup_cannot_reach_the_page_unescaped(self) -> None:
        source = self.source(SYNTHETIC)
        source.pr["body"] = source.pr["body"].replace(
            "## Summary",
            "## Summary\n- <script>alert('xss')</script> is only text.",
        )
        page = pr_review_page.build_page(source)
        self.assertNotIn("<script>alert('xss')</script>", page)
        self.assertIn("&lt;script&gt;", page)

    def test_a_head_that_is_not_the_prs_head_is_refused(self) -> None:
        source = self.source(SPECIMEN)
        with self.assertRaises(ValueError):
            pr_review_page.build_page(source, head="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")

    def test_the_page_states_the_head_it_was_built_from(self) -> None:
        page = self.page(SPECIMEN)
        self.assertIn("d13afd8e", page)


class PlainLanguage(GeneratorTestCase):
    def test_it_is_about_five_lines_of_prose_without_paths_or_code_spans(self) -> None:
        source = self.source(SPECIMEN)
        lines = pr_review_page.plain_language(source.pr)
        self.assertTrue(lines, "the plain-language opening is empty")
        self.assertLessEqual(len(lines), 5)
        for line in lines:
            self.assertNotIn("`", line, f"code span survived into plain language: {line}")
            self.assertNotIn("Sources/", line, f"file path survived into plain language: {line}")
            self.assertNotIn("Tests/", line, f"file path survived into plain language: {line}")

    def test_it_opens_from_the_summarys_own_first_sentences(self) -> None:
        source = self.source(SPECIMEN)
        lines = pr_review_page.plain_language(source.pr)
        self.assertTrue(lines[0].startswith("Named the shared state"), lines[0])
        self.assertIn("UserDefaults.standard", lines[0])
        self.assertNotIn("which is exactly the two-worktree repro", lines[0])

    def test_a_block_below_the_bullets_is_not_read_out_as_prose(self) -> None:
        """An indented diagram after the list is indented like a continuation.

        Folding it into the last bullet put mermaid edge syntax into the page's
        opening sentences.
        """
        lines = pr_review_page.plain_language(self.source(SYNTHETIC).pr)
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[1].endswith("fails closed."), lines[1])
        self.assertNotIn("-->", lines[1])

    def test_a_body_with_no_summary_falls_back_to_the_title(self) -> None:
        source = self.source(SYNTHETIC)
        source.pr["body"] = "*Bench Persona, Fixture Lead*\n\nNo summary here.\n"
        lines = pr_review_page.plain_language(source.pr)
        self.assertEqual(lines, [source.pr["title"]])


class DiffByConcern(GeneratorTestCase):
    def test_a_summary_bullet_claims_the_hunks_that_name_its_symbols(self) -> None:
        source = self.source(SPECIMEN)
        groups = pr_review_page.group_hunks(source)
        by_heading = {group.heading: group for group in groups}
        shared_state = next(h for h in by_heading if h.startswith("Named the shared state"))
        self.assertTrue(
            any(
                hunk.path.endswith("WorkspaceService.swift")
                for hunk in by_heading[shared_state].hunks
            ),
            "the bullet that names WorkspaceService.swift claimed none of its hunks",
        )
        isolated = next(h for h in by_heading if "makeIsolatedPreferences" in h or "injectable" in h)
        self.assertTrue(
            any("makeIsolatedPreferences" in hunk.body for hunk in by_heading[isolated].hunks),
            "the bullet that introduces makeIsolatedPreferences claimed no hunk adding it",
        )

    def test_every_hunk_is_filed_exactly_once(self) -> None:
        source = self.source(SPECIMEN)
        groups = pr_review_page.group_hunks(source)
        filed = [(hunk.path, hunk.header) for group in groups for hunk in group.hunks]
        self.assertEqual(len(filed), len(set(filed)), "a hunk was filed under two headings")
        self.assertEqual(len(filed), source.diff.count("\n@@ "), "hunks went missing")

    def test_an_unnamed_file_falls_under_everything_else(self) -> None:
        source = self.source(SYNTHETIC)
        groups = pr_review_page.group_hunks(source)
        leftovers = next(g for g in groups if g.heading == pr_review_page.EVERYTHING_ELSE)
        self.assertEqual([hunk.path for hunk in leftovers.hunks], ["docs/notes.md"])
        claimed = [hunk.path for g in groups if g is not leftovers for hunk in g.hunks]
        self.assertIn("src/config.py", claimed)
        self.assertNotIn("docs/notes.md", claimed)

    def test_everything_else_is_absent_when_every_hunk_is_claimed(self) -> None:
        source = self.source(SPECIMEN)
        headings = [group.heading for group in pr_review_page.group_hunks(source)]
        self.assertNotIn(pr_review_page.EVERYTHING_ELSE, headings)

    def test_each_group_opens_with_the_sentence_it_serves(self) -> None:
        page = self.page(SYNTHETIC)
        self.assertIn("Named the bad key", page)
        self.assertIn("parse_config", page)


class Diagram(GeneratorTestCase):
    def test_a_diagram_in_the_body_is_the_one_rendered(self) -> None:
        page = self.page(SYNTHETIC)
        self.assertIn("named key error", page)
        self.assertNotIn("review-page:diagram", page)

    def test_the_fence_under_the_marker_is_the_carrier(self) -> None:
        diagram = pr_review_page.diagram_source(self.source(SYNTHETIC))
        self.assertIn("parse_config", diagram)
        self.assertIn("named key error", diagram)

    def test_a_diagram_inside_an_html_comment_is_ignored(self) -> None:
        """Where a comment ends is not one answer, so it carries nothing.

        A browser ends a comment at `--!>` as well as at `-->`, and a mermaid
        edge is `-->`. Any parser that reads a comment for content disagrees
        with the renderer about where the content stopped, and the text after
        the disagreement is prose in the PR body and diagram source here
        (`py/bad-tag-filter`). The marker plus a fence has one reading.
        """
        source = self.source(SYNTHETIC)
        source.pr["body"] = (
            "## Summary\n- One thing.\n\n"
            "<!-- review-page:diagram\n```mermaid\ngraph LR\n  a --> b\n```\n-->\n"
        )
        diagram = pr_review_page.diagram_source(source)
        self.assertNotIn("graph LR", diagram)
        self.assertTrue(diagram.startswith("graph TD"), diagram)

    def test_the_marker_needs_its_fence(self) -> None:
        source = self.source(SYNTHETIC)
        source.pr["body"] = "## Summary\n- One thing.\n\n<!-- review-page:diagram -->\ngraph LR\n  a --> b\n"
        self.assertTrue(pr_review_page.diagram_source(source).startswith("graph TD"))

    def test_a_hostile_label_cannot_become_markup(self) -> None:
        """The mermaid source is a PR body's text, wherever it lands."""
        source = self.source(SYNTHETIC)
        source.pr["body"] = (
            "## Summary\n- One thing.\n\n"
            '<!-- review-page:diagram -->\n```mermaid\ngraph LR\n'
            '  a["<script>alert(1)</script>"] --> b\n```\n'
        )
        page = pr_review_page.build_page(source)
        self.assertNotIn("<script>alert(1)</script>", page)

        # And on the path CI takes, where no local renderer exists and the
        # source is handed to the browser as text.
        with unittest.mock.patch.object(pr_review_page.shutil, "which", return_value=None):
            fallback = pr_review_page.render_diagram('graph LR\n  a["<script>alert(1)</script>"]')
        self.assertNotIn("<script>alert(1)</script>", fallback)
        self.assertIn("&lt;script&gt;", fallback)

    def test_without_one_the_generated_graph_names_the_files_and_the_issue(self) -> None:
        source = self.source(SPECIMEN)
        diagram = pr_review_page.diagram_source(source)
        self.assertIn("WorkspaceService.swift", diagram)
        self.assertIn("WorkspaceServiceTests.swift", diagram)
        self.assertIn("#1536", diagram)


class Evidence(GeneratorTestCase):
    def test_an_evidence_image_is_shown_not_linked(self) -> None:
        page = self.page(SYNTHETIC)
        self.assertIn('<img src="https://evidence.example.com/workspaces/pr-99/after.png"', page)

    def test_a_non_image_evidence_link_is_listed(self) -> None:
        page = self.page(SYNTHETIC)
        self.assertIn('href="https://evidence.example.com/workspaces/pr-99/run.txt"', page)

    def test_a_named_test_command_keeps_the_line_it_printed(self) -> None:
        page = self.page(SPECIMEN)
        self.assertIn("swift test --filter WorkspaceServiceTests", page)
        self.assertIn("Test run with 46 tests in 1 suite passed after 1.441 seconds.", page)

    def test_the_synthetic_commands_survive_too(self) -> None:
        page = self.page(SYNTHETIC)
        self.assertIn("python3 -m pytest tests/test_config.py", page)
        self.assertIn("12 passed in 0.30s", page)


class WhereItStands(GeneratorTestCase):
    def test_reviewers_appear_with_their_verdicts(self) -> None:
        page = self.page(SPECIMEN)
        self.assertIn("workspace-agents", page)
        self.assertIn("approved", page.lower())

    def test_a_red_check_is_named_not_averaged_away(self) -> None:
        page = self.page(SYNTHETIC)
        self.assertIn("readiness", page)
        self.assertIn("Failure", page)

    def test_a_check_that_was_re_run_green_is_not_still_red(self) -> None:
        """#1602's `readiness` failed at 11:55 and passed at 12:41.

        A page that reports the first run leaves the reader chasing a failure
        that no longer exists, so only each check's latest run counts.
        """
        page = self.page(SPECIMEN)
        self.assertNotIn("readiness: Failure", page)
        self.assertIn("Checks:", page)

    def test_an_open_thread_is_listed_and_a_resolved_one_is_not(self) -> None:
        page = self.page(SYNTHETIC)
        self.assertIn("Should the message name every missing key", page)
        self.assertNotIn("Typo in the note.", page)


class BodyLink(GeneratorTestCase):
    URL = "https://evidence.cloudcompute.com/workspaces/pr-1602/abc/1602.html"

    def test_the_line_follows_the_byline(self) -> None:
        body = self.source(SPECIMEN).pr["body"]
        linked = pr_review_page.body_with_link(body, self.URL)
        lines = linked.splitlines()
        self.assertEqual(lines[0], "*April Clearwater, Application Lead*")
        self.assertEqual(
            next(line for line in lines[1:] if line.strip()),
            f"Review page: {self.URL}",
        )

    def test_the_rest_of_the_body_is_byte_identical(self) -> None:
        """The only new bytes are the line and the blank that separates it.

        The blank is not cosmetic: without it Markdown folds the link into the
        byline's paragraph and the reader gets one run-on line.
        """
        body = self.source(SPECIMEN).pr["body"]
        linked = pr_review_page.body_with_link(body, self.URL)
        self.assertEqual(linked.replace(f"Review page: {self.URL}\n\n", "", 1), body)

    def test_the_hidden_evidence_status_block_survives_untouched(self) -> None:
        body = self.source(SPECIMEN).pr["body"]
        block = body[body.index("<!-- evidence-status:v1") : body.index("-->\n\n## Evidence Status")]
        linked = pr_review_page.body_with_link(body, self.URL)
        self.assertIn(block, linked)

    def test_relinking_rewrites_the_line_rather_than_adding_one(self) -> None:
        body = self.source(SPECIMEN).pr["body"]
        once = pr_review_page.body_with_link(body, self.URL)
        twice = pr_review_page.body_with_link(once, self.URL + "?v=2")
        self.assertEqual(twice.count("Review page: "), 1)
        self.assertIn(f"Review page: {self.URL}?v=2", twice)

    def test_a_body_with_no_byline_takes_the_line_at_the_top(self) -> None:
        linked = pr_review_page.body_with_link("## Summary\n- One thing.\n", self.URL)
        self.assertEqual(linked.splitlines()[0], f"Review page: {self.URL}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
