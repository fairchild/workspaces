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

import base64
import html
import http.server
import importlib.util
import json
import re
import subprocess
import shutil
import tempfile
import threading
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

# `mmdc` is on a developer's machine and not on the hosted runner, so a test
# that asserts a drawn diagram asserts something CI cannot produce. These skip
# where it is absent; the path CI does take is a contract of its own, held by
# `test_without_a_renderer_the_page_shows_the_source_and_says_so`.
requires_renderer = unittest.skipUnless(
    shutil.which("mmdc"), "no local mermaid renderer (mmdc)"
)


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


class Policy(GeneratorTestCase):
    def test_the_policy_is_the_first_thing_in_the_head(self) -> None:
        """The page is untrusted text on an origin every artifact shares.

        A policy that arrives after something else in `<head>` is a policy that
        arrived after that thing could act.
        """
        page = self.page(SPECIMEN)
        head = page[page.index("<head>") : page.index("</head>")]
        first_meta = re.search(r"<meta[^>]*>", head)
        self.assertIsNotNone(first_meta)
        self.assertIn("Content-Security-Policy", first_meta.group(0))
        for directive in (
            "default-src 'none'",
            "img-src data: https:",
            "base-uri 'none'",
            "form-action 'none'",
        ):
            self.assertIn(directive, first_meta.group(0))

    def test_the_page_loads_nothing_from_anywhere(self) -> None:
        for fixture in (SPECIMEN, SYNTHETIC):
            page = self.page(fixture)
            self.assertNotIn("<script", page, "a script tag on a page whose policy forbids scripts")
            self.assertNotIn("<link", page)
            self.assertNotIn("cdnjs", page)
            for src in re.findall(r'src="([^"]+)"', page):
                self.assertTrue(
                    src.startswith(("data:image/", "https://")),
                    f"page reaches for {src}",
                )


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
    @requires_renderer
    def test_a_diagram_in_the_body_is_the_one_rendered(self) -> None:
        """The body's diagram is what gets drawn -- and drawn is the word.

        Its labels are pixels in the page, not text, which is the whole point of
        rendering to an image: nothing the source said survives as markup.
        """
        self.assertIn("named key error", pr_review_page.diagram_source(self.source(SYNTHETIC)))
        page = self.page(SYNTHETIC)
        self.assertNotIn("review-page:diagram", page)
        self.assertNotIn("named key error", page)

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

    def test_a_marker_nested_in_an_outer_comment_carries_nothing(self) -> None:
        """Comments do not nest, so GitHub shows this block and its fence to nobody.

        A page that draws it shows a diagram no reviewer can see in the body the
        page claims to front.
        """
        source = self.source(SYNTHETIC)
        source.pr["body"] = (
            "## Summary\n- One thing.\n\n"
            "<!--\n<!-- review-page:diagram -->\n```mermaid\ngraph LR\n"
            "  hidden --> payload\n```\n-->\n"
        )
        self.assertIsNotNone(
            pr_review_page.DIAGRAM_MARKER_RE.search(source.pr["body"]),
            "the fence pattern alone should still match; the guard is what refuses it",
        )
        diagram = pr_review_page.diagram_source(source)
        self.assertNotIn("payload", diagram)
        self.assertTrue(diagram.startswith("graph TD"), diagram)

    @requires_renderer
    def test_the_diagram_leaves_as_an_image_not_as_markup(self) -> None:
        page = self.page(SYNTHETIC)
        self.assertRegex(page, r'<img width="\d+" alt="Diagram of the change" src="data:image/png;base64,')
        self.assertNotIn("<svg", page)

    def test_without_a_renderer_the_page_shows_the_source_and_says_so(self) -> None:
        """The fallback is a contract, not a shrug.

        It is the path every hosted runner takes, so it is the one path a test
        must not need a renderer to check: the source is shown as escaped text,
        the page says it did not draw it, and nothing in that block can load,
        run, or fetch anything.
        """
        source = self.source(SYNTHETIC)
        with unittest.mock.patch.object(pr_review_page.shutil, "which", return_value=None):
            page = pr_review_page.build_page(source)

        shape = page[page.index('id="shape"') : page.index('<section id="diff"')]
        self.assertIn("No renderer was available", shape)
        self.assertIn("<pre>graph LR", shape)
        self.assertIn("--&gt;", shape, "the mermaid arrows should be escaped text")
        self.assertIn("parse_config", shape)
        for markup in ("<img", "<svg", "<script"):
            self.assertNotIn(markup, shape, f"{markup} in a block that only shows source")
        self.assertNotIn("<script", page)
        self.assertNotIn("<svg", page)

    @requires_renderer
    def test_the_renderer_reaches_no_network_during_a_build(self) -> None:
        """A diagram label can name a URL, and the renderer is a browser.

        The listener here is on loopback, which is the case an IP literal would
        slip past host-resolver rules alone, so it is the one worth proving.
        """
        hits: list[str] = []

        class Probe(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - http.server's spelling
                hits.append(self.path)
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.end_headers()

            def log_message(self, *_args: object) -> None:
                return

        server = http.server.HTTPServer(("127.0.0.1", 0), Probe)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            # Straight at the renderer, not through the page: the allowlist
            # refuses this syntax before mmdc ever sees it, and the sandbox is
            # the layer behind that one, which is what this asserts.
            drawn = pr_review_page.render_diagram(
                f'graph LR\n  a["<img src=\'http://127.0.0.1:{port}/probe\'>"] --> b',
                authored=False,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

        self.assertEqual(hits, [], f"the build fetched {hits} from a diagram's source")
        self.assertIn("data:image/png;base64,", drawn, "the diagram did not render at all")
        self.assertNotIn(f"127.0.0.1:{port}", drawn, "the URL survived into the page")

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


class AuthoredDiagramAllowlist(GeneratorTestCase):
    """An authored fence is drawn only if its syntax is provably harmless.

    mmdc renders from a `file://` page, so a bare path in an image shape or an
    HTML label resolves on the build host and is rasterised into the PNG the
    page publishes. Refusing the syntax is what closes that; sanitising the
    render is a race against mermaid's feature set.
    """

    def body_with(self, diagram: str) -> str:
        return f"## Summary\n- One thing.\n\n{pr_review_page.DIAGRAM_MARKER}\n```mermaid\n{diagram}\n```\n"

    def probe_png(self) -> Path:
        probe = Path(self.enterContext(tempfile.TemporaryDirectory())) / "probe.png"
        # 1x1 magenta PNG: something the build user can read at a known path.
        probe.write_bytes(base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        ))
        return probe

    def assertShownAsSource(self, page: str, needle: str) -> None:
        self.assertNotIn("data:image/png", page, "a refused diagram was rendered anyway")
        self.assertIn("No renderer", page + "not rendered")  # tolerated wording check below
        self.assertIn(html.escape(needle, quote=True), page)

    @requires_renderer
    def test_an_image_shape_naming_a_local_file_is_not_rendered(self) -> None:
        probe = self.probe_png()
        source = self.source(SYNTHETIC)
        source.pr["body"] = self.body_with(f'flowchart LR\n  A@{{ img: "{probe}" }}\n  A --> B')
        page = pr_review_page.build_page(source)
        self.assertNotIn("data:image/png", page)
        self.assertIn("@{", page)

    @requires_renderer
    def test_an_html_label_naming_a_local_file_is_not_rendered(self) -> None:
        probe = self.probe_png()
        source = self.source(SYNTHETIC)
        source.pr["body"] = self.body_with(f'graph LR\n  a["<img src=\'{probe}\'>"] --> b')
        page = pr_review_page.build_page(source)
        self.assertNotIn("data:image/png", page)
        self.assertIn("&lt;img", page)

    def test_the_allowlist_refuses_what_can_reach_a_file_or_a_browser(self) -> None:
        for diagram in (
            'flowchart LR\n  A@{ img: "/etc/hosts" }',
            'graph LR\n  a["<img src=x>"] --> b',
            'graph LR\n  a["../../secret.png"] --> b',
            'graph LR\n  a["file:///etc/hosts"] --> b',
            'graph LR\n  a --> b\n  click a "https://example.test"',
            'graph LR\n  a["<a href=\'x\'>y</a>"] --> b',
            '%%{init: {"securityLevel": "loose"}}%%\ngraph LR\n  a --> b',
            'graph LR\n  a["/absolute/path.png"] --> b',
            "not a diagram at all",
        ):
            with self.subTest(diagram=diagram.splitlines()[0]):
                self.assertFalse(
                    pr_review_page.is_renderable_mermaid(diagram),
                    f"allowlist admitted {diagram!r}",
                )

    def test_the_allowlist_admits_an_ordinary_shape_diagram(self) -> None:
        for diagram in (
            "graph LR\n  caller[caller] --> parse[parse_config]\n  parse --> named[named key error]",
            "flowchart TD\n  a --> b\n  b -.-> c",
            "sequenceDiagram\n  Alice->>Bob: asks\n  Bob-->>Alice: answers",
            "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Running",
        ):
            with self.subTest(diagram=diagram.splitlines()[0]):
                self.assertTrue(
                    pr_review_page.is_renderable_mermaid(diagram),
                    f"allowlist refused an ordinary diagram: {diagram!r}",
                )

    @requires_renderer
    def test_the_generated_graph_still_renders_though_its_labels_hold_slashes(self) -> None:
        """The generated graph is ours, and its labels are file paths.

        It does not go through the allowlist, which exists for text a stranger
        wrote; its labels are escaped by `_mermaid_label` instead.
        """
        source = self.source(SPECIMEN)
        page = pr_review_page.build_page(source)
        self.assertIn("data:image/png;base64,", page)


class HiddenContent(GeneratorTestCase):
    """What GitHub does not show, the page does not show either."""

    def test_a_summary_inside_a_comment_is_not_the_pages_opening(self) -> None:
        source = self.source(SYNTHETIC)
        source.pr["body"] = (
            "*Bench Persona, Fixture Lead*\n\n"
            "<!--\n## Summary\n- Hidden bullet nobody can see.\n-->\n\n"
            "## Summary\n- The visible bullet.\n"
        )
        page = pr_review_page.build_page(source)
        self.assertIn("The visible bullet.", page)
        self.assertNotIn("Hidden bullet", page)

    def test_an_image_inside_a_comment_is_never_fetched(self) -> None:
        source = self.source(SYNTHETIC)
        source.pr["body"] = (
            "## Summary\n- One thing.\n\n## Evidence\n"
            "<!--\n"
            "- ![hidden](https://tracker.example.test/pixel.png)\n"
            "- [hidden link](https://tracker.example.test/click)\n"
            "-->\n"
            "- ![shown](https://evidence.cloudcompute.com/ok.png)\n"
        )
        page = pr_review_page.build_page(source)
        self.assertNotIn("tracker.example.test", page)
        self.assertIn("evidence.cloudcompute.com/ok.png", page)

    def test_a_closes_reference_inside_a_comment_is_not_the_issue(self) -> None:
        source = self.source(SYNTHETIC)
        source.pr["body"] = "## Summary\n- One thing.\n\n<!-- Closes #4321 -->\n"
        self.assertIsNone(pr_review_page.closes_issue(source.pr["body"]))


class Evidence(GeneratorTestCase):
    def test_an_evidence_image_is_shown_not_linked(self) -> None:
        page = self.page(SYNTHETIC)
        self.assertIn('<img src="https://evidence.cloudcompute.com/workspaces/pr-99/after.png"', page)

    def test_a_non_image_evidence_link_is_listed(self) -> None:
        page = self.page(SYNTHETIC)
        self.assertIn('href="https://evidence.cloudcompute.com/workspaces/pr-99/run.txt"', page)

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


class Unavailable(GeneratorTestCase):
    """Three states, not two: present, none, and could-not-find-out."""

    def test_a_failed_thread_query_reports_unavailable_not_none(self) -> None:
        source = self.source(SYNTHETIC)
        source.threads = None
        page = pr_review_page.build_page(source)
        self.assertIn("Review threads: unavailable", page)
        self.assertNotIn("No open review threads.", page)

    def test_a_thread_query_that_raises_yields_unavailable(self) -> None:
        def explode(*_args: object, **_kwargs: object) -> str:
            raise RuntimeError("gh: API rate limit exceeded")

        with unittest.mock.patch.object(pr_review_page, "_run", explode):
            self.assertIsNone(pr_review_page.read_threads(99))

    def test_an_empty_thread_list_still_reports_none_open(self) -> None:
        source = self.source(SYNTHETIC)
        source.threads = []
        self.assertIn("No open review threads.", pr_review_page.build_page(source))

    def test_absent_reviews_and_checks_report_unavailable(self) -> None:
        source = self.source(SYNTHETIC)
        source.pr.pop("reviews")
        source.pr.pop("statusCheckRollup")
        page = pr_review_page.build_page(source)
        self.assertIn("Reviews: unavailable", page)
        self.assertIn("Checks: unavailable", page)
        self.assertNotIn("No reviews yet.", page)
        self.assertNotIn("No checks reported.", page)

    def test_empty_reviews_and_checks_still_report_none(self) -> None:
        source = self.source(SYNTHETIC)
        source.pr["reviews"] = []
        source.pr["statusCheckRollup"] = []
        page = pr_review_page.build_page(source)
        self.assertIn("No reviews yet.", page)
        self.assertIn("No checks reported.", page)


class Schemes(GeneratorTestCase):
    def test_only_web_addresses_become_links_and_images(self) -> None:
        """A prefix test is not a scheme test: `httpjavascript:` passes one."""
        source = self.source(SYNTHETIC)
        source.pr["body"] = (
            "## Summary\n- One thing.\n\n## Evidence\n"
            "- [one](javascript:alert1)\n"
            "- [two](httpjavascript:alert2)\n"
            "- ![three](javascript:alert3)\n"
            "- ![four](data:text/html;base64,PHNjcmlwdD4=)\n"
            "- [five](https://evidence.cloudcompute.com/ok.txt)\n"
            "- ![six](https://evidence.cloudcompute.com/ok.png)\n"
        )
        page = pr_review_page.build_page(source)
        for scheme in ("javascript:", "httpjavascript:", "data:text/html"):
            self.assertNotIn(f'href="{scheme}', page)
            self.assertNotIn(f'src="{scheme}', page)
        self.assertIn('href="https://evidence.cloudcompute.com/ok.txt"', page)
        self.assertIn('src="https://evidence.cloudcompute.com/ok.png"', page)
        # Refused is not hidden: the reader still sees what the body said.
        self.assertIn("javascript:alert1", page)

    def test_the_scheme_gate_is_a_parse_not_a_prefix(self) -> None:
        self.assertIsNone(pr_review_page._safe_url("httpjavascript:alert(1)"))
        self.assertIsNone(pr_review_page._safe_url("javascript:alert(1)"))
        self.assertIsNone(pr_review_page._safe_url("data:text/html,<script>"))
        self.assertEqual(pr_review_page._safe_url("https://x.test/a"), "https://x.test/a")
        self.assertEqual(pr_review_page._safe_url("http://x.test/a"), "http://x.test/a")


class Escaping(GeneratorTestCase):
    """The characters that matter, wherever PR text lands in the page."""

    DANGEROUS = ('"', "<", ">")

    def assertEscaped(self, page: str, raw: str) -> None:
        self.assertNotIn(raw, page)
        for character in self.DANGEROUS:
            if character in raw:
                self.assertIn(html.escape(character, quote=True), page)

    def test_a_hostile_title_cannot_break_out_of_its_element(self) -> None:
        source = self.source(SYNTHETIC)
        source.pr["title"] = '"><img src=x onerror=alert(1)>'
        page = pr_review_page.build_page(source)
        # The characters are shown; what must not exist is a tag made of them.
        self.assertEscaped(page, '"><img src=x onerror=alert(1)>')
        self.assertNotIn("<img src=x", page)

    def test_a_hostile_group_heading_is_escaped(self) -> None:
        source = self.source(SYNTHETIC)
        source.pr["body"] = (
            '## Summary\n- <img src=x onerror=alert(1)> in `src/config.py` is only text.\n'
        )
        page = pr_review_page.build_page(source)
        self.assertNotIn("<img src=x onerror=alert(1)>", page)
        self.assertIn("&lt;img", page)

    def test_a_hostile_filename_cannot_escape_a_mermaid_label(self) -> None:
        source = self.source(SYNTHETIC)
        source.pr["body"] = "## Summary\n- One thing.\n"
        source.pr["files"] = [{"path": 'src/a"]--x[b.py', "additions": 1, "deletions": 0}]
        diagram = pr_review_page.diagram_source(source)
        # `"]` legitimately closes every label; what must not survive is this
        # filename's own copy of it, which would close the label early.
        self.assertNotIn('a"]--x[b.py', diagram)
        self.assertIn("#quot;", diagram)
        self.assertIn("#93;", diagram)

    def test_markup_in_a_diff_hunk_is_escaped(self) -> None:
        source = self.source(SYNTHETIC)
        source.diff = (
            "diff --git a/src/config.py b/src/config.py\n"
            "--- a/src/config.py\n+++ b/src/config.py\n"
            '@@ -1,2 +1,3 @@\n context\n+<img src=x onerror="alert(1)">\n'
        )
        page = pr_review_page.build_page(source)
        self.assertNotIn('<img src=x onerror="alert(1)">', page)
        self.assertIn("&lt;img", page)

    def test_a_hostile_evidence_caption_is_escaped(self) -> None:
        source = self.source(SYNTHETIC)
        source.pr["body"] = (
            "## Summary\n- One thing.\n\n## Evidence\n"
            '- ![" onerror="alert(1)](https://evidence.cloudcompute.com/a.png)\n'
        )
        page = pr_review_page.build_page(source)
        self.assertNotIn('onerror="alert(1)"', page)
        self.assertIn("&quot;", page)


class QuotedMarkers(GeneratorTestCase):
    """A marker a reader sees as literal text is not a diagram either."""

    def diagram_for(self, body: str) -> str:
        source = self.source(SYNTHETIC)
        source.pr["body"] = body
        return pr_review_page.diagram_source(source)

    def test_a_marker_inside_a_fenced_example_is_not_drawn(self) -> None:
        body = (
            "## Summary\n- One thing.\n\n````text\n"
            f"{pr_review_page.DIAGRAM_MARKER}\n```mermaid\ngraph LR\n  quoted --> payload\n```\n"
            "````\n"
        )
        self.assertNotIn("payload", self.diagram_for(body))

    def test_a_marker_inside_cdata_is_not_drawn(self) -> None:
        body = (
            "## Summary\n- One thing.\n\n<![CDATA[\n"
            f"{pr_review_page.DIAGRAM_MARKER}\n```mermaid\ngraph LR\n  quoted --> payload\n```\n"
            "]]>\n"
        )
        self.assertNotIn("payload", self.diagram_for(body))

    def test_a_marker_inside_a_processing_instruction_is_not_drawn(self) -> None:
        body = (
            "## Summary\n- One thing.\n\n<?php\n"
            f"{pr_review_page.DIAGRAM_MARKER}\n```mermaid\ngraph LR\n  quoted --> payload\n```\n"
            "?>\n"
        )
        self.assertNotIn("payload", self.diagram_for(body))

    def test_the_ordinary_marker_still_works(self) -> None:
        body = (
            "## Summary\n- One thing.\n\n"
            f"{pr_review_page.DIAGRAM_MARKER}\n```mermaid\ngraph LR\n  a --> b\n```\n"
        )
        self.assertEqual(self.diagram_for(body), "graph LR\n  a --> b")


class HeadMoved(GeneratorTestCase):
    """Four calls build one page; they have to be four calls about one head."""

    def test_a_head_that_moves_between_the_body_and_the_diff_is_refused(self) -> None:
        calls = {"n": 0}

        def gh(argv, **_kwargs):
            calls["n"] += 1
            if "--json" in argv and "headRefOid" == argv[argv.index("--json") + 1]:
                return '{"headRefOid": "bbbbbbbbbbbb"}'
            if "diff" in argv:
                return "diff --git a/x b/x\n"
            return '{"headRefOid": "aaaaaaaaaaaa", "number": 99, "title": "t", "body": ""}'

        with unittest.mock.patch.object(pr_review_page, "_run", gh):
            with self.assertRaises(ValueError) as caught:
                pr_review_page.read_pr(99)
        self.assertIn("moved from aaaaaaaa to bbbbbbbb", str(caught.exception))

    def test_write_link_refuses_a_moved_head_before_touching_the_body(self) -> None:
        seen: list[list[str]] = []

        def gh(argv, **_kwargs):
            seen.append(argv)
            return '{"headRefOid": "bbbbbbbbbbbb"}'

        with unittest.mock.patch.object(pr_review_page, "_run", gh):
            with self.assertRaises(ValueError):
                pr_review_page.write_link(99, "https://x.test/p.html", "o/r", "aaaaaaaaaaaa")
        self.assertTrue(all("edit" not in argv for argv in seen), "the body was edited anyway")


class ThreadQuery(GeneratorTestCase):
    def test_a_payload_without_the_expected_shape_is_unavailable_not_a_crash(self) -> None:
        for payload in ('{"data": null}', '{"errors": [{"message": "gone"}]}', '{"data": {}}', "[]"):
            with self.subTest(payload=payload):
                with unittest.mock.patch.object(pr_review_page, "_run", lambda *a, **k: payload):
                    self.assertIsNone(pr_review_page.read_threads(99))

    def test_the_page_says_when_it_read_only_the_first_hundred(self) -> None:
        source = self.source(SYNTHETIC)
        source.threads = [
            {
                "isResolved": False,
                "path": f"src/f{index}.py",
                "line": index,
                "comments": {"nodes": [{"author": {"login": "someone"}, "body": "a note"}]},
            }
            for index in range(pr_review_page.THREAD_QUERY_CAP)
        ]
        page = pr_review_page.build_page(source)
        self.assertIn(f"Only the first {pr_review_page.THREAD_QUERY_CAP} review threads", page)

    def test_a_short_list_says_nothing_about_a_cap(self) -> None:
        self.assertNotIn("Only the first", self.page(SYNTHETIC))


class RendererWiring(GeneratorTestCase):
    """Runs everywhere, including where there is no renderer to run.

    The offline proof has two halves: that the flags work, which needs a
    browser, and that they are actually handed to one, which does not. CI can
    only ever see the second half, so the second half is asserted here.
    """

    def test_the_renderer_is_launched_with_the_network_closed(self) -> None:
        captured: dict[str, object] = {}

        def fake_run(argv, **_kwargs):
            captured["argv"] = argv
            config = Path(argv[argv.index("--puppeteerConfigFile") + 1])
            captured["puppeteer"] = json.loads(config.read_text())
            captured["mermaid"] = json.loads(Path(argv[argv.index("-c") + 1]).read_text())
            Path(argv[argv.index("-o") + 1]).write_bytes(
                base64.b64decode(
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
                )
            )
            return subprocess.CompletedProcess(argv, 0, "", "")

        with (
            unittest.mock.patch.object(pr_review_page.shutil, "which", return_value="/fake/mmdc"),
            unittest.mock.patch.object(pr_review_page.subprocess, "run", fake_run),
        ):
            drawn = pr_review_page.render_diagram("graph LR\n  a --> b", authored=False)

        self.assertIn("data:image/png;base64,", drawn)
        args = captured["puppeteer"]["args"]
        self.assertIn("--host-resolver-rules=MAP * ~NOTFOUND", args)
        self.assertIn("--proxy-server=127.0.0.1:1", args)
        self.assertIn("--proxy-bypass-list=<-loopback>", args)
        mermaid = captured["mermaid"]
        self.assertEqual(mermaid["securityLevel"], "strict")
        self.assertFalse(mermaid["htmlLabels"])
        self.assertIn("securityLevel", mermaid["secure"])


class ImageHosts(GeneratorTestCase):
    def test_the_policy_names_the_hosts_rather_than_all_of_https(self) -> None:
        page = self.page(SYNTHETIC)
        policy = re.search(r'content="([^"]*default-src[^"]*)"', page).group(1)
        self.assertNotIn("img-src data: https:;", policy)
        self.assertIn("https://evidence.cloudcompute.com", policy)

    def test_an_image_from_an_unlisted_host_is_named_not_fetched(self) -> None:
        source = self.source(SYNTHETIC)
        source.pr["body"] = (
            "## Summary\n- One thing.\n\n## Evidence\n"
            "- ![tracker](https://tracker.example.test/pixel.png)\n"
            "- ![plain](http://evidence.cloudcompute.com/a.png)\n"
        )
        page = pr_review_page.build_page(source)
        self.assertNotIn('<img src="https://tracker.example.test', page)
        self.assertNotIn('<img src="http://', page)
        self.assertIn("Image not shown", page)
        self.assertIn("tracker.example.test/pixel.png", page)


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

    def test_a_quoted_review_page_line_is_not_the_one_rewritten(self) -> None:
        """A body may talk about this line; talking about it is not having it.

        Rewriting a `Review page:` inside a comment or a fenced example edits
        that prose and leaves the body with no link a reader can see.
        """
        for hidden in (
            "<!--\nReview page: https://old.test/hidden.html\n-->",
            "```\nReview page: https://old.test/quoted.html\n```",
        ):
            with self.subTest(hidden=hidden.splitlines()[0]):
                body = f"*A Persona, Lead*\n\n{hidden}\n\n## Summary\n- One thing.\n"
                linked = pr_review_page.body_with_link(body, self.URL)
                self.assertIn(hidden, linked, "the quoted line was edited")
                visible = [
                    line for line in linked.splitlines()
                    if line.startswith("Review page: ") and self.URL in line
                ]
                self.assertEqual(len(visible), 1, linked)
                self.assertEqual(linked.splitlines()[0], "*A Persona, Lead*")

    def test_a_review_page_line_below_the_first_heading_is_left_alone(self) -> None:
        body = "*A Persona, Lead*\n\n## Summary\n- Review page: https://old.test/x.html\n"
        linked = pr_review_page.body_with_link(body, self.URL)
        self.assertIn("- Review page: https://old.test/x.html", linked)
        self.assertEqual(linked.splitlines()[2], f"Review page: {self.URL}")

    def test_a_body_with_no_byline_takes_the_line_at_the_top(self) -> None:
        linked = pr_review_page.body_with_link("## Summary\n- One thing.\n", self.URL)
        self.assertEqual(linked.splitlines()[0], f"Review page: {self.URL}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
