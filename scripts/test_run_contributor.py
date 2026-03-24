#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Stdlib tests for run-contributor evidence reconciliation."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "run-contributor.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


run_contributor = load_module("run_contributor", SCRIPT_PATH)


class RunContributorEvidenceTests(unittest.TestCase):
    maxDiff = None

    def test_reconcile_pending_ci_evidence_includes_uploaded_screenshot_links(self) -> None:
        body = "\n".join(
            [
                "## Evidence Status",
                "- [pending-ci] Post-setup screenshot -- CI evidence job will capture screenshot",
                "",
                "## Validation",
                "- blocked on evidence",
            ]
        )

        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            screenshot_upload_succeeded=True,
            screenshot_urls=[
                ("01-launch", "https://evidence.example/workspaces/pr-42/01-launch.png"),
                ("02-final", "https://evidence.example/workspaces/pr-42/02-final.png"),
            ],
        )

        self.assertIn(
            "- [complete] Post-setup screenshot -- captured on self-hosted macOS CI: "
            "[01-launch](https://evidence.example/workspaces/pr-42/01-launch.png), "
            "[02-final](https://evidence.example/workspaces/pr-42/02-final.png)",
            reconciled,
        )

    def test_reconcile_pending_ci_evidence_blocks_missing_screenshot_upload(self) -> None:
        body = "## Evidence Status\n- [pending-ci] Final screenshot -- CI evidence job will capture screenshot\n"

        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            screenshot_upload_succeeded=False,
            screenshot_urls=[],
        )

        self.assertEqual(
            reconciled,
            "## Evidence Status\n"
            "- [blocked] Final screenshot -- self-hosted macOS CI captured screenshots but R2 upload failed; "
            "see workflow artifacts\n",
        )

    def test_reconcile_pending_ci_evidence_blocks_missing_uploaded_urls(self) -> None:
        body = "## Evidence Status\n- [pending-ci] Final screenshot -- CI evidence job will capture screenshot\n"

        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            screenshot_upload_succeeded=True,
            screenshot_urls=[],
        )

        self.assertEqual(
            reconciled,
            "## Evidence Status\n"
            "- [blocked] Final screenshot -- self-hosted macOS CI captured screenshots but no R2 URLs were recorded; "
            "see workflow artifacts\n",
        )


class EvidenceValidationTests(unittest.TestCase):
    maxDiff = None

    def _make_body(
        self,
        evidence_lines: list[str],
        *,
        section: bool = True,
        validation: str = "",
    ) -> str:
        parts: list[str] = []
        if section:
            parts.append("## Evidence Status")
            parts.extend(evidence_lines)
        if validation:
            parts.append("")
            parts.append("## Validation")
            parts.append(validation)
        return "\n".join(parts)

    def test_malformed_lines_truncated(self) -> None:
        long_line = "- broken entry " + "x" * 200
        body = self._make_body([long_line, "- another broken line"])
        requested = ["`swift test --filter Foo`"]
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        malformed_errors = [e for e in errors if "malformed" in e]
        self.assertEqual(len(malformed_errors), 1)
        error = malformed_errors[0]
        # Should contain 'line 1:' with truncation
        self.assertIn('line 1:', error)
        self.assertIn('...', error)
        # Should NOT contain the full 200-char string
        self.assertNotIn("x" * 200, error)

    def test_missing_items_show_indexes(self) -> None:
        requested = [
            "`swift test --filter FooTests`",
            "`swift build`",
            "screenshot of final result",
        ]
        # Only provide evidence for item 2
        body = self._make_body(
            ["- [complete] `swift build` -- built ok"],
        )
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        missing_errors = [e for e in errors if "missing:" in e]
        self.assertEqual(len(missing_errors), 1)
        error = missing_errors[0]
        # 1-based indexes for items 1 and 3
        self.assertIn("[1]", error)
        self.assertIn("[3]", error)
        # Should not contain index 2 (that one was provided)
        self.assertNotIn("[2]", error)

    def test_missing_section(self) -> None:
        body = "Some PR body without evidence section"
        requested = ["`swift test`"]
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        section_errors = [e for e in errors if "Evidence Status" in e and "section" in e]
        self.assertTrue(len(section_errors) >= 1)

    def test_duplicates_truncated(self) -> None:
        long_item = "very long evidence item " + "y" * 200
        body = self._make_body([
            f"- [complete] {long_item} -- proof 1",
            f"- [complete] {long_item} -- proof 2",
        ])
        requested = [long_item]
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        dup_errors = [e for e in errors if "duplicate" in e]
        self.assertEqual(len(dup_errors), 1)
        error = dup_errors[0]
        self.assertIn("...", error)
        self.assertNotIn("y" * 200, error)

    def test_all_complete_no_errors(self) -> None:
        requested = ["`swift test`", "`swift build`"]
        body = self._make_body([
            "- [complete] `swift test` -- all passed",
            "- [complete] `swift build` -- built ok",
        ])
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        self.assertEqual(errors, [])

    def test_structured_metadata_invalid(self) -> None:
        body = (
            '<!-- evidence-status:v1\n'
            'not valid json\n'
            '-->\n\n'
            '## Evidence Status\n'
        )
        requested = ["`swift test`"]
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        metadata_errors = [e for e in errors if "metadata" in e]
        self.assertTrue(len(metadata_errors) >= 1)

    def test_classify_evidence_error_categories(self) -> None:
        cases = [
            ("missing required '## Evidence Status' section", "evidence_section_missing"),
            ("malformed Evidence Status entries; expected '...' (line 1: ...)", "evidence_format"),
            ("malformed hidden evidence metadata: (line 1: ...)", "evidence_metadata"),
            ("duplicate Evidence Status entries for: foo", "evidence_duplicate"),
            ("PR body must account for every requested evidence item exactly; missing: [1] foo", "evidence_missing"),
        ]
        for error_msg, expected_category in cases:
            with self.subTest(error=error_msg):
                self.assertEqual(
                    run_contributor.classify_evidence_error(error_msg),
                    expected_category,
                )

        # Also test classify_evidence_errors returns list of dicts
        errors = [c[0] for c in cases]
        classified = run_contributor.classify_evidence_errors(errors)
        self.assertEqual(len(classified), len(cases))
        for i, (_, expected_cat) in enumerate(cases):
            self.assertEqual(classified[i]["category"], expected_cat)
            self.assertEqual(classified[i]["message"], errors[i])

    def test_fuzzy_matching_edge_cases(self) -> None:
        # Exact 70% word overlap should match
        requested = ["swift test filter FooTests BarTests BazTests QuuxTests FiveTests SixTests TenWord"]
        # 7 of 10 words match = 70%
        entry_text = "swift test filter FooTests BarTests BazTests QuuxTests different words here"
        body = self._make_body([
            f"- [complete] {entry_text} -- proof",
        ])
        accounting = run_contributor.evaluate_evidence_accounting(body, requested)
        # With 70% overlap the item should be matched (not missing)
        self.assertEqual(accounting["missing_items"], [])

        # Below 70% should NOT match
        requested_low = ["alpha bravo charlie delta echo foxtrot golf hotel india juliet"]
        entry_low = "alpha bravo charlie completely different words everywhere now ok done"
        body_low = self._make_body([
            f"- [complete] {entry_low} -- proof",
        ])
        accounting_low = run_contributor.evaluate_evidence_accounting(body_low, requested_low)
        self.assertEqual(len(accounting_low["missing_items"]), 1)

    def test_reproduce_april_failure_pattern(self) -> None:
        """Reproduce the exact pattern from April's CI logs: long evidence items
        with missing entries produce readable error messages."""
        requested = [
            "`swift test --filter 'WorkspaceManagerTests.SomeVeryLongTestSuiteName'`",
            "screenshot of the workspace manager main window after launching with the new sidebar layout changes applied",
            "`swift build`",
        ]
        # Only provide evidence for item 3
        body = self._make_body([
            "- [complete] `swift build` -- built successfully",
        ])
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        missing_errors = [e for e in errors if "missing:" in e]
        self.assertEqual(len(missing_errors), 1)
        error = missing_errors[0]
        # Should show 1-based indexes
        self.assertIn("[1]", error)
        self.assertIn("[2]", error)
        # Should truncate long items
        self.assertIn("...", error)
        # Should NOT contain the full long screenshot description
        self.assertNotIn("after launching with the new sidebar layout changes applied", error)
        # Verify total error message is readable (under ~500 chars)
        self.assertLess(len(error), 500)


    def test_render_then_validate_pending_ci_roundtrip(self) -> None:
        """Round-trip: render_execution_summary_body with pending-ci entries,
        then validate_evidence_accounting should not raise format errors."""
        requested = ["`swift test --filter Foo`", "screenshot of main window"]
        summary_body = "## Summary\nSome PR description\n\n## Validation\n- looks good\n"
        rendered, render_errors = run_contributor.render_execution_summary_body(
            summary_body,
            requested_evidence=requested,
            evidence_complete=["1 -- all tests pass"],
            evidence_blocked=None,
            evidence_pending_ci=["2 -- CI will capture screenshot"],
        )
        self.assertEqual(render_errors, [])
        # Rendered body should contain "blocked on evidence" language
        self.assertIn("blocked on evidence", rendered.casefold())
        # Now validate the rendered body — should have no errors
        _, validate_errors = run_contributor.validate_evidence_accounting(rendered, requested)
        self.assertEqual(validate_errors, [], f"Round-trip validation failed: {validate_errors}")


if __name__ == "__main__":
    unittest.main()
