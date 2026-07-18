#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Behavior tests for the Factory cost-row append script.

Exercises the script against a local bare repo seeded with a factory/ops-data
branch (via FACTORY_OPS_DATA_REMOTE): first append, idempotent re-run, empty
input, and the missing-branch guard.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "factory-cost-append.py"
RUNS_PATH = "docs/ops/cost/runs.jsonl"


def git(args: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        env={
            "GIT_AUTHOR_NAME": "seed",
            "GIT_AUTHOR_EMAIL": "seed@example.com",
            "GIT_COMMITTER_NAME": "seed",
            "GIT_COMMITTER_EMAIL": "seed@example.com",
            "PATH": _path(),
            "HOME": str(cwd or REPO_ROOT),
        },
    )
    if result.returncode != 0:
        raise AssertionError(f"git {args}: {result.stderr}")
    return result


def _path() -> str:
    import os

    return os.environ.get("PATH", "")


def run_script(rows_file: Path, remote: str) -> subprocess.CompletedProcess[str]:
    import os

    return subprocess.run(
        [sys.executable, str(SCRIPT), "--rows", str(rows_file)],
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "FACTORY_OPS_DATA_REMOTE": remote,
            "GH_TOKEN": "unused",
            "GITHUB_REPOSITORY": "owner/repo",
        },
    )


def seed_bare_repo(root: Path, *, branch: str = "factory/ops-data") -> Path:
    work = root / "work"
    git(["init", "-b", branch, str(work)])
    ops_dir = work / "docs" / "ops"
    ops_dir.mkdir(parents=True)
    (ops_dir / "README.md").write_text("ops-data\n", encoding="utf-8")
    git(["add", "."], cwd=work)
    git(["commit", "-m", "seed"], cwd=work)
    origin = root / "origin.git"
    git(["clone", "--bare", str(work), str(origin)])
    return origin


def read_runs(origin: Path, root: Path) -> list[dict]:
    verify = root / "verify"
    git(["clone", "--branch", "factory/ops-data", str(origin), str(verify)])
    runs = verify / RUNS_PATH
    if not runs.is_file():
        return []
    return [json.loads(line) for line in runs.read_text(encoding="utf-8").splitlines() if line.strip()]


def head_sha(origin: Path) -> str:
    return git(["rev-parse", "factory/ops-data"], cwd=origin).stdout.strip()


def write_rows(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")


class FactoryCostAppendTests(unittest.TestCase):
    def test_append_then_idempotent_rerun(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            origin = seed_bare_repo(root)
            rows_file = root / "cost-rows.jsonl"
            write_rows(rows_file, [{"id": "a", "cost_usd": 1.0}, {"id": "b", "cost_usd": 2.0}])

            first = run_script(rows_file, str(origin))
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual({r["id"] for r in read_runs(origin, root / "v1")}, {"a", "b"})

            sha_after_first = head_sha(origin)

            second = run_script(rows_file, str(origin))
            self.assertEqual(second.returncode, 0, second.stderr)
            rows = read_runs(origin, root / "v2")
            self.assertEqual(len(rows), 2)
            self.assertEqual(head_sha(origin), sha_after_first, "duplicate rows must not commit")

    def test_new_rows_merge_with_existing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            origin = seed_bare_repo(root)
            rows_file = root / "cost-rows.jsonl"

            write_rows(rows_file, [{"id": "a"}])
            self.assertEqual(run_script(rows_file, str(origin)).returncode, 0)

            write_rows(rows_file, [{"id": "a"}, {"id": "c"}])
            self.assertEqual(run_script(rows_file, str(origin)).returncode, 0)

            self.assertEqual({r["id"] for r in read_runs(origin, root / "v")}, {"a", "c"})

    def test_empty_rows_exits_zero_without_commit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            origin = seed_bare_repo(root)
            sha_before = head_sha(origin)
            rows_file = root / "empty.jsonl"
            rows_file.write_text("\n  \n", encoding="utf-8")

            result = run_script(rows_file, str(origin))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(head_sha(origin), sha_before)

    def test_missing_branch_is_hard_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            origin = seed_bare_repo(root, branch="main")
            rows_file = root / "cost-rows.jsonl"
            write_rows(rows_file, [{"id": "a"}])

            result = run_script(rows_file, str(origin))
            self.assertNotEqual(result.returncode, 0)

    def test_git_errors_never_leak_remote_credentials(self) -> None:
        # Job logs are public: no git failure may echo the token. Modern git
        # strips URL userinfo itself; the script's scrub is the backstop for
        # git versions and messages that don't.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rows_file = root / "cost-rows.jsonl"
            write_rows(rows_file, [{"id": "a"}])

            remote = "https://x-access-token:sekret-token-value@localhost:1/none.git"
            result = run_script(rows_file, remote)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("sekret-token-value", result.stdout + result.stderr)

    def test_scrub_credentials_redacts_url_userinfo(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("factory_cost_append", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        scrubbed = module.scrub_credentials(
            "fatal: unable to access 'https://x-access-token:tok123@github.com/o/r.git/'"
        )
        self.assertNotIn("tok123", scrubbed)
        self.assertIn("//[REDACTED]@github.com", scrubbed)


if __name__ == "__main__":
    unittest.main()
