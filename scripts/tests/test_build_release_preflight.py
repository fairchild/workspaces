#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests that `scripts/build-release.sh` rejects a build it cannot finish,
before it spends the build.

Two ways a packaged build was discovered only at the end. A signing identity of
the wrong class passes every check the script made — it is a real certificate,
it signs the bundle — and is then rejected by verify-release-bundle.sh, which
requires a Developer ID Application authority (#1570). And a GhosttyKit
framework built at a superseded pin compiles happily against source that moved
past it (#1564). Both cost a full compile to learn; both are answerable in a
second from configuration and the filesystem.

The tests assemble a throwaway project directory — the real scripts, a stub
Package.swift, a fixture framework — and run the real entry point against it,
so nothing here touches the repo's own build state. They read the machine's
keychain but never write to it, need no network, no secrets, and no signing
material: the identity cases resolve real certificates by name, and each skips
where the certificate it needs is absent.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SECURITY = shutil.which("security")


def codesigning_identity_names() -> list[str]:
    if SECURITY is None:
        return []
    listing = subprocess.run(
        [SECURITY, "find-identity", "-v", "-p", "codesigning"],
        capture_output=True,
        text=True,
    ).stdout
    return re.findall(r'"([^"]+)"', listing)


def first_identity_with_prefix(prefix: str) -> str | None:
    for name in codesigning_identity_names():
        if name.startswith(prefix):
            return name
    return None


@unittest.skipIf(SECURITY is None, "needs macOS `security` for identity lookup")
class BuildReleasePreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.project = Path(self.tmp.name) / "project"
        shutil.copytree(REPO_ROOT / "scripts", self.project / "scripts")
        (self.project / "Package.swift").write_text("// stub\n")
        manifest = subprocess.run(
            ["bash", str(self.project / "scripts" / "build-ghosttykit.sh"), "--print-pin"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        self.pin = dict(line.split("=", 1) for line in manifest.strip().splitlines())
        self.write_framework(self.pin["GHOSTTY_ARCHIVE_NAME"], self.pin["GHOSTTY_COMMIT"])
        self.addCleanup(self.tmp.cleanup)

    def write_framework(self, archive: str, stamp: str | None) -> None:
        framework = self.project / "Frameworks" / "GhosttyKit.xcframework"
        slice_dir = framework / "macos-arm64"
        slice_dir.mkdir(parents=True, exist_ok=True)
        (slice_dir / archive).write_text("")
        if stamp is not None:
            (framework / self.pin["GHOSTTY_PIN_STAMP_NAME"]).write_text(stamp + "\n")

    def signing_config(self, identity: str, profile: str | None = None) -> Path:
        path = Path(self.tmp.name) / "signing-config.sh"
        lines = ['export TEAM_ID="TESTTEAM00"', 'export BUNDLE_ID="com.example.test"',
                 f'export SIGNING_IDENTITY="{identity}"']
        if profile is not None:
            lines.append(f'export PROVISIONING_PROFILE_PATH="{profile}"')
        path.write_text("\n".join(lines) + "\n")
        return path

    def run_build(self, *args: str, config: Path | None = None) -> subprocess.CompletedProcess[str]:
        # HOME is left alone: `security` finds the login keychain through it.
        # Isolation comes from SIGNING_CONFIG and the throwaway project dir.
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ["HOME"]}
        if config is not None:
            env["SIGNING_CONFIG"] = str(config)
        return subprocess.run(
            ["bash", str(self.project / "scripts" / "build-release.sh"), *args],
            capture_output=True,
            text=True,
            env=env,
        )

    def assertNeverBuilt(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertNotIn("Building release binary", result.stdout)
        self.assertFalse((self.project / ".build").exists())

    def test_identity_of_the_wrong_class_is_rejected_before_the_build(self) -> None:
        identity = first_identity_with_prefix("Apple Distribution: ")
        if identity is None:
            self.skipTest("no Apple Distribution certificate to misconfigure with")
        result = self.run_build(config=self.signing_config(identity))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Developer ID Application", result.stdout + result.stderr)
        self.assertIn("verify-release-bundle.sh", result.stdout + result.stderr)
        self.assertNeverBuilt(result)

    def test_identity_matching_no_certificate_is_rejected(self) -> None:
        result = self.run_build(config=self.signing_config("Nonexistent Identity (ZZZZZZZZZZ)"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("matches no codesigning certificate", result.stdout + result.stderr)
        self.assertNeverBuilt(result)

    def test_a_developer_id_identity_passes_the_authority_check(self) -> None:
        identity = first_identity_with_prefix("Developer ID Application: ")
        if identity is None:
            self.skipTest("no Developer ID Application certificate on this host")
        # No profile configured, so the run stops at the next assertion — which
        # is what shows the identity was accepted.
        result = self.run_build(config=self.signing_config(identity))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"Signing identity: {identity}", result.stdout)
        self.assertIn("PROVISIONING_PROFILE_PATH is required", result.stdout + result.stderr)
        self.assertNeverBuilt(result)

    def test_a_stale_framework_stops_the_build_even_when_signing_is_fine(self) -> None:
        shutil.rmtree(self.project / "Frameworks")
        self.write_framework("libghostty-fat.a", None)
        identity = first_identity_with_prefix("Developer ID Application: ")
        config = self.signing_config(identity) if identity else None
        result = self.run_build(config=config)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("libghostty-fat.a", result.stdout + result.stderr)
        self.assertNeverBuilt(result)

    def test_the_pin_is_checked_for_unsigned_builds_too(self) -> None:
        shutil.rmtree(self.project / "Frameworks")
        result = self.run_build("--no-sign")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no GhosttyKit.xcframework", result.stdout + result.stderr)
        self.assertNeverBuilt(result)


if __name__ == "__main__":
    unittest.main()
