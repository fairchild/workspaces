#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Every script and workflow step that loads evidence.py can import it.

evidence.py imports markdown-it-py, so an entry point that loads it without
the pinned package throws ModuleNotFoundError where the evidence gate should
refuse. Each test imports evidence.py through a loader's own command, outside
this test's environment, so a missing pin fails here rather than in CI. This
file carries no dependency of its own on purpose.
"""

from __future__ import annotations

import os
import shlex
import subprocess
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "_evidence.yml"
PIN = "markdown-it-py==4.2.0"
# One minor version, so the reading does not vary with the interpreter uv picks.
PYTHON_PIN = "--python 3.12"
LOAD_LINES = {"import evidence", "spec.loader.exec_module(module)"}


def heredoc_loaders() -> list[tuple[str, str]]:
    """Each `<<'PY'` step in the workflow that loads evidence.py.

    Returns the command the step runs and its script up to and including the
    line that loads evidence.py, so the load runs exactly as the step runs it.
    """
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    loaders: list[tuple[str, str]] = []
    for number, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.endswith("<<'PY'"):
            continue
        body: list[str] = []
        for following in lines[number + 1 :]:
            if following.strip() == "PY":
                break
            body.append(following)
        prologue: list[str] = []
        for source_line in textwrap.dedent("\n".join(body)).splitlines():
            prologue.append(source_line)
            if source_line.strip() in LOAD_LINES:
                loaders.append((stripped[: -len("<<'PY'")].strip(), "\n".join(prologue) + "\n"))
                break
    return loaders


def script_dependencies(path: Path) -> str:
    """The `dependencies` line of a script's PEP 723 block, or an empty string."""
    in_block = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip() == "# /// script":
            in_block = True
        elif line.strip() == "# ///":
            break
        elif in_block and line.startswith("# dependencies"):
            return line
    return ""


class EvidenceLoaderTests(unittest.TestCase):
    def run_loader(self, argv: list[str], stdin: str | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            argv,
            cwd=REPO_ROOT,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=600,
            # No cached environment: a loader has to resolve its own pins.
            env={**os.environ, "PYTHONNOUSERSITE": "1", "UV_NO_CACHE": "1"},
        )

    def assert_loads(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertNotIn("ModuleNotFoundError", result.stderr, result.stderr[-2000:])
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])

    def test_factory_sweep_loads_evidence_through_factory_implement(self) -> None:
        # factory-monitor.yml runs this script, which loads factory-implement.py
        # through importlib at import time, and that imports evidence.py. uv
        # reuses a cached script environment that already satisfies the
        # script's dependencies, so after a pinned run a removed pin still
        # imports; the declared pin is checked, and the run skips the cache.
        self.assertIn(PIN, script_dependencies(REPO_ROOT / "scripts" / "factory-sweep.py"))
        self.assert_loads(self.run_loader(["uv", "run", "--no-cache", "--script", "scripts/factory-sweep.py", "--help"]))

    def test_every_evidence_workflow_step_loads_evidence(self) -> None:
        # The count is exact rather than a floor: a step added without the pin
        # would otherwise be a loader nobody checked, and this file exists
        # because that failure lands in CI rather than here. Three since #1740
        # gave the lane's uncarried-note announcement a posting step of its own.
        loaders = heredoc_loaders()
        self.assertEqual(len(loaders), 3, loaders)
        for command, prologue in loaders:
            with self.subTest(command=command):
                # The runner's own python3 has no markdown-it-py, so the pin has
                # to be in the command itself.
                self.assertIn(PIN, command)
                self.assertIn(PYTHON_PIN, command)
                self.assert_loads(self.run_loader(shlex.split(command), stdin=prologue))


if __name__ == "__main__":
    unittest.main()
