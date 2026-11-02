#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for scripts/lib/build-products.sh, the one place scripts learn where
SwiftPM put a build's products and how a resource bundle is shaped.

The directory and the bundle's shape both follow the toolchain's default build
system. These run the real helpers under bash against a stub `swift` and
throwaway bundles in each layout: no build, no toolchain needed, so they also
hold on the Linux runner, which never builds the app.
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LIB_PATH = REPO_ROOT / "scripts" / "lib" / "build-products.sh"


def run_helper(script: str, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", f'set -euo pipefail\nsource "{LIB_PATH}"\n{script}', "helper", *args],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )


class BuildProductsDirTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.calls = self.root / "swift-calls"

    def env_with_swift(self, body: str) -> dict[str, str]:
        stub_bin = self.root / "bin"
        stub_bin.mkdir()
        swift = stub_bin / "swift"
        swift.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{self.calls}"\n{body}\n', encoding="utf-8")
        swift.chmod(swift.stat().st_mode | stat.S_IXUSR)
        return {**os.environ, "PATH": f"{stub_bin}:{os.environ['PATH']}"}

    def test_prints_the_directory_the_toolchain_reports(self) -> None:
        env = self.env_with_swift('echo "/repo/.build/out/Products/Debug"')
        result = run_helper('build_products_dir "$1"', "/repo", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/repo/.build/out/Products/Debug\n")

    def test_asks_for_the_requested_configuration_of_the_requested_package(self) -> None:
        env = self.env_with_swift('echo "/repo/.build/out/Products/Release"')
        run_helper('build_products_dir "$1" release', "/repo", env=env)
        call = self.calls.read_text(encoding="utf-8")
        self.assertIn("--package-path /repo", call)
        self.assertIn("--configuration release", call)
        self.assertIn("--show-bin-path", call)

    def test_does_not_wait_on_a_build_running_in_the_same_tree(self) -> None:
        env = self.env_with_swift('echo "/repo/.build/out/Products/Debug"')
        run_helper('build_products_dir "$1"', "/repo", env=env)
        self.assertIn("--ignore-lock", self.calls.read_text(encoding="utf-8"))

    def test_keeps_only_the_path_when_the_toolchain_prints_more(self) -> None:
        env = self.env_with_swift('echo "warning: something"\necho "/repo/.build/arm64-apple-macosx/debug"')
        result = run_helper('build_products_dir "$1"', "/repo", env=env)
        self.assertEqual(result.stdout, "/repo/.build/arm64-apple-macosx/debug\n")

    def test_a_failed_query_fails_the_caller_instead_of_yielding_a_bare_name(self) -> None:
        """An empty directory would turn `pkill -f "$dir/WorkspaceManager"` into a
        pattern that matches the installed app, so the assignment has to abort."""
        env = self.env_with_swift("exit 1")
        result = run_helper(
            'dir="$(build_products_dir "$1")/WorkspaceManager"\necho "reached with $dir"', "/repo", env=env
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("reached", result.stdout)
        self.assertIn("build products", result.stderr)

    def test_empty_output_counts_as_a_failed_query(self) -> None:
        env = self.env_with_swift("exit 0")
        result = run_helper('dir="$(build_products_dir "$1")"\necho "reached"', "/repo", env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("reached", result.stdout)


class ResourceBundleContentsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bundle = Path(self.tmp.name) / "WorkspaceManager_WorkspaceManager.bundle"

    def contents(self) -> Path:
        result = run_helper('resource_bundle_contents "$1"', str(self.bundle))
        self.assertEqual(result.returncode, 0, result.stderr)
        return Path(result.stdout.strip())

    def test_a_native_bundle_holds_its_files_at_the_root(self) -> None:
        (self.bundle / "HookForwarders").mkdir(parents=True)
        (self.bundle / "HookForwarders" / "statusline.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        self.assertEqual(self.contents(), self.bundle)

    def test_a_swiftbuild_bundle_holds_them_under_contents_resources(self) -> None:
        resources = self.bundle / "Contents" / "Resources"
        (resources / "HookForwarders").mkdir(parents=True)
        (resources / "HookForwarders" / "statusline.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        (self.bundle / "Contents" / "Info.plist").write_text("<plist/>\n", encoding="utf-8")
        contents = self.contents()
        self.assertEqual(contents, resources)
        self.assertTrue((contents / "HookForwarders" / "statusline.sh").is_file())
        self.assertFalse((contents / "Info.plist").exists())


if __name__ == "__main__":
    unittest.main()
