#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for the become-persona resolver."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[4]


def load_resolver():
    path = SCRIPT_PATH.parent / "resolve_persona.py"
    spec = importlib.util.spec_from_file_location("resolve_persona", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["resolve_persona"] = module
    spec.loader.exec_module(module)
    return module


resolver = load_resolver()


class ResolvePersonaTests(unittest.TestCase):
    def test_resolves_short_aliases(self) -> None:
        personas = resolver.load_catalog(repo_root=REPO_ROOT)

        self.assertEqual(resolver.resolve_alias("april", personas).display_name, "April Clearwater")
        self.assertEqual(resolver.resolve_alias("plat", personas).display_name, "Plat Ironwood")
        self.assertEqual(resolver.resolve_alias("peter", personas).display_name, "Peter Planner")
        self.assertEqual(resolver.resolve_alias("mara", personas).display_name, "Mara Fielding")
        self.assertEqual(resolver.resolve_alias("pm", personas).display_name, "Mara Fielding")

    def test_parse_requested_text_accepts_command_form(self) -> None:
        alias, remaining = resolver.parse_requested_text(["/become april review this layout"])

        self.assertEqual(alias, "april")
        self.assertEqual(remaining, "review this layout")

    def test_interactive_prompt_strips_runtime_output_format(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            context = resolver.resolve_persona_context(
                ["april"],
                repo_root=REPO_ROOT,
                memory_root=Path(tmp),
            )

        self.assertIn("You are April Clearwater", context.prompt)
        self.assertNotIn("## Output Format", context.prompt)
        self.assertNotIn("Your entire output must be valid YAML frontmatter", context.prompt)

    def test_discovers_shared_and_persona_memory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            memory_root = Path(tmp)
            (memory_root / "shared").mkdir()
            (memory_root / "shared" / "human.md").write_text("Shared note", encoding="utf-8")
            (memory_root / "april").mkdir()
            (memory_root / "april" / "AGENTS.md").write_text("Team bootstrap", encoding="utf-8")
            (memory_root / "april" / "personality.md").write_text(
                "April memory", encoding="utf-8"
            )
            (memory_root / "april" / "method.md").write_text(
                "Unlisted top-level memory", encoding="utf-8"
            )
            (memory_root / "april" / "core").mkdir()
            (memory_root / "april" / "core" / "pattern.md").write_text(
                "Team core", encoding="utf-8"
            )

            context = resolver.resolve_persona_context(
                ["april"],
                repo_root=REPO_ROOT,
                memory_root=memory_root,
            )
            paths = {item.path.name for item in context.memory_files}

        self.assertIn("MEMORY.md", paths)
        self.assertIn("AGENTS.md", paths)
        self.assertIn("human.md", paths)
        self.assertIn("personality.md", paths)
        self.assertIn("pattern.md", paths)
        # Regression (2026-08-28): a top-level file outside PERSONA_INLINE_FILES
        # was written successfully and silently never loaded.
        self.assertIn("method.md", paths)

    def test_uses_active_team_core_when_persona_memory_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            memory_root = Path(tmp)
            (memory_root / "shared").mkdir()
            (memory_root / "shared" / "human.md").write_text("Shared note", encoding="utf-8")
            scout = memory_root / "scout"
            (scout / "core").mkdir(parents=True)
            (scout / "core" / "workflow.md").write_text("Active core", encoding="utf-8")
            (memory_root / "active").symlink_to(scout, target_is_directory=True)

            context = resolver.resolve_persona_context(
                ["april"],
                repo_root=REPO_ROOT,
                memory_root=memory_root,
            )
            memory_by_name = {item.path.name: item.label for item in context.memory_files}
            names = [item.path.name for item in context.memory_files]

        self.assertEqual(memory_by_name["workflow.md"], "Active Team Memory Core")
        self.assertLess(names.index("workflow.md"), names.index("human.md"))

    def test_unknown_persona_lists_available_personas(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = resolver.main(["unknown"])

        self.assertEqual(result, 2)


if __name__ == "__main__":
    unittest.main()
