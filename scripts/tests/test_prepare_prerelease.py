#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for the tester-prerelease preparation helper."""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "prepare-prerelease.sh"


class PreparePrereleaseTests(unittest.TestCase):
    def test_updates_version_build_and_changelog_without_committing(self) -> None:
        with PreparePrereleaseFixture() as fixture:
            result = fixture.run("--version", "0.21.0-beta.1")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("Prerelease PR target", result.stdout)
            self.assertIn("publishes when merged: manual Release workflow dispatch from main", result.stdout)

            plist = fixture.read_plist()
            self.assertEqual(plist["CFBundleShortVersionString"], "0.21.0-beta.1")
            self.assertEqual(plist["CFBundleVersion"], "26")

            changelog = fixture.changelog.read_text(encoding="utf-8")
            self.assertIn("## [0.21.0-beta.1] - ", changelog)
            self.assertIn("### Added\n- add tester prerelease flow", changelog)
            self.assertIn("### Fixed\n- repair release notes", changelog)

            status = fixture.git("status", "--porcelain").stdout
            self.assertIn(" M CHANGELOG.md", status)
            self.assertIn(" M Sources/WorkspaceManager/Resources/Info.plist", status)

    def test_rejects_stable_versions(self) -> None:
        with PreparePrereleaseFixture() as fixture:
            result = fixture.run("--version", "0.21.0")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Version must be a SemVer prerelease", result.stderr)

    def test_dry_run_does_not_mutate_files(self) -> None:
        with PreparePrereleaseFixture() as fixture:
            original_plist = fixture.info_plist.read_bytes()
            original_changelog = fixture.changelog.read_text(encoding="utf-8")

            result = fixture.run("--version", "0.21.0-rc.1", "--dry-run")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(fixture.info_plist.read_bytes(), original_plist)
            self.assertEqual(fixture.changelog.read_text(encoding="utf-8"), original_changelog)
            self.assertEqual(fixture.git("status", "--porcelain").stdout, "")


class PreparePrereleaseFixture:
    def __init__(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="PreparePrereleaseTests-"))
        self.scripts_dir = self.root / "scripts"
        self.info_plist = self.root / "Sources/WorkspaceManager/Resources/Info.plist"
        self.changelog = self.root / "CHANGELOG.md"

    def __enter__(self) -> "PreparePrereleaseFixture":
        self.scripts_dir.mkdir(parents=True)
        shutil.copy2(SCRIPT_PATH, self.scripts_dir / "prepare-prerelease.sh")
        (self.scripts_dir / "prepare-prerelease.sh").chmod(0o755)
        self.write_fake_release_version_script()

        self.info_plist.parent.mkdir(parents=True)
        with self.info_plist.open("wb") as file:
            plistlib.dump(
                {
                    "CFBundleShortVersionString": "0.20.0",
                    "CFBundleVersion": "25",
                },
                file,
            )
        self.changelog.write_text("# Changelog\n\n## [0.20.0] - 2026-06-17\n\n### Added\n- existing release\n", encoding="utf-8")

        self.git("init")
        self.git("config", "user.name", "Test User")
        self.git("config", "user.email", "test@example.com")
        self.git("add", ".")
        self.git("commit", "-m", "release: v0.20.0")
        self.git("tag", "v0.20.0")

        self.commit("feat: add tester prerelease flow")
        self.commit("fix: repair release notes")
        return self

    def __exit__(self, *args: object) -> None:
        shutil.rmtree(self.root)

    def write_fake_release_version_script(self) -> None:
        script = self.scripts_dir / "release-version.sh"
        script.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail

                plist="${INFO_PLIST_PATH:?}"

                case "${1:-}" in
                  print-build)
                    python3 - "$plist" <<'PY'
                import plistlib, sys
                with open(sys.argv[1], "rb") as file:
                    print(plistlib.load(file)["CFBundleVersion"])
                PY
                    ;;
                  set)
                    version="${2:?}"
                    shift 2
                    bump=false
                    while [ "$#" -gt 0 ]; do
                      case "$1" in
                        --bump-build) bump=true ;;
                        *) echo "unexpected argument: $1" >&2; exit 64 ;;
                      esac
                      shift
                    done
                    python3 - "$plist" "$version" "$bump" <<'PY'
                import plistlib, sys
                path, version, bump = sys.argv[1:]
                with open(path, "rb") as file:
                    data = plistlib.load(file)
                data["CFBundleShortVersionString"] = version
                if bump == "true":
                    data["CFBundleVersion"] = str(int(data["CFBundleVersion"]) + 1)
                with open(path, "wb") as file:
                    plistlib.dump(data, file)
                print(f"version={data['CFBundleShortVersionString']}")
                print(f"build={data['CFBundleVersion']}")
                PY
                    ;;
                  *)
                    echo "unexpected command: ${1:-}" >&2
                    exit 64
                    ;;
                esac
                """
            ),
            encoding="utf-8",
        )
        script.chmod(0o755)

    def commit(self, message: str) -> None:
        marker = self.root / f"{message.replace(': ', '-').replace(' ', '-')}.txt"
        marker.write_text(message, encoding="utf-8")
        self.git("add", marker.name)
        self.git("commit", "-m", message)

    def run(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.scripts_dir / "prepare-prerelease.sh"), *args],
            cwd=self.root,
            env={**os.environ, "INFO_PLIST_PATH": str(self.info_plist)},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *args],
            cwd=self.root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

    def read_plist(self) -> dict[str, object]:
        with self.info_plist.open("rb") as file:
            return plistlib.load(file)


if __name__ == "__main__":
    unittest.main()
