#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fail-closed tests for the release harness-absence gate (#1235).

The gate makes a negative claim — "the debug smoke/fixture harness is not in the
release binary" — which is only worth anything if the scan actually ran. These
tests protect that: an empty binary, a missing binary, or nm/strings returning
nothing must error rather than certify, and a stale deferral allowlist entry
must fail so #1237 cannot silently inherit a hole.

Safe to run without network, secrets, UI access, or live GitHub mutations: nm
and strings are stubbed on PATH and every fixture lives in a temp directory.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "check-release-harness-absence.sh"

EXIT_LEAK = 1
EXIT_NO_BINARY = 2
EXIT_NO_SIGNAL = 3

SENTINEL = "com.cloudcompute.workspaces"

DEFERRED_KEYS = (
    "WORKSPACES_UI_FIXTURE",
    "WORKSPACES_UI_FIXTURE_OPEN_SESSION_SWITCHER",
    "WORKSPACES_UI_FIXTURE_OPEN_DIAGNOSTICS",
    "WORKSPACES_UI_FIXTURE_OPEN_PREVIEW",
    "WORKSPACES_UI_FIXTURE_PREVIEW_REPO",
    "WORKSPACES_UI_FIXTURE_PREVIEW_PATH",
    "WORKSPACES_UI_FIXTURE_SELECT_WEB_SOURCE",
    "WORKSPACES_UI_FIXTURE_WEB_SOURCE",
)


def clean_symbols(count: int = 2000) -> list[str]:
    return [f"0000000100000000 T _$s16WorkspaceManager{index}yF" for index in range(count)]


def clean_strings() -> list[str]:
    return [SENTINEL, "WORKSPACES_AUTOMATION_SOCKET", *DEFERRED_KEYS]


class ReleaseHarnessAbsenceTests(unittest.TestCase):
    def test_clean_release_binary_passes(self) -> None:
        with HarnessFixture(symbols=clean_symbols(), strings=clean_strings()) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("release harness check passed", result.stdout)
        self.assertIn(f"strings found '{SENTINEL}'", result.stdout)

    def test_empty_binary_errors_instead_of_certifying(self) -> None:
        """The vacuous case: nothing to scan must never read as nothing found."""
        with HarnessFixture(symbols=[], strings=[]) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, EXIT_NO_SIGNAL, result.stdout + result.stderr)
        self.assertNotIn("release harness check passed", result.stdout)
        self.assertIn("refusing to certify", result.stderr)

    def test_real_tools_on_an_empty_file_error(self) -> None:
        """Same vacuum, unstubbed: real nm/strings on an empty file must error."""
        with HarnessFixture(symbols=[], strings=[], stub_tools=False) as fixture:
            result = fixture.run()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("release harness check passed", result.stdout)

    def test_missing_binary_is_its_own_exit_code(self) -> None:
        with HarnessFixture(symbols=[], strings=[], create_binary=False) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, EXIT_NO_BINARY, result.stdout + result.stderr)
        self.assertIn("release binary not found", result.stderr)

    def test_symbol_table_without_sentinel_errors(self) -> None:
        """nm reads fine but strings is empty — still an unproven scan."""
        with HarnessFixture(symbols=clean_symbols(), strings=[]) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, EXIT_NO_SIGNAL, result.stdout + result.stderr)
        self.assertIn(SENTINEL, result.stderr)

    def test_leaked_harness_symbol_fails(self) -> None:
        symbols = [*clean_symbols(), "0000000100000000 T _$s16UIFixtureSeederyF"]
        with HarnessFixture(symbols=symbols, strings=clean_strings()) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, EXIT_LEAK, result.stdout + result.stderr)
        self.assertIn("UIFixtureSeeder", result.stderr)

    def test_leaked_harness_string_fails(self) -> None:
        strings = [*clean_strings(), "WORKSPACES_AUTOMATION_EVENTS_PATH"]
        with HarnessFixture(symbols=clean_symbols(), strings=strings) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, EXIT_LEAK, result.stdout + result.stderr)
        self.assertIn("WORKSPACES_AUTOMATION_EVENTS_PATH", result.stderr)

    def test_stale_deferral_entry_fails(self) -> None:
        """When #1237 gates a fixture key, its allowlist entry must be deleted."""
        strings = [value for value in clean_strings() if "PREVIEW_PATH" not in value]
        with HarnessFixture(symbols=clean_symbols(), strings=strings) as fixture:
            result = fixture.run()

        self.assertEqual(result.returncode, EXIT_LEAK, result.stdout + result.stderr)
        self.assertIn("WORKSPACES_UI_FIXTURE_PREVIEW_PATH", result.stderr)
        self.assertIn("delete it from deferred_string_patterns", result.stderr)


class HarnessFixture:
    def __init__(
        self,
        *,
        symbols: list[str],
        strings: list[str],
        create_binary: bool = True,
        stub_tools: bool = True,
    ) -> None:
        self.symbols = symbols
        self.strings = strings
        self.create_binary = create_binary
        self.stub_tools = stub_tools
        self.root = Path(tempfile.mkdtemp(prefix="ReleaseHarnessAbsenceTests-"))

    def __enter__(self) -> "HarnessFixture":
        self.binary = self.root / "WorkspaceManager"
        if self.create_binary:
            self.binary.write_text("\n".join(self.strings))

        self.env = os.environ.copy()
        if self.stub_tools:
            stub_bin = self.root / "bin"
            stub_bin.mkdir()
            (self.root / "nm.out").write_text("\n".join(self.symbols))
            (self.root / "strings.out").write_text("\n".join(self.strings))
            self._write_stub(stub_bin / "nm", self.root / "nm.out")
            self._write_stub(stub_bin / "strings", self.root / "strings.out")
            self.env["PATH"] = f"{stub_bin}{os.pathsep}{self.env['PATH']}"
        return self

    def _write_stub(self, path: Path, payload: Path) -> None:
        path.write_text(
            textwrap.dedent(
                f"""\
                #!/bin/sh
                cat "{payload}"
                """
            )
        )
        path.chmod(0o755)

    def run(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT_PATH), str(self.binary)],
            capture_output=True,
            text=True,
            env=self.env,
            cwd=self.root,
        )

    def __exit__(self, *_: object) -> None:
        shutil.rmtree(self.root, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
